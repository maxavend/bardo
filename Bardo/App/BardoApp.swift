import OSLog
import SwiftUI

@main
struct BardoApp: App {
    @NSApplicationDelegateAdaptor(BardoAppDelegate.self) private var appDelegate
    @StateObject private var recordingMenuBar = RecordingMenuBar.shared

    static let mainWindowID = "main-v3-native-toolbar"

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
        Window("Bardo", id: Self.mainWindowID) {
            Group {
                if Self.isHostingUnitTests {
                    Color.clear
                } else {
                    BardoLaunchView()
                }
            }
            .groupBoxStyle(.bardoCard)
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

        // Only while Bardo records, so a recording in the background stays in sight.
        MenuBarExtra(isInserted: Binding(get: { recordingMenuBar.state != nil }, set: { _ in })) {
            RecordingMenuBarMenu(model: recordingMenuBar)
        } label: {
            if let state = recordingMenuBar.state {
                RecordingMenuBarLabel(state: state, clock: recordingMenuBar.clock)
            }
        }
    }
}