import OSLog
import SwiftUI

@main
struct BardoApp: App {
    @NSApplicationDelegateAdaptor(BardoAppDelegate.self) private var appDelegate
    @AppStorage(BardoLanguage.storageKey) private var languageRaw = BardoLanguage.preferredDefault.rawValue

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "application"
    )

    private var language: BardoLanguage {
        BardoLanguage.resolve(languageRaw)
    }

    init() {
        Self.logger.debug("Bardo application initialized")
    }

    var body: some Scene {
        Window("Bardo", id: "main") {
            BardoLaunchView()
                .environment(\.locale, language.locale)
                .frame(minWidth: 760, minHeight: 520)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            BardoSettingsView()
        }
    }
}
