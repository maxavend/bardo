import OSLog
import SwiftUI

@main
struct BardoApp: App {
    @NSApplicationDelegateAdaptor(BardoAppDelegate.self) private var appDelegate

    private static let logger = Logger(
        subsystem: "com.maxavend.bardo",
        category: "application"
    )

    /// Unit tests are hosted inside Bardo.app. The host must not open the real Library,
    /// recover captures or warm models from the developer's Application Support data.
    static let isHostingUnitTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    init() {
        Self.logger.debug("Bardo application initialized")
    }

    var body: some Scene {
        Window("Bardo", id: "main-v3-native-toolbar") {
            Group {
                if Self.isHostingUnitTests {
                    Color.clear
                } else {
                    BardoLaunchView()
                }
            }
            .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: BardoLayout.windowDefaultWidth, height: 800)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            SidebarCommands()
            ToolbarCommands()
            BardoCommands()
        }

        Settings {
            SettingsView()
        }
    }
}