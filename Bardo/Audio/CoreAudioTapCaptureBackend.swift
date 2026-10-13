import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import CoreMedia
import Foundation
import OSLog

/// Records everything the Mac plays, such as a Meet, Zoom or Discord call, with a Core
/// Audio process tap, and the microphone with AVCaptureSession.
///
/// A global tap hears every app (Bardo excluded) whatever its window or helper process,
/// so there is nothing to choose and no screen recording involved: macOS asks once for
/// permission to record system audio. Both tracks are stamped on the host clock, so the
/// existing writers and mix keep them aligned.
final class CoreAudioTapCaptureBackend: SystemAudioCapturing, @unchecked Sendable {
    @MainActor var eventHandler: ((SystemAudioCaptureBackendEvent) -> Void)?

    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "capture.system-audio")

    private let systemQueue = DispatchQueue(label: "com.maxavend.bardo.system-audio.tap", qos: .userInitiated)
    private let microphoneQueue = DispatchQueue(label: "com.maxavend.bardo.system-audio.microphone", qos: .userInitiated)
    private let processor = SystemAudioSampleProcessor()
    private let silence = SilenceMonitor()

    @MainActor private var tap: SystemAudioTap?
    @MainActor private var microphone: MicrophoneSession?
    @MainActor private var isStopping = false

    @MainActor
    var currentTime: TimeInterval {
        processor.elapsedTime
    }

    @MainActor
    func start(
        selection: SystemContentSelection,
        includeMicrophone: Bool,
        systemURL: URL,
        microphoneURL: URL?
    ) async throws {
        guard tap == nil else { throw SystemAudioCaptureError.alreadyCapturing }
        if includeMicrophone && microphoneURL == nil {
            throw SystemAudioCaptureError.missingMicrophoneDestination
        }

        processor.configure(systemURL: systemURL, microphoneURL: includeMicrophone ? microphoneURL : nil)
        silence.reset()

        do {
            let tap = try SystemAudioTap(queue: systemQueue) { [weak self] sampleBuffer, heardSound in
                self?.handle(sampleBuffer, track: .system, heardSound: heardSound)
            }
            self.tap = tap

            if includeMicrophone {
                let microphone = try MicrophoneSession(queue: microphoneQueue) { [weak self] sampleBuffer in
                    self?.handle(sampleBuffer, track: .microphone, heardSound: true)
                }
                await microphone.start()
                self.microphone = microphone
            }
            try tap.start()
            Self.logger.notice("System audio capture started (microphone: \(includeMicrophone, privacy: .public))")
        } catch {
            await tearDown()
            processor.reset()
            throw SystemAudioCaptureError.systemAudio(error.localizedDescription)
        }
    }

    /// The tap already hears the whole Mac, so there is no other content to switch to.
    @MainActor
    func update(selection: SystemContentSelection) async throws {
        guard tap != nil else { throw SystemAudioCaptureError.notCapturing }
    }

    @MainActor
    func stop() async -> SystemAudioCaptureResult {
        guard tap != nil else {
            return SystemAudioCaptureResult(
                systemTrack: nil,
                microphoneTrack: nil,
                systemError: SystemAudioCaptureError.notCapturing.localizedDescription,
                microphoneError: nil,
                streamStopError: nil
            )
        }

        isStopping = true
        await tearDown()

        // Drain every callback already enqueued before finalizing writers.
        systemQueue.sync { }
        microphoneQueue.sync { }
        var result = await processor.finish(streamStopError: nil)
        processor.reset()
        isStopping = false

        // A tap without permission delivers silence rather than an error, so a track of
        // pure digital silence is the only sign that macOS did not let Bardo listen.
        if var systemTrack = result.systemTrack, !silence.heardSound {
            systemTrack.warning = systemTrack.warning ?? String(localized: "Bardo did not hear any Mac audio. If something was playing, allow Bardo in System Settings › Privacy & Security › Screen & System Audio Recording.")
            result = SystemAudioCaptureResult(
                systemTrack: systemTrack,
                microphoneTrack: result.microphoneTrack,
                systemError: result.systemError,
                microphoneError: result.microphoneError,
                streamStopError: result.streamStopError
            )
        }
        Self.logger.notice("System audio capture stopped (heard sound: \(self.silence.heardSound, privacy: .public))")
        return result
    }

    nonisolated private func handle(_ sampleBuffer: CMSampleBuffer, track: SystemAudioSampleProcessor.Track, heardSound: Bool) {
        if track == .system, heardSound { silence.markHeard() }

        let event: SystemAudioCaptureBackendEvent
        switch processor.append(sampleBuffer, track: track) {
        case .recording:
            return
        case .trackFailed(let message):
            event = .trackFailed(message)
        case .allTracksFailed(let message):
            event = .interrupted(message)
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isStopping else { return }
            self.eventHandler?(event)
        }
    }

    @MainActor
    private func tearDown() async {
        tap?.stop()
        tap = nil
        await microphone?.stop()
        microphone = nil
    }
}

/// Remembers whether the system track carried anything but digital silence.
private final class SilenceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var heard = false

    var heardSound: Bool { lock.bardoWithLock { heard } }
    func markHeard() { lock.bardoWithLock { heard = true } }
    func reset() { lock.bardoWithLock { heard = false } }
}

