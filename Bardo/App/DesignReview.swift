#if DEBUG
import AppKit
import OSLog
import SwiftUI

/// Debug-only visual review. Launch Bardo with
///
///     -BardoDesignCapture <folder> -BardoDesignScenario <steps>
///     [-BardoDesignAppearance light|dark] [-BardoDesignWindowSize 1240x800]
///     [-BardoDesignScreen sharpest] [-BardoDesignComposite YES] [-BardoDesignForceActive YES]
///     [-BardoDesignMicrophone <name>]
///
/// to drive the real windows into a known state, capture each visible window to PNG
/// and quit. `<steps>` is a `+`-separated list such as `section:recordings` or
/// `open:0+inspector`. Use an isolated `CFFIXED_USER_HOME` and bundle identifier so
/// the review never reads or changes a real Library; `tools/portfolio/capture.py`
/// shows a complete run.
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

    /// `-BardoDesignWelcome YES` shows the first-run welcome without resetting setup.
    static var showsWelcome: Bool { isActive && arguments.bool(forKey: "BardoDesignWelcome") }
    /// `-BardoDesignWelcome engine` opens the welcome on its choice of transcription.
    static var welcomeStartsOnChoice: Bool { isActive && arguments.string(forKey: "BardoDesignWelcome") == "engine" }
    /// `-BardoDesignSettings <tab>` shows that Settings tab in the main window, where
    /// captures see it.
    static var settingsTab: String? { isActive ? arguments.string(forKey: "BardoDesignSettings") : nil }

    /// Whether `-BardoDesignAppearance` chose the appearance, over the app's own setting.
    static var forcesAppearance: Bool {
        isActive && arguments.string(forKey: "BardoDesignAppearance") != nil
    }

    /// `-BardoDesignSetup downloading|optimizing|paused|failed` shows first-run setup in
    /// that state without touching the models.
    static var setupState: TranscriptionSetupCoordinator.State? {
        guard isActive else { return nil }
        switch arguments.string(forKey: "BardoDesignSetup") {
        case "downloading": return .installing(.init(stage: .downloading, fractionCompleted: 0.42))
        case "optimizing": return .installing(.init(stage: .optimizingForMac, fractionCompleted: 1))
        case "paused": return .cancelled
        case "failed": return .failed(String(localized: "Bardo could not connect to the internet. Check your connection and try again."))
        default: return nil
        }
    }

    /// `-BardoDesignMicrophone <name>` shows that input device instead of the Mac's own.
    static var microphoneName: String? {
        isActive ? arguments.string(forKey: "BardoDesignMicrophone") : nil
    }

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

        if arguments.bool(forKey: "BardoDesignForceActive") { drawFrontWindowAsActive() }

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            NSApp.activate()
            resizeMainWindow()
            refreshActiveAppearance()
            for step in steps {
                perform(step)
                refreshActiveAppearance()
                try? await Task.sleep(for: .seconds(step.action == "wait" ? Double(step.value) ?? 1 : 0.9))
            }
            try? await Task.sleep(for: .seconds(1.2))
            if placeWindowsOnSharpestScreen() {
                try? await Task.sleep(for: .seconds(0.8))
            }
            // Capture the window as active even if another app took focus meanwhile.
            for _ in 0..<10 where !NSApp.isActive {
                NSRunningApplication.current.activate(options: [.activateAllWindows])
                try? await Task.sleep(for: .seconds(0.3))
            }
            NSApp.activate()
            refreshActiveAppearance()
            try? await Task.sleep(for: .seconds(0.4))
            // File names stop at 255 bytes; scenarios with paths can be longer.
            let name = String(scenario.replacingOccurrences(of: ":", with: "-").suffix(120))
            if steps.contains(where: { $0.action == "menus" }) {
                writeMenus(into: directory, name: name)
            }
            if arguments.bool(forKey: "BardoDesignComposite") {
                captureComposited(into: directory, name: name)
            } else {
                capture(into: directory, name: name)
            }
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
        placeWindowsOnSharpestScreen()
    }

    /// With `-BardoDesignScreen sharpest`, moves every window to the screen with the
    /// highest backing scale, so captures come out at Retina resolution even when the
    /// main display is not. Returns whether a window moved.
    @discardableResult
    private static func placeWindowsOnSharpestScreen() -> Bool {
        guard arguments.string(forKey: "BardoDesignScreen") == "sharpest",
              let screen = NSScreen.screens.max(by: { $0.backingScaleFactor < $1.backingScaleFactor }) else {
            return false
        }
        var moved = false
        // Sheets and popovers follow their parent window.
        for window in NSApp.windows where window.isVisible && window.sheetParent == nil && window.parent == nil
            && window.screen != screen && window.frame.width > 160 {
            let area = screen.visibleFrame
            let origin = NSPoint(
                x: area.midX - window.frame.width / 2,
                y: max(area.minY, area.midY - window.frame.height / 2)
            )
            window.setFrameOrigin(origin)
            moved = true
        }
        return moved
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

extension DesignReview {
    /// `-BardoDesignComposite YES`: captures each top-level window with its sheets and
    /// popovers drawn on top, where they appear on screen. `-BardoDesignRenderer view`
    /// draws the views directly instead of reading what WindowServer composited.
    fileprivate static func captureComposited(into directory: URL, name: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawsViews = arguments.string(forKey: "BardoDesignRenderer") == "view"
        func image(of window: NSWindow) -> CGImage? {
            if !drawsViews, let composited = compositedImage(of: window), !isBlank(composited) {
                return composited
            }
            guard let frameView = window.contentView?.superview ?? window.contentView,
                  let drawn = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
            frameView.cacheDisplay(in: frameView.bounds, to: drawn)
            return drawn.cgImage
        }
        func attached(to window: NSWindow) -> [NSWindow] {
            NSApp.windows.filter { $0.isVisible && ($0.sheetParent === window || $0.parent === window) }
                .flatMap { [$0] + attached(to: $0) }
        }
        let topLevel = NSApp.windows.filter {
            $0.isVisible && $0.sheetParent == nil && $0.parent == nil && $0.frame.width > 160 && $0.frame.height > 80
        }
        for (index, window) in topLevel.enumerated() {
            guard let base = image(of: window) else { continue }
            let scale = CGFloat(base.width) / window.frame.width
            // Popovers can reach past the window's edge; the canvas grows to show them whole.
            let children = attached(to: window)
            let bounds = children.reduce(window.frame) { $0.union($1.frame) }
            guard let context = CGContext(
                data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { continue }
            func place(_ frame: NSRect) -> CGRect {
                CGRect(
                    x: (frame.minX - bounds.minX) * scale,
                    y: (frame.minY - bounds.minY) * scale,
                    width: frame.width * scale,
                    height: frame.height * scale
                )
            }
            context.draw(base, in: place(window.frame))
            for child in children {
                guard let overlay = image(of: child) else { continue }
                context.draw(overlay, in: place(child.frame))
            }
            guard let stacked = context.makeImage() else { continue }
            let suffix = topLevel.count > 1 && window !== mainWindow
                ? "-\(index)-\(window.title.isEmpty ? "window" : window.title)" : ""
            let url = directory.appendingPathComponent("\(name)\(suffix).png".replacingOccurrences(of: "/", with: "-"))
            do {
                try NSBitmapImageRep(cgImage: stacked).representation(using: .png, properties: [:])?.write(to: url)
            } catch {
                logger.error("Design capture failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

extension DesignReview {
    /// macOS lets an app activate itself only when the person is not using another one,
    /// so a review that runs while they work would capture inactive windows. With
    /// `-BardoDesignForceActive YES` the front window (and its sheet) report themselves
    /// as key and main, and the app as active, so their controls draw as when focused.
    /// The sidebar's accent follows WindowServer and still needs Bardo to be frontmost.
    fileprivate static func drawFrontWindowAsActive() {
        func exchange(_ type: AnyClass, _ original: Selector, _ replacement: Selector) {
            guard let a = class_getInstanceMethod(type, original),
                  let b = class_getInstanceMethod(type, replacement) else { return }
            method_exchangeImplementations(a, b)
        }
        exchange(NSWindow.self, #selector(getter: NSWindow.isKeyWindow), #selector(getter: NSWindow.designReviewIsKeyWindow))
        exchange(NSWindow.self, #selector(getter: NSWindow.isMainWindow), #selector(getter: NSWindow.designReviewIsMainWindow))
        exchange(NSApplication.self, #selector(getter: NSApplication.isActive), #selector(getter: NSApplication.designReviewIsActive))
        // Window controls and selection accents follow AppKit's private "active appearance"
        // state of the window rather than its key status.
        for name in ["_hasActiveAppearance", "_hasActiveAppearanceIgnoringKeyFocus", "_hasKeyAppearance", "_hasMainAppearance"] {
            let selector = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(NSWindow.self, selector) else { continue }
            let block: @convention(block) (NSWindow) -> Bool = { window in
                guard let front = DesignReview.frontWindow else { return false }
                var chain = window
                while let parent = chain.sheetParent ?? chain.parent { chain = parent }
                return chain === front
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }

    /// The Settings window while it is open, otherwise the main window.
    static var frontWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.contains("Settings") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain && $0.sheetParent == nil && $0.parent == nil }
    }

    /// Asks every window to redraw with its (possibly forced) active state.
    fileprivate static func refreshActiveAppearance() {
        guard arguments.bool(forKey: "BardoDesignForceActive") else { return }
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        for window in NSApp.windows where window.isVisible {
            if window.isMainWindow { NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: window) }
            if window.isKeyWindow { NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window) }
            func invalidate(_ view: NSView) {
                view.needsDisplay = true
                view.subviews.forEach(invalidate)
            }
            (window.contentView?.superview ?? window.contentView).map(invalidate)
        }
    }
}

extension NSWindow {
    @objc fileprivate var designReviewIsKeyWindow: Bool {
        guard var key = DesignReview.frontWindow else { return false }
        while let sheet = key.attachedSheet { key = sheet }
        return self === key
    }

    @objc fileprivate var designReviewIsMainWindow: Bool {
        self === DesignReview.frontWindow
    }
}

extension NSApplication {
    @objc fileprivate var designReviewIsActive: Bool { true }
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
