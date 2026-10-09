#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// Debug-only visual review. Launch Bardo with
///
///     -BardoDesignCapture <folder> -BardoDesignScenario <steps>
///     [-BardoDesignAppearance light|dark] [-BardoDesignWindowSize 1240x800]
///
/// to drive the real windows into a known state, capture each visible window to PNG
/// and quit. `<steps>` is a `+`-separated list such as `section:recordings` or
/// `open:0+inspector`. Use an isolated `CFFIXED_USER_HOME` and bundle identifier so
/// the review never reads or changes a real Library.
@MainActor
enum DesignReview {
    struct Step: Sendable {
        let action: String
        let value: String
    }

    static let command = Notification.Name("Bardo.DesignReview.Command")
    private static let logger = Logger(subsystem: "com.maxavend.bardo", category: "design-review")

    private static var arguments: UserDefaults { .standard }

    static var isActive: Bool { captureDirectory != nil }

    private static var captureDirectory: URL? {
        arguments.string(forKey: "BardoDesignCapture").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func start() {
        guard let directory = captureDirectory else { return }
        let scenario = arguments.string(forKey: "BardoDesignScenario") ?? "launch"
        let steps = scenario.split(separator: "+").map { token -> Step in
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            return Step(action: parts[0], value: parts.count > 1 ? parts[1] : "")
        }

        switch arguments.string(forKey: "BardoDesignAppearance") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            NSApp.activate()
            resizeMainWindow()
            for step in steps {
                perform(step)
                try? await Task.sleep(for: .seconds(step.action == "wait" ? Double(step.value) ?? 1 : 0.9))
            }
            try? await Task.sleep(for: .seconds(1.2))
            NSApp.activate()
            try? await Task.sleep(for: .seconds(0.3))
            let name = scenario.replacingOccurrences(of: ":", with: "-")
            if steps.contains(where: { $0.action == "menus" }) {
                writeMenus(into: directory, name: name)
            }
            capture(into: directory, name: name)
            // `terminate` waits for open sheets and alerts; the review owns no user data.
            exit(0)
        }
    }

