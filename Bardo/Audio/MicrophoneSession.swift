import AVFoundation
import CoreMedia
import Foundation

/// One microphone through AVCaptureSession, delivered as 48 kHz mono Float32 and
/// restamped on the host clock the system tap uses, so the two tracks line up. Whatever
/// rate the device runs at, such as a Bluetooth headset's 16 kHz, AVFoundation resamples.
final class MicrophoneSession: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    typealias Handler = @Sendable (CMSampleBuffer) -> Void

    static let sampleRate: Double = 48_000

    let deviceName: String
    /// Called once, on the main actor, when the microphone stops delivering audio because
    /// it was disconnected or the capture session failed.
    @MainActor var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let device: AVCaptureDevice
    private let handler: Handler
    private var observers: [NSObjectProtocol] = []

    init(device: AVCaptureDevice, queue: DispatchQueue, handler: @escaping Handler) throws {
        self.device = device
        self.deviceName = device.localizedName
        self.handler = handler
        super.init()

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
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

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.fail(String(localized: "The microphone was disconnected."))
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated {
                self?.fail(error?.localizedDescription ?? String(localized: "The microphone stopped unexpectedly."))
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    var isRunning: Bool { session.isRunning }

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
                self.stopNow()
                continuation.resume()
            }
        }
    }

    /// Stops right away, for callers that must finish synchronously.
    func stopNow() {
        session.stopRunning()
    }

    @MainActor
    private func fail(_ message: String) {
        guard let onFailure else { return }
        self.onFailure = nil
        onFailure(message)
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
