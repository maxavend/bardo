import AppKit
import SwiftUI

/// The displayed text and its playback targets use the same character ranges.
enum TranscriptPlaybackText {
    private static let seekScheme = "bardo-seek"

    static func time(in link: Any) -> TimeInterval? {
        guard let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:)), url.scheme == seekScheme,
              let time = TimeInterval(url.lastPathComponent), time.isFinite, time >= 0 else { return nil }
        return time
    }

    static func attributed(
        segments: [TranscriptSegment], position: TimeInterval?, searchQuery: String, canSeek: Bool
    ) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 4
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: style
        ]
        let result = NSMutableAttributedString(string: "")
        for segment in segments {
            if result.length > 0 { result.append(NSAttributedString(string: " ", attributes: attributes)) }
            let text = segment.displayText
            let piece = NSMutableAttributedString(string: text, attributes: attributes)
            if canSeek { link(piece, range: NSRange(location: 0, length: piece.length), to: segment.startTime) }

            let tokens = text.split(whereSeparator: \.isWhitespace)
            if segment.editedText == nil, tokens.count == segment.words.count {
                for (token, word) in zip(tokens, segment.words) {
                    guard TranscriptTextSanitizer.wordKey(token) == TranscriptTextSanitizer.wordKey(word.text) else {
                        continue
                    }
                    let range = NSRange(token.startIndex..<token.endIndex, in: text)
                    if canSeek { link(piece, range: range, to: word.startTime) }
                    if let position {
                        if position >= word.startTime, position <= word.endTime {
                            piece.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
                        } else if position < word.startTime {
                            piece.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: range)
                        }
                    }
                }
            }
            result.append(piece)
        }
        let text = result.string as NSString
        for term in LibraryFormatting.searchTerms(searchQuery) {
            var start = 0
            while start < text.length {
                let range = text.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: start, length: text.length - start)
                )
                guard range.location != NSNotFound else { break }
                result.addAttributes([.backgroundColor: NSColor.findHighlightColor, .foregroundColor: NSColor.black], range: range)
                start = NSMaxRange(range)
            }
        }
        return result
    }

    private static func link(_ text: NSMutableAttributedString, range: NSRange, to time: TimeInterval) {
        guard range.length > 0, time.isFinite, time >= 0,
              let url = URL(string: "\(seekScheme)://audio/\(time)") else { return }
        text.addAttribute(.link, value: url, range: range)
    }
}

/// AppKit keeps link clicks and drag selection in the same selectable text view.
struct SelectablePlaybackText: NSViewRepresentable {
    enum Command {
        case action(String, enabled: Bool = true, checked: Bool = false, perform: () -> Void)
        case submenu(String, [Command])
        case separator
    }

    let text: NSAttributedString
    let commands: [Command]
    let seek: (TimeInterval) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSTextView {
        let view = PlaybackTextView(usingTextLayoutManager: false)
        view.delegate = context.coordinator
        view.commands = { [weak coordinator = context.coordinator] in coordinator?.makeMenu() }
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = true
        view.isAutomaticLinkDetectionEnabled = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.linkTextAttributes = [:]
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.commands = commands
        context.coordinator.seek = seek
        guard let storage = view.textStorage, !storage.isEqual(to: text) else { return }
        let selection = storage.string == text.string ? view.selectedRanges : []
        storage.setAttributedString(text)
        if !selection.isEmpty { view.selectedRanges = selection }
        (view as? PlaybackTextView)?.refreshHover()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0,
              let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        return CGSize(width: width, height: ceil(layout.usedRect(for: container).height))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var commands: [Command] = []
        var seek: (TimeInterval) -> Void = { _ in }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard let time = TranscriptPlaybackText.time(in: link) else { return false }
            seek(time)
            return true
        }

        func makeMenu() -> NSMenu {
            menu(for: commands)
        }

