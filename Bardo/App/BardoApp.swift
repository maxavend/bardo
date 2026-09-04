import OSLog
import SwiftUI

@main
struct BardoApp: App {
    @NSApplicationDelegateAdaptor(BardoAppDelegate.self) private var appDelegate

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "application"
    )

    init() {
        Self.logger.debug("Bardo application initialized")
    }

    var body: some Scene {
        Window("Bardo", id: "main") {
            BardoLaunchView()
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1240, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
    }
}