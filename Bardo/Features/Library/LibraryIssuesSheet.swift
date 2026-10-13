import SwiftUI

/// What the sidebar's "needs review" row opens: each Library item Bardo could not load
/// as a conversation, explained in plain words, with a way to resolve it.
struct LibraryIssuesSheet: View {
    @ObservedObject var model: LibraryViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isTrashAllConfirmationPresented = false

    private var trashable: [RecordingStoreIssue] {
        model.issues.filter(\.canMoveToTrash)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Elementos que necesitan revisión")
                    .font(.title2.weight(.semibold))
                // Once everything is resolved the explanation no longer applies.
                if !model.issues.isEmpty {
                    Text("Bardo encontró en tu biblioteca archivos que no puede mostrar como conversaciones. No afectan a tus conversaciones; puedes revisarlos en Finder o moverlos a la Papelera de macOS, de donde se pueden recuperar.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)

            if model.issues.isEmpty {
                ContentUnavailableView(
                    "Todo en orden",
                    systemImage: "checkmark.circle",
                    description: Text("No queda nada por revisar en tu biblioteca.")
                )
                .frame(maxWidth: .infinity, minHeight: 180)
                .padding(.bottom, 24)
            } else {
                List(model.issues) { issue in
                    LibraryIssueRow(
                        issue: issue,
                        reveal: { Task { await model.revealIssue(issue) } },
                        moveToTrash: { Task { await model.moveIssuesToTrash([issue]) } }
                    )
                }
                .listStyle(.inset)
                .frame(minHeight: 120, idealHeight: CGFloat(min(model.issues.count, 4)) * 96 + 16)
            }

            Divider()

            HStack {
                if trashable.count > 1 {
                    Button("Mover todo a la Papelera…", role: .destructive) {
                        isTrashAllConfirmationPresented = true
                    }
                }
                Spacer()
                Button("Listo") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 580)
        .confirmationDialog(
            trashable.count == 1 ? "¿Mover 1 elemento a la Papelera?" : "¿Mover \(trashable.count) elementos a la Papelera?",
            isPresented: $isTrashAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Mover a la Papelera", role: .destructive) {
                Task { await model.moveIssuesToTrash(trashable) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Podrás recuperarlos desde la Papelera de macOS mientras no la vacíes.")
        }
    }
}

private struct LibraryIssueRow: View {
    let issue: RecordingStoreIssue
    let reveal: () -> Void
    let moveToTrash: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: LibraryIssueCopy.symbol(for: issue.kind))
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(issue.canMoveToTrash ? Color.secondary : Color.orange)
                .frame(width: 26)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(LibraryIssueCopy.title(for: issue.kind))
                    .font(.headline)
                Text(LibraryIssueCopy.explanation(for: issue.kind))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(issue.entryName)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                Button(action: reveal) {
                    Label("Mostrar en Finder", systemImage: "folder")
                        .labelStyle(.iconOnly)
                }
                .help("Mostrar en Finder")

                if issue.canMoveToTrash {
                    Button(action: moveToTrash) {
                        Label("Mover a la Papelera", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                    .help("Mover a la Papelera")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}

/// Plain words for what each Library issue means to the person.
enum LibraryIssueCopy {
    static func title(for kind: RecordingStoreIssue.Kind) -> String {
        switch kind {
        case .missingManifest: "Carpeta sin conversación"
        case .corruptManifest: "Conversación dañada"
        case .unsupportedSchemaVersion: "Conversación de una versión más nueva"
        case .identityMismatch: "Conversación con datos inconsistentes"
        case .temporaryArtifact, .temporaryAudioArtifact: "Archivo temporal sobrante"
        case .missingAudioFile: "Falta el audio original"
        case .missingDerivedAudioFile: "Falta el audio combinado"
        case .unexpectedEntry: "Elemento desconocido"
        case .unreadableEntry: "Elemento que no se puede leer"
        }
    }

    static func explanation(for kind: RecordingStoreIssue.Kind) -> String {
        switch kind {
        case .missingManifest:
            "No describe ninguna conversación; suele ser un resto de una versión anterior de Bardo o de una conversación eliminada."
        case .corruptManifest:
            "Bardo no puede leer su información. Si contiene audio que te interesa, revísalo en Finder antes de moverlo."
        case .unsupportedSchemaVersion:
            "Se creó con una versión más reciente de Bardo. Actualiza Bardo para abrirla; se conserva tal cual."
        case .identityMismatch:
            "Su información no coincide con su carpeta, así que Bardo no la muestra para no confundirla con otra."
        case .temporaryArtifact, .temporaryAudioArtifact:
            "Quedó de una operación interrumpida. Moverlo a la Papelera no afecta a la conversación."
        case .missingAudioFile:
            "La conversación sigue en tu biblioteca, pero su archivo de audio no está en su carpeta."
        case .missingDerivedAudioFile:
            "Bardo conserva las pistas originales; solo falta la mezcla que usa para reproducir."
        case .unexpectedEntry:
            "Algo que no es una conversación está dentro de la biblioteca de Bardo."
        case .unreadableEntry:
            "macOS no permitió a Bardo leerlo, así que se dejó sin tocar."
        }
    }

    static func symbol(for kind: RecordingStoreIssue.Kind) -> String {
        switch kind {
        case .missingManifest, .unexpectedEntry: "folder.badge.questionmark"
        case .corruptManifest, .identityMismatch, .unreadableEntry: "exclamationmark.triangle"
        case .unsupportedSchemaVersion: "arrow.up.circle"
        case .temporaryArtifact, .temporaryAudioArtifact: "doc.badge.clock"
        case .missingAudioFile, .missingDerivedAudioFile: "waveform.slash"
        }
    }
}
