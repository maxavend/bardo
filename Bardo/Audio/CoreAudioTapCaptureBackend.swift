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
    private let systemLevels = LiveAudioMeter()
    private let microphoneLevels = LiveAudioMeter()

    @MainActor private var tap: SystemAudioTap?
    @MainActor private var microphone: MicrophoneSession?
    @MainActor private var isStopping = false
    private let devices: AudioDevicePreferences

    init(devices: AudioDevicePreferences = AudioDevicePreferences()) {
        self.devices = devices
    }

    @MainActor
    var currentTime: TimeInterval {
        processor.elapsedTime
    }

    @MainActor var systemMeter: LiveAudioMeter? { systemLevels }
    @MainActor var microphoneMeter: LiveAudioMeter? { microphoneLevels }
    @MainActor var microphoneName: String? { microphone?.deviceName }

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
        systemLevels.reset()
        microphoneLevels.reset()

        do {
            let tap = try SystemAudioTap(outputDevice: devices.outputDeviceID(), queue: systemQueue) { [weak self] sampleBuffer, heardSound in
                self?.handle(sampleBuffer, track: .system, heardSound: heardSound)
            }
            self.tap = tap

            if includeMicrophone {
                guard let device = devices.microphoneCaptureDevice() else {
                    throw SystemAudioCaptureError.systemAudio(String(localized: "No microphone is available."))
                }
                let microphone = try MicrophoneSession(device: device, queue: microphoneQueue) { [weak self] sampleBuffer in
                    self?.handle(sampleBuffer, track: .microphone, heardSound: true)
                }
                await microphone.start()
                self.microphone = microphone
            }
            // The tap reads its device's rate only now: opening a Bluetooth microphone
            // switches that device, and so the system audio, to its hands-free rate.
            try tap.start()
            Self.logger.notice("System audio capture started (microphone: \(self.microphone?.deviceName ?? "none", privacy: .public))")
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
        (track == .system ? systemLevels : microphoneLevels).append(sampleBuffer)

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
/// chosen output device, or the default output when none is chosen or it is gone.
private final class SystemAudioTap: @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer, _ heardSound: Bool) -> Void

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var tapFormat = AudioStreamBasicDescription()
    private var converter: SystemAudioFrameConverter?
    private let queue: DispatchQueue
    private let handler: Handler
    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "capture.system-audio")
    private static let nominalRateAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(outputDevice: AudioObjectID?, queue: DispatchQueue, handler: @escaping Handler) throws {
        self.queue = queue
        self.handler = handler

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.currentProcessObjects())
        description.uuid = UUID()
        description.name = "Bardo"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create the system audio tap")

        tapFormat = try Self.property(kAudioTapPropertyFormat, of: tapID, default: AudioStreamBasicDescription())
        Self.logger.notice("Tap format: \(self.tapFormat.mSampleRate, privacy: .public) Hz, \(self.tapFormat.mChannelsPerFrame, privacy: .public) ch, \(self.tapFormat.mBytesPerFrame, privacy: .public) bytes/frame, flags \(self.tapFormat.mFormatFlags, privacy: .public)")

        do {
            guard let outputDevice else {
                throw SystemAudioTapError(action: "find an output device", status: kAudioHardwareBadDeviceError)
            }
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
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID),
                "create the system audio device"
            )
            Self.logger.notice("System audio is clocked by \(outputUID as String, privacy: .public)")
        } catch {
            stop()
            throw error
        }
    }

    deinit {
        stop()
    }

    /// Starts listening. Call it once every other device of the recording is open: a
    /// Bluetooth output changes its rate when its own microphone opens.
    func start() throws {
        // The aggregate runs at its output device's rate, not necessarily the tap's.
        let rate = deviceSampleRate() ?? tapFormat.mSampleRate
        guard let converter = SystemAudioFrameConverter(tapFormat: tapFormat, sampleRate: rate) else {
            throw SystemAudioTapError(action: "describe the system audio format", status: kAudioHardwareUnsupportedOperationError)
        }
        self.converter = converter
        Self.logger.notice("System audio device runs at \(rate, privacy: .public) Hz")

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let rate = self.deviceSampleRate() else { return }
            Self.logger.notice("System audio device rate changed to \(rate, privacy: .public) Hz")
            converter.setSampleRate(rate)
        }
        var address = Self.nominalRateAddress
        if AudioObjectAddPropertyListenerBlock(aggregateID, &address, queue, listener) == noErr {
            rateListener = listener
        }

        let handler = handler
        try Self.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, queue) { _, input, inputTime, _, _ in
                guard let sampleBuffer = converter.sampleBuffer(from: input, at: inputTime.pointee) else { return }
                handler(sampleBuffer, converter.containsSound(input))
            },
            "listen to the system audio device"
        )
        try Self.check(AudioDeviceStart(aggregateID, ioProcID), "start listening to system audio")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var address = Self.nominalRateAddress
                AudioObjectRemovePropertyListenerBlock(aggregateID, &address, queue, rateListener)
                self.rateListener = nil
            }
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

    private func deviceSampleRate() -> Double? {
        let rate: Float64? = AudioHardware.value(kAudioDevicePropertyNominalSampleRate, of: aggregateID)
        return rate.flatMap { $0 > 0 ? $0 : nil }
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
