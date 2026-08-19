import OSLog
import SwiftUI

@main
struct BardoApp: App {
    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "application"
    )

    init() {
        Self.logger.debug("Bardo application initialized")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 900, height: 600)
    }
}
