import AppKit
import Foundation

@MainActor
final class BardoAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller = MicrophoneRecordingController.activeForApplicationTermination,
              controller.requiresTerminationFinalization else {
            return .terminateNow
        }

        if terminationInProgress {
            return .terminateLater
        }

        terminationInProgress = true
        Task {
            await controller.prepareForApplicationTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
