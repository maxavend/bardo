import AppKit
import SwiftUI

/// The recording in progress, as the menu bar item shows it.
struct RecordingMenuBarState: Equatable {
    var isPaused: Bool
    var commands: BardoCaptureCommandState

    /// The menu's first line, which says what the symbol means.
    var status: String {
        if isPaused { return "Grabación en pausa" }
        return commands.isMuted ? "Micrófono silenciado" : "Grabando"
    }
}

/// Feeds the menu bar item from the window that records. Only the start, end, pause
/// and mute of a recording change it; the running time lives in `clock`, which only
/// the item's label observes.
@MainActor
final class RecordingMenuBar: ObservableObject {
    static let shared = RecordingMenuBar()

    @Published private(set) var state: RecordingMenuBarState?
    let clock = RecordingMenuBarClock()

    /// `position` reads the seconds of audio heard so far.
    func update(_ state: RecordingMenuBarState?, position: @escaping @MainActor () -> TimeInterval) {
        if state != self.state { self.state = state }
        if let state {
            clock.run(position: position, isPaused: state.isPaused)
        } else {
            clock.stop()
        }
    }
}

/// The running time in whole seconds. It reads the recording four times a second but
/// publishes only when the second changes, so the label redraws once a second.
@MainActor
final class RecordingMenuBarClock: ObservableObject {
    @Published private(set) var seconds = 0
    private var position: (@MainActor () -> TimeInterval)?
    private var ticker: Task<Void, Never>?

    var text: String { LibraryFormatting.duration(TimeInterval(seconds)) }

    func run(position: @escaping @MainActor () -> TimeInterval, isPaused: Bool) {
        self.position = position
        refresh()
        if isPaused {
            ticker?.cancel()
            ticker = nil
        } else if ticker == nil {
            ticker = Task { [weak self] in
                while true {
                    // A cancelled sleep returns at once; stop before reading again.
                    guard (try? await Task.sleep(for: .milliseconds(250))) != nil, let self else { return }
                    self.refresh()
                }
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        position = nil
        if seconds != 0 { seconds = 0 }
    }

    func refresh() {
        guard let position else { return }
        let elapsed = position()
        let whole = elapsed.isFinite ? Int(max(0, elapsed)) : 0
        if whole != seconds { seconds = whole }
    }
}

/// A red recording symbol with the running time, grey while paused.
struct RecordingMenuBarLabel: View {
    let state: RecordingMenuBarState
    @ObservedObject var clock: RecordingMenuBarClock

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.symbol(isPaused: state.isPaused, status: state.status))
            Text(clock.text)
                .monospacedDigit()
        }
    }

    /// The menu bar tints template images; the recording symbol keeps its red.
    /// The menu bar reads the item as its image and title, so the symbol says the status.
    static func symbol(isPaused: Bool, status: String) -> NSImage {
        let name = isPaused ? "pause.circle.fill" : "record.circle.fill"
        let base = NSImage(systemSymbolName: name, accessibilityDescription: status) ?? NSImage()
        let size = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        if isPaused {
            let image = base.withSymbolConfiguration(size) ?? base
            image.isTemplate = true
            return image
        }
        let red = size.applying(.init(paletteColors: [.white, .systemRed]))
        let image = base.withSymbolConfiguration(red) ?? base
        image.isTemplate = false
        return image
    }
}

/// The essentials of the recording, from anywhere on the Mac.
struct RecordingMenuBarMenu: View {
    @ObservedObject var model: RecordingMenuBar
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let state = model.state {
            Text(state.status)

            Button("Mostrar Bardo") {
                openWindow(id: BardoApp.mainWindowID)
                NSApp.activate()
                NotificationCenter.default.post(name: BardoCommandNotification.showRecording, object: nil)
            }

            Divider()

            RecordingCommandButtons(capture: state.commands, includesSections: false)
        }
    }
}