/// A private global process tap, read through a private aggregate device clocked by the
/// default output device.
private final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer, _ heardSound: Bool) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var format = AudioStreamBasicDescription()
    private var formatDescription: CMAudioFormatDescription?
    private let queue: DispatchQueue
    private let handler: Handler
    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "capture.system-audio")

    init(queue: DispatchQueue, handler: @escaping Handler) throws {
        self.queue = queue
        self.handler = handler

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.currentProcessObjects())
        description.uuid = UUID()
        description.name = "Bardo"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        format = try Self.property(kAudioTapPropertyFormat, of: tapID, default: AudioStreamBasicDescription())
        Self.logger.notice("Tap format: \(self.format.mSampleRate, privacy: .public) Hz, \(self.format.mChannelsPerFrame, privacy: .public) ch, \(self.format.mBytesPerFrame, privacy: .public) bytes/frame, flags \(self.format.mFormatFlags, privacy: .public)")
        try Self.check(
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &format,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &formatDescription
            ),
            "describe the system audio format"
        )

        let outputDevice: AudioObjectID = try Self.property(
            kAudioHardwarePropertyDefaultOutputDevice,
            of: AudioObjectID(kAudioObjectSystemObject),
            default: AudioObjectID(kAudioObjectUnknown)
        )
        let outputUID = try Self.deviceUID(of: outputDevice)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Bardo System Audio",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString
            ]]
        ]
        do {
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                "create the system audio device"
            )
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    func start() throws {
        let format = format
        let formatDescription = formatDescription
        let handler = handler
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
                guard let formatDescription,
                      let sampleBuffer = Self.sampleBuffer(from: input, at: inputTime.pointee, format: format, description: formatDescription)
                else { return }
                handler(sampleBuffer, Self.containsSound(input))
            },
            "listen to the system audio device"
        )
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start listening to system audio")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                self.ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Copies one IO cycle into a sample buffer stamped with its host time.
    private static func sampleBuffer(
        from input: UnsafePointer<AudioBufferList>,
        at time: AudioTimeStamp,
        format: AudioStreamBasicDescription,
        description: CMAudioFormatDescription
    ) -> CMSampleBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, format.mBytesPerFrame > 0, format.mSampleRate > 0 else { return nil }
        let frames = Int(first.mDataByteSize / format.mBytesPerFrame)
        guard frames > 0, time.mFlags.contains(.hostTimeValid) else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.mSampleRate)),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(time.mHostTime),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleCount: frames,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: input
        ) == noErr else { return nil }
        CMSampleBufferSetDataReady(sampleBuffer)
        return sampleBuffer
    }

    /// Whether any sample in the cycle is not digital silence. The tap delivers Float32.
    private static func containsSound(_ input: UnsafePointer<AudioBufferList>) -> Bool {
        for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let count = vDSP_Length(Int(buffer.mDataByteSize) / MemoryLayout<Float>.size)
            guard count > 0 else { continue }
            var peak: Float = 0
            vDSP_maxmgv(data, 1, &peak, count)
            if peak > 0 { return true }
        }
        return false
    }

    /// Bardo's own audio objects, so playing back a recording never ends up in a new one.
    private static func currentProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pid,
            &size,
            &object
        )
        return status == noErr && object != kAudioObjectUnknown ? [object] : []
    }

    private static func deviceUID(of device: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid), "read the output device")
        guard let uid else { throw SystemAudioTapError(action: "read the output device", status: kAudioHardwareUnknownPropertyError) }
        return uid.takeRetainedValue()
    }

    private static func property<Value: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        of object: AudioObjectID,
        default initial: Value
    ) throws -> Value {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read the system audio setup")
        return value
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else {
            Logger(subsystem: "com.maxavend.bardo", category: "capture.system-audio")
                .error("Could not \(action, privacy: .public): \(status, privacy: .public)")
            throw SystemAudioTapError(action: action, status: status)
        }
    }
}

private struct SystemAudioTapError: LocalizedError {
    let action: String
    let status: OSStatus

    var errorDescription: String? {
        String(localized: "Bardo could not listen to the Mac's audio (Core Audio error \(status)).")
    }
}

/// The default microphone through AVCaptureSession, delivered as 48 kHz mono Float32
/// and restamped on the host clock the system tap uses, so the two tracks line up.
private final class MicrophoneSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer) -> Void

    private let session = AVCaptureSession()
    private let handler: Handler

    init(queue: DispatchQueue, handler: @escaping Handler) throws {
        self.handler = handler
        super.init()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw SystemAudioCaptureError.systemAudio(String(localized: "No microphone is available."))
        }
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw SystemAudioCaptureError.systemAudio(String(localized: "The microphone could not be connected."))
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
    }

    /// `startRunning` blocks while the device spins up, so it runs off the main thread.
    func start() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.stopRunning()
                continuation.resume()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let retimed = hostTimed(sampleBuffer) else { return }
        handler(retimed)
    }

    private func hostTimed(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return nil }
        let hostClock = CMClockGetHostTimeClock()
        guard let sourceClock = session.synchronizationClock, !CFEqual(sourceClock, hostClock) else {
            return sampleBuffer
        }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: CMSyncConvertTime(pts, from: sourceClock, to: hostClock),
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        )
        return retimed
    }
}