    private static func perform(_ step: Step) {
        switch step.action {
        case "newRecording":
            NotificationCenter.default.post(name: BardoCommandNotification.newRecording, object: nil)
        case "key":
            mainWindow?.makeKeyAndOrderFront(nil)
        case "wait", "menus":
            break
        case "focusList":
            focusTable(at: Int(step.value) ?? 1)
        case "press":
            press(step.value)
        default:
            NotificationCenter.default.post(
                name: command,
                object: nil,
                userInfo: ["action": step.action, "value": step.value]
            )
        }
    }

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0.title.contains("Ajustes") || $0.title.contains("Settings")) }
    }

    private static func resizeMainWindow() {
        guard let value = arguments.string(forKey: "BardoDesignWindowSize"),
              let window = mainWindow else { return }
        let parts = value.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return }
        window.setContentSize(NSSize(width: parts[0], height: parts[1]))
        window.center()
    }

    private static func capture(into directory: URL, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let windows = NSApp.windows.filter { $0.isVisible && $0.frame.width > 160 && $0.frame.height > 80 }
        for (index, window) in windows.enumerated() {
            let representation: NSBitmapImageRep
            // A locked screen composites every window as a blank sheet; draw the views
            // directly then (without glass or vibrancy, but with the real layout).
            if let composited = compositedImage(of: window), !isBlank(composited) {
                representation = NSBitmapImageRep(cgImage: composited)
            } else {
                guard let frameView = window.contentView?.superview ?? window.contentView,
                      let drawn = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { continue }
                frameView.cacheDisplay(in: frameView.bounds, to: drawn)
                representation = drawn
            }
            let suffix = windows.count > 1 ? "-\(index)-\(window.title.isEmpty ? "window" : window.title)" : ""
            let url = directory.appendingPathComponent("\(name)\(suffix).png".replacingOccurrences(of: "/", with: "-"))
            do {
                try representation.representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                logger.error("Design capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension DesignReview {
    /// Gives keyboard focus to one of the window's lists, ordered left to right
    /// (0 is the sidebar, 1 the conversation list), as a click would.
    fileprivate static func focusTable(at index: Int) {
        guard let window = mainWindow, let root = window.contentView else { return }
        func tables(in view: NSView) -> [NSTableView] {
            (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap(tables(in:))
        }
        let sorted = tables(in: root).sorted {
            $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX
        }
        guard sorted.indices.contains(index) else { return }
        window.makeFirstResponder(sorted[index])
    }

    /// Sends a real key press through the window, exactly as the keyboard would.
    fileprivate static func press(_ key: String) {
        guard let window = NSApp.keyWindow ?? mainWindow else { return }
        let keys: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
            "down": (125, "\u{F701}", [.numericPad, .function]),
            "up": (126, "\u{F700}", [.numericPad, .function]),
            "space": (49, " ", []),
            "return": (36, "\r", []),
            "escape": (53, "\u{1B}", []),
            "delete": (51, "\u{7F}", []),
            "tab": (48, "\t", [])
        ]
        guard let (code, characters, flags) = keys[key] else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
            ) {
                NSApp.sendEvent(event)
            }
        }
    }

    /// Every menu item with its shortcut and enabled state, to review the menu bar.
    fileprivate static func writeMenus(into directory: URL, name: String) {
        func describe(_ menu: NSMenu, depth: Int) -> [String] {
            menu.update()
            return menu.items.filter { !$0.isHidden }.flatMap { item -> [String] in
                guard !item.isSeparatorItem else { return [String(repeating: "  ", count: depth) + "—"] }
                var line = String(repeating: "  ", count: depth) + item.title
                if !item.keyEquivalent.isEmpty {
                    let flags = item.keyEquivalentModifierMask
                    let modifiers = [
                        flags.contains(.control) ? "⌃" : "",
                        flags.contains(.option) ? "⌥" : "",
                        flags.contains(.shift) ? "⇧" : "",
                        flags.contains(.command) ? "⌘" : ""
                    ].joined()
                    line += "\t\(modifiers)\(item.keyEquivalent == " " ? "Space" : item.keyEquivalent.uppercased())"
                }
                if !item.isEnabled { line += "\t(disabled)" }
                return [line] + (item.submenu.map { describe($0, depth: depth + 1) } ?? [])
            }
        }
        guard let menu = NSApp.mainMenu else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = describe(menu, depth: 0).joined(separator: "\n")
        try? text.write(to: directory.appendingPathComponent("\(name)-menus.txt"), atomically: true, encoding: .utf8)
    }

    /// The window as WindowServer composites it, with real Liquid Glass, vibrancy and
    /// selection. An app may capture its own windows; the call is looked up at runtime
    /// because the SDK no longer exposes it to Swift.
    fileprivate static func isBlank(_ image: CGImage) -> Bool {
        let representation = NSBitmapImageRep(cgImage: image)
        guard let first = representation.colorAt(x: 0, y: 0) else { return true }
        let step = max(1, min(image.width, image.height) / 24)
        for x in stride(from: 0, to: image.width, by: step) {
            for y in stride(from: 0, to: image.height, by: step) where representation.colorAt(x: x, y: y) != first {
                return false
            }
        }
        return true
    }

    fileprivate static func compositedImage(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let handle = dlopen(nil, RTLD_NOW),
              let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFramingAndBestResolution: UInt32 = (1 << 0) | (1 << 3)
        guard let image = capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFramingAndBestResolution)?
            .takeRetainedValue(),
              image.width > 1 else { return nil }
        return image
    }
}

extension View {
    /// Lets the debug design review drive this view into a known state.
    func onDesignReviewCommand(perform action: @escaping (DesignReview.Step) -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: DesignReview.command)) { notification in
            guard let name = notification.userInfo?["action"] as? String else { return }
            action(DesignReview.Step(action: name, value: notification.userInfo?["value"] as? String ?? ""))
        }
    }
}
#endif
