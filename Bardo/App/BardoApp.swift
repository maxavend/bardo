import Foundation
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
        Self.resetPersistedToolbarConfigurations()
        Self.logger.debug("Bardo application initialized")
    }

    var body: some Scene {
        // Keep the scene identity versioned as an additional boundary against stale
        // window restoration state from older builds.
        Window("Bardo", id: "main-v3-toolbar-reset") {
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

    private static func resetPersistedToolbarConfigurations() {
        let defaults = UserDefaults.standard
        let toolbarKeys = defaults.dictionaryRepresentation().keys.filter {
            $0.hasPrefix("NSToolbar Configuration")
        }

        guard !toolbarKeys.isEmpty else { return }
        for key in toolbarKeys {
            defaults.removeObject(forKey: key)
        }

        logger.notice("Reset \(toolbarKeys.count, privacy: .public) persisted toolbar configuration(s)")
    }
}
