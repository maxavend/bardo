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
        // Version the scene identity once so macOS does not restore the anonymous toolbar
        // layout written by older Bardo builds. The previous layout can contain generated
        // SwiftUI item identifiers that are no longer valid after the toolbar redesign.
        Window("Bardo", id: "main-v2-toolbar") {
            BardoLaunchView()
                .environment(\.locale, language.locale)
                // 840pt keeps the detail column useful with the sidebar visible,
                // while remaining practical on smaller notebook displays.
                .frame(minWidth: 840, minHeight: 540)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            BardoSettingsView()
        }
    }
}
