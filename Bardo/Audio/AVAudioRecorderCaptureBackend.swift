import AudioToolbox
import AVFoundation
import AVFAudio
import Foundation

@MainActor
final class AVAudioRecorderCaptureBackend: NSObject, AudioCapturing {
    static let recordingFileExtension = "m4a"
    static let recordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 96_000,
        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
    ]

    var eventHandler: ((AudioCaptureBackendEvent) -> Void)?

    var fileExtension: String {
        Self.recordingFileExtension
    }

    var currentTime: TimeInterval {
        recorder?.currentTime ?? 0
    }

    var inputDisplayName: String? {
        activeInputDisplayName ?? AVCaptureDevice.default(for: .audio)?.localizedName
    }

    var inputLevel: Double {
        guard let recorder, recorder.isRecording else { return 0 }
        recorder.updateMeters()
        let decibels = Double(recorder.averagePower(forChannel: 0))
        guard decibels.isFinite else { return 0 }
        return min(1, max(0, (decibels + 60) / 60))
    }

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    private var recorder: AVAudioRecorder?
    private var activeInputDisplayName: String?
    private var stoppingIntentionally = false

    func start(to url: URL) throws {
        guard recorder == nil else {
            throw AudioCaptureBackendError.alreadyRecording
        }

        guard let inputDevice = AVCaptureDevice.default(for: .audio) else {
            throw AudioCaptureBackendError.noInputDevice
        }

        let candidate: AVAudioRecorder
        do {
            candidate = try AVAudioRecorder(url: url, settings: Self.recordingSettings)
        } catch {
            throw AudioCaptureBackendError.recorderInitialization(error.localizedDescription)
        }

        candidate.delegate = self
        candidate.isMeteringEnabled = true

        guard candidate.prepareToRecord() else {
            candidate.stop()
            throw AudioCaptureBackendError.preparationFailed
        }

        stoppingIntentionally = false
        activeInputDisplayName = inputDevice.localizedName
        recorder = candidate

        guard candidate.record() else {
            stoppingIntentionally = true
            candidate.stop()
            recorder = nil
            throw AudioCaptureBackendError.startFailed
        }
    }

    func pause() {
        guard let recorder, recorder.isRecording else { return }
        recorder.pause()
    }

    func resume() {
        guard let recorder, !recorder.isRecording else { return }
        _ = recorder.record()
    }

    func stop() {
        guard let recorder else { return }
        stoppingIntentionally = true
        recorder.stop()
        self.recorder = nil
    }

    private func reportUnexpectedFinish(successfully flag: Bool, error: Error?) {
        guard !stoppingIntentionally else { return }

        recorder = nil
        let message: String
        if let error {
            message = error.localizedDescription
        } else if flag {
            message = "Microphone recording ended unexpectedly."
        } else {
            message = "Microphone recording stopped because the audio recorder could not continue."
        }
        eventHandler?(.interrupted(message))
    }
}

extension AVAudioRecorderCaptureBackend: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let message = error?.localizedDescription ?? "The audio encoder reported an unknown recording error."
        Task { @MainActor [weak self] in
            self?.reportUnexpectedFinish(successfully: false, error: NSError(
                domain: "Bardo.AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.reportUnexpectedFinish(successfully: flag, error: nil)
        }
    }
}
