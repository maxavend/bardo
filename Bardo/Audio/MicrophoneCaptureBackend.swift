import Accelerate
import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

/// Records the chosen microphone, or the macOS default one, to linear PCM.
///
/// AVAudioRecorder can only use the default input, so Bardo opens the device itself
/// through `MicrophoneSession` and writes what it hears to a CAF file.
@MainActor
final class MicrophoneCaptureBackend: AudioCapturing {
    /// Linear PCM in CAF stays readable up to the last written sample if Bardo crashes,
    /// is force quit or loses power. The controller compresses it to AAC after stopping.
    static let recordingFileExtension = "caf"
    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false
    ]

    var eventHandler: ((AudioCaptureBackendEvent) -> Void)?

    var fileExtension: String {
        Self.recordingFileExtension
    }

    var currentTime: TimeInterval {
        writer?.duration ?? 0
    }

    var inputDisplayName: String? {
        session?.deviceName ?? devices.microphoneCaptureDevice()?.localizedName
    }

    var inputLevel: Double {
        guard let writer, isRecording else { return 0 }
        return writer.level
    }

    var meter: LiveAudioMeter? { levels }

    var inputDeviceUID: String? { session?.deviceUID }

    func switchInput(toDeviceUID uid: String) throws {
        guard let session else { throw AudioCaptureBackendError.noInputDevice }
        guard let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) else {
            throw AudioCaptureBackendError.noInputDevice
        }
        try session.switchDevice(to: device)
    }

    var isRecording: Bool {
        session != nil && writer?.isPaused == false
    }

    private let devices: AudioDevicePreferences
    private let queue = DispatchQueue(label: "com.maxavend.bardo.microphone", qos: .userInitiated)
    private var session: MicrophoneSession?
    private var writer: MicrophoneFileWriter?
    private let levels = LiveAudioMeter()

    init(devices: AudioDevicePreferences = AudioDevicePreferences()) {
        self.devices = devices
    }

    func start(to url: URL) async throws {
        guard session == nil else {
            throw AudioCaptureBackendError.alreadyRecording
        }
        guard let device = devices.microphoneCaptureDevice() else {
            throw AudioCaptureBackendError.noInputDevice
        }

        let writer: MicrophoneFileWriter
        let session: MicrophoneSession
        do {
            levels.reset()
            writer = try MicrophoneFileWriter(url: url, settings: Self.recordingSettings, meter: levels)
            session = try MicrophoneSession(device: device, queue: queue) { sampleBuffer in
                writer.append(sampleBuffer)
            }
        } catch {
            throw AudioCaptureBackendError.recorderInitialization(error.localizedDescription)
        }
        session.onFailure = { [weak self] message in
            self?.reportFailure(message)
        }

        self.writer = writer
        self.session = session
        await session.start()
        guard session.isRunning, self.session === session else {
            self.session = nil
            self.writer = nil
            await session.stop()
            queue.sync { }
            writer.close()
            throw AudioCaptureBackendError.startFailed
        }
    }

    func pause() {
        writer?.isPaused = true
    }

    func resume() {
        writer?.isPaused = false
    }

    func stop() {
        guard let session else { return }
        session.onFailure = nil
        session.stopNow()
        // Write every buffer already delivered before the file is closed.
        queue.sync { }
        writer?.close()
        self.session = nil
    }

    private func reportFailure(_ message: String) {
        guard session != nil else { return }
        eventHandler?(.interrupted(message))
    }
}

/// Appends microphone buffers to a linear PCM file and meters them. Buffers arrive on the
/// capture queue; the main actor reads the duration and level.
final class MicrophoneFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    // Guarded by `lock`.
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var framesWritten: AVAudioFramePosition = 0
    private var paused = false
    private var lastLevel: Double = 0
    private let sampleRate: Double
    private let meter: LiveAudioMeter?

    init(url: URL, settings: [String: Any], meter: LiveAudioMeter? = nil) throws {
        self.meter = meter
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        self.file = file
        self.sampleRate = file.processingFormat.sampleRate
    }

    var duration: TimeInterval {
        lock.bardoWithLock { Double(framesWritten) / sampleRate }
    }

    /// The last buffer's loudness from 0 to 1, on the same -60 dB scale as the meters.
    var level: Double {
        lock.bardoWithLock { lastLevel }
    }

    var isPaused: Bool {
        get { lock.bardoWithLock { paused } }
        set { lock.bardoWithLock { paused = newValue; if newValue { lastLevel = 0 } } }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        lock.bardoWithLock {
            guard !paused, let file, let buffer = pcmBuffer(from: sampleBuffer, writingTo: file.processingFormat) else { return }
            do {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                lastLevel = Self.level(of: buffer)
                if let samples = buffer.floatChannelData?[0] {
                    meter?.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)), frames: Int(buffer.frameLength), sampleRate: sampleRate)
                }
            } catch {
                // A full disk ends the file where it is; what was written stays readable.
                self.file = nil
            }
        }
    }

    func close() {
        lock.bardoWithLock {
            file?.close()
            file = nil
        }
    }

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer, writingTo target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: streamDescription)
        else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        source.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: source.mutableAudioBufferList
        ) == noErr else { return nil }

        if format == target { return source }
        // The session delivers the file's own format; convert anything else rather than drop it.
        if converter?.inputFormat != format {
            converter = AVAudioConverter(from: format, to: target)
        }
        guard let converter else { return nil }
        let capacity = AVAudioFrameCount((Double(frames) * target.sampleRate / format.sampleRate).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var pending: AVAudioPCMBuffer? = source
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard let next = pending else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            pending = nil
            inputStatus.pointee = .haveData
            return next
        }
        return status != .error && output.frameLength > 0 ? output : nil
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Double {
        guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(buffer.frameLength))
        guard rms > 0 else { return 0 }
        let decibels = 20 * Double(log10(rms))
        return min(1, max(0, (decibels + 60) / 60))
    }
}
