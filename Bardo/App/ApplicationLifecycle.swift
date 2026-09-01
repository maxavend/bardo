import AppKit
import Foundation

@MainActor
final class BardoAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        for window in NSApp.windows {
            stabilizeToolbar(in: window)
        }
    }

    @objc
    private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        stabilizeToolbar(in: window)
    }

    private func stabilizeToolbar(in window: NSWindow) {
        guard let toolbar = window.toolbar else { return }

        // Bardo owns a state-driven toolbar; persisting an AppKit representation of
        // SwiftUI-generated items across app/OS versions is both unnecessary and brittle.
        toolbar.autosavesConfiguration = false
        toolbar.allowsUserCustomization = false
        toolbar.allowsDisplayModeCustomization = false
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