        private func menu(for commands: [Command]) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for command in commands {
                switch command {
                case .action(let title, let enabled, let checked, let perform):
                    let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
                    item.target = self
                    item.isEnabled = enabled
                    item.state = checked ? .on : .off
                    item.representedObject = perform
                    menu.addItem(item)
                case .submenu(let title, let commands):
                    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                    item.submenu = self.menu(for: commands)
                    menu.addItem(item)
                case .separator:
                    menu.addItem(.separator())
                }
            }
            return menu
        }

        @objc private func performCommand(_ item: NSMenuItem) {
            (item.representedObject as? () -> Void)?()
        }
    }

    final class PlaybackTextView: NSTextView {
        private struct PlaybackLink {
            let value: Any
            let character: Int
            let range: NSRange
        }

        var commands: () -> NSMenu? = { nil }
        private var hoverTrackingArea: NSTrackingArea?
        private var hoveredRange: NSRange?
        private var pendingMouseDown: NSEvent?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let tracking = NSTrackingArea(
                rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate],
                owner: self
            )
            addTrackingArea(tracking)
            hoverTrackingArea = tracking
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            showHover(at: event.locationInWindow)
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            showHover(at: event.locationInWindow)
        }

        override func mouseExited(with event: NSEvent) {
            setHoveredRange(nil)
            super.mouseExited(with: event)
        }

        override func cursorUpdate(with event: NSEvent) {
            if playbackLink(at: event.locationInWindow) != nil {
                NSCursor.pointingHand.set()
            } else {
                super.cursorUpdate(with: event)
            }
        }

        override func mouseDown(with event: NSEvent) {
            pendingMouseDown = nil
            let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
            guard event.clickCount == 1, event.modifierFlags.intersection(modifiers).isEmpty,
                  playbackLink(at: event.locationInWindow) != nil else {
                super.mouseDown(with: event)
                return
            }
            pendingMouseDown = event
        }

        override func mouseDragged(with event: NSEvent) {
            guard let down = pendingMouseDown else {
                super.mouseDragged(with: event)
                return
            }
            let dx = event.locationInWindow.x - down.locationInWindow.x
            let dy = event.locationInWindow.y - down.locationInWindow.y
            guard dx * dx + dy * dy >= 9 else { return }
            pendingMouseDown = nil
            // Hand the original press back to AppKit for normal drag-to-select.
            NSApp.postEvent(event, atStart: true)
            super.mouseDown(with: down)
        }

        override func mouseUp(with event: NSEvent) {
            guard let down = pendingMouseDown else {
                super.mouseUp(with: event)
                return
            }
            pendingMouseDown = nil
            guard let pressed = playbackLink(at: down.locationInWindow),
                  let released = playbackLink(at: event.locationInWindow),
                  pressed.range == released.range else { return }
            clicked(onLink: released.value, at: released.character)
        }

        func refreshHover() {
            guard hoveredRange != nil, let window else { return }
            setHoveredRange(nil)
            showHover(at: window.mouseLocationOutsideOfEventStream)
        }

        private func showHover(at point: NSPoint) {
            let range = playbackLink(at: point)?.range
            setHoveredRange(range)
            (range == nil ? NSCursor.iBeam : .pointingHand).set()
        }

        private func playbackLink(at location: NSPoint) -> PlaybackLink? {
            let local = convert(location, from: nil)
            guard visibleRect.contains(local), let container = textContainer,
                  let layout = layoutManager, let storage = textStorage, storage.length > 0 else { return nil }
            let point = NSPoint(x: local.x - textContainerOrigin.x, y: local.y - textContainerOrigin.y)
            let glyph = layout.glyphIndex(for: point, in: container)
            guard glyph < layout.numberOfGlyphs,
                  layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point)
            else { return nil }
            let character = layout.characterIndexForGlyph(at: glyph)
            guard character < storage.length else { return nil }
            var range = NSRange()
            guard let link = storage.attribute(.link, at: character, effectiveRange: &range),
                  TranscriptPlaybackText.time(in: link) != nil else { return nil }
            return PlaybackLink(value: link, character: character, range: range)
        }

        private func setHoveredRange(_ range: NSRange?) {
            guard range != hoveredRange, let layout = layoutManager else { return }
            if let hoveredRange, NSMaxRange(hoveredRange) <= (textStorage?.length ?? 0) {
                layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: hoveredRange)
            }
            hoveredRange = range
            if let range {
                layout.addTemporaryAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, forCharacterRange: range)
            }
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            guard let menu = commands() else { return super.menu(for: event) }
            if selectedRange().length > 0 {
                let copy = NSMenuItem(title: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "")
                copy.target = self
                menu.insertItem(.separator(), at: 0)
                menu.insertItem(copy, at: 0)
            }
            return menu
        }
    }
}
