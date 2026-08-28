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
            RootView()
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
    }
}
