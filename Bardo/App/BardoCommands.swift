import Foundation
import SwiftUI

enum BardoCommandNotification {
    static let newRecording = Notification.Name("Bardo.Command.NewRecording")
    static let importAudio = Notification.Name("Bardo.Command.ImportAudio")
    static let focusSearch = Notification.Name("Bardo.Command.FocusSearch")
    static let toggleInspector = Notification.Name("Bardo.Command.ToggleInspector")
    static let pauseRecording = Notification.Name("Bardo.Command.PauseRecording")
    static let resumeRecording = Notification.Name("Bardo.Command.ResumeRecording")
    static let stopRecording = Notification.Name("Bardo.Command.StopRecording")
    static let libraryChanged = Notification.Name("Bardo.Library.Changed")
}

struct BardoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nueva grabación") {
                post(BardoCommandNotification.newRecording)
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Importar audio…") {
                post(BardoCommandNotification.importAudio)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandMenu("Grabación") {
            Button("Nueva grabación…") {
                post(BardoCommandNotification.newRecording)
            }
            .keyboardShortcut("r", modifiers: [.command])

            Divider()

            Button("Pausar grabación") {
                post(BardoCommandNotification.pauseRecording)
            }
            .keyboardShortcut(.space, modifiers: [.command, .option])

            Button("Reanudar grabación") {
                post(BardoCommandNotification.resumeRecording)
            }

            Button("Finalizar grabación") {
                post(BardoCommandNotification.stopRecording)
            }
            .keyboardShortcut(".", modifiers: [.command])
        }

        CommandGroup(after: .toolbar) {
            Button("Buscar en Bardo") {
                post(BardoCommandNotification.focusSearch)
            }
            .keyboardShortcut("k", modifiers: [.command])

            Button("Mostrar u ocultar información") {
                post(BardoCommandNotification.toggleInspector)
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    private func post(_ name: Notification.Name) {
        NotificationCenter.default.post(name: name, object: nil)
    }
}
