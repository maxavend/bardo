import Foundation
import SwiftUI

enum BardoCommandNotification {
    static let newRecording = Notification.Name("Bardo.Command.NewRecording")
    static let importAudio = Notification.Name("Bardo.Command.ImportAudio")
    static let focusSearch = Notification.Name("Bardo.Command.FocusSearch")
    static let pauseRecording = Notification.Name("Bardo.Command.PauseRecording")
    static let resumeRecording = Notification.Name("Bardo.Command.ResumeRecording")
    static let stopRecording = Notification.Name("Bardo.Command.StopRecording")
    static let libraryChanged = Notification.Name("Bardo.Library.Changed")
}

/// What the focused window's capture can do right now, so menu items are enabled
/// only when they would act.
struct BardoCaptureCommandState: Equatable {
    var canStart: Bool
    var canPause: Bool
    var canResume: Bool
    var canStop: Bool
}

extension FocusedValues {
    @Entry var captureCommands: BardoCaptureCommandState?
}

struct BardoCommands: Commands {
    @FocusedBinding(\.libraryInspector) private var isInspectorPresented
    @FocusedValue(\.captureCommands) private var capture

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nueva grabación…") {
                post(BardoCommandNotification.newRecording)
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(capture?.canStart == false)

            Button("Importar audio…") {
                post(BardoCommandNotification.importAudio)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .textEditing) {
            Button("Buscar…") {
                post(BardoCommandNotification.focusSearch)
            }
            .keyboardShortcut("f", modifiers: [.command])
        }

        CommandGroup(after: .sidebar) {
            Button(isInspectorPresented == true ? "Ocultar información" : "Mostrar información") {
                isInspectorPresented?.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(isInspectorPresented == nil)
        }

        // Bardo has no Help book; keep the menu's search field without a dead item.
        CommandGroup(replacing: .help) {}

        CommandMenu("Grabación") {
            Button("Pausar grabación") {
                post(BardoCommandNotification.pauseRecording)
            }
            .keyboardShortcut(.space, modifiers: [.command, .option])
            .disabled(capture?.canPause != true)

            Button("Reanudar grabación") {
                post(BardoCommandNotification.resumeRecording)
            }
            .keyboardShortcut(.space, modifiers: [.command, .option, .shift])
            .disabled(capture?.canResume != true)

            Divider()

            Button("Finalizar grabación") {
                post(BardoCommandNotification.stopRecording)
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(capture?.canStop != true)
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
