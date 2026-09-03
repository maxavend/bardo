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
                .frame(minWidth: 1080, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
