import AppKit
import Foundation

@MainActor
final class BardoAppDelegate: NSObject, NSApplicationDelegate {
    private var terminationInProgress = false
    private var screenChangeObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.terminationInProgress else { return }
                self.restoreWindowsOnAvailableScreen()
            }
        }

        #if DEBUG
        InjectionObserver.shared.loadInjectionBundleIfNeeded()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
        }
    }

    private func restoreWindowsOnAvailableScreen() {
        guard let targetFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return
        }

        for window in NSApp.windows where window.isVisible && window.canBecomeKey {
            guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(window.frame) }) else {
                continue
            }

            let size = NSSize(
                width: min(window.frame.width, targetFrame.width),
                height: min(window.frame.height, targetFrame.height)
            )
            let origin = NSPoint(
                x: targetFrame.midX - size.width / 2,
                y: targetFrame.midY - size.height / 2
            )
            window.setFrame(NSRect(origin: origin, size: size), display: true)
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
