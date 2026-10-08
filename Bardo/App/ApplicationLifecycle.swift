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
        if !BardoApp.isHostingUnitTests {
            InjectionObserver.shared.loadInjectionBundleIfNeeded()
        }
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
            return deferTermination(sender, timeout: Self.finalizationTimeout(forRecordingDuration: microphone.elapsedTime)) {
                await microphone.prepareForApplicationTermination()
            }
        }

        if let systemAudio = SystemAudioRecordingController.activeForApplicationTermination,
           systemAudio.requiresTerminationFinalization {
            return deferTermination(sender, timeout: Self.finalizationTimeout(forRecordingDuration: systemAudio.elapsedTime)) {
                await systemAudio.prepareForApplicationTermination()
            }
        }

        if CaptureRecoveryActivity.isActive {
            return deferTermination(sender, timeout: Self.recoveryTimeout) {
                while CaptureRecoveryActivity.isActive {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }

        return .terminateNow
    }

    /// Saving a recording on quit compresses the microphone and builds the conversation
    /// mix, which grows with the recording: allow 45 s plus 3 minutes per hour of audio,
    /// up to 20 minutes. If ScreenCaptureKit or the encoder never answers, quit anyway:
    /// staged audio is crash-safe and is offered for recovery on the next launch.
    static func finalizationTimeout(forRecordingDuration duration: TimeInterval) -> Duration {
        let hours = max(0, duration.isFinite ? duration : 0) / 3_600
        return .seconds(min(45 + hours * 180, 20 * 60))
    }

    static let recoveryTimeout: Duration = .seconds(300)

    private func deferTermination(
        _ sender: NSApplication,
        timeout: Duration,
        operation: @escaping @MainActor () async -> Void
    ) -> NSApplication.TerminateReply {
        if terminationInProgress {
            return .terminateLater
        }

        terminationInProgress = true
        let reply = TerminationReply(sender)
        Task { @MainActor in
            await operation()
            reply.send()
        }
        Task { @MainActor in
            try? await Task.sleep(for: timeout)
            reply.send()
        }
        return .terminateLater
    }
}

@MainActor
private final class TerminationReply {
    private let application: NSApplication
    private var sent = false

    init(_ application: NSApplication) {
        self.application = application
    }

    func send() {
        guard !sent else { return }
        sent = true
        application.reply(toApplicationShouldTerminate: true)
    }
}
