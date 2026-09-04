import AppKit
import Darwin
import Foundation

@MainActor
final class BardoAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        InjectionObserver.shared.loadInjectionBundleIfNeeded()
        #endif

        guard WhisperBenchmarkConfiguration.isRequested else { return }

        // Benchmark mode is opt-in via environment and intentionally bypasses normal UI work.
        // Running the Release executable directly keeps measurements representative of production.
        NSApp.hide(nil)
        Task {
            let status = await WhisperPhysicalBenchmarkRunner.runFromEnvironment()
            exit(status)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let microphone = MicrophoneRecordingController.activeForApplicationTermination,
           microphone.requiresTerminationFinalization {
            return deferTermination(sender) {
                await microphone.prepareForApplicationTermination()
            }
        }

        if let systemAudio = SystemAudioRecordingController.activeForApplicationTermination,
           systemAudio.requiresTerminationFinalization {
            return deferTermination(sender) {
                await systemAudio.prepareForApplicationTermination()
            }
        }

        return .terminateNow
    }

    private func deferTermination(
        _ sender: NSApplication,
        operation: @escaping @MainActor () async -> Void
    ) -> NSApplication.TerminateReply {
        if terminationInProgress {
            return .terminateLater
        }

        terminationInProgress = true
        Task { @MainActor in
            await operation()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
