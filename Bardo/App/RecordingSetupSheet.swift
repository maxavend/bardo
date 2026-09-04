import AVFoundation
import SwiftUI

enum BardoRecordingMode: String, CaseIterable, Identifiable {
    case microphone
    case conversation
    case systemAudio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: "Micrófono"
        case .conversation: "Reunión en este Mac"
        case .systemAudio: "Audio interno"
        }
    }

    var detail: String {
        switch self {
        case .microphone:
            "Graba lo que escucha el micrófono."
        case .conversation:
            "Graba el audio del Mac y tu micrófono en pistas separadas."
        case .systemAudio:
            "Graba solamente el audio de la app, ventana o pantalla que elijas."
        }
    }

    var symbol: String {
        switch self {
        case .microphone: "mic"
        case .conversation: "person.wave.2"
        case .systemAudio: "macbook.and.iphone"
        }
    }
}

struct RecordingSetupSheet: View {
    @ObservedObject var microphone: MicrophoneRecordingController
    let onStart: (BardoRecordingMode, String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: BardoRecordingMode = .conversation
    @State private var title = ""

    private var microphoneName: String {
        AVCaptureDevice.default(for: .audio)?.localizedName ?? "No hay un micrófono disponible"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Nueva grabación")
                    .font(.title2.weight(.semibold))
                Text("Elige qué quieres capturar. Podrás seguir usando Bardo mientras procesa la conversación.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField("Nombre de la conversación (opcional)", text: $title)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text("Fuente")
                    .font(.headline)

                ForEach(BardoRecordingMode.allCases) { option in
                    Button {
                        mode = option
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: option.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(mode == option ? Color.accentColor : Color.secondary)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 12)

                            Image(systemName: mode == option ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(mode == option ? Color.accentColor : Color.secondary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if mode != .systemAudio {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Micrófono") {
                        Text(microphoneName)
                            .foregroundStyle(.secondary)
                    }

                    switch microphone.permissionState {
                    case .denied:
                        HStack {
                            Label("Bardo necesita acceso al micrófono para esta grabación.", systemImage: "mic.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Abrir Ajustes del Sistema") {
                                _ = microphone.openMicrophoneSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    case .restricted:
                        Label("macOS no permite usar el micrófono en este momento.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    default:
                        Label("El indicador de entrada aparecerá en cuanto comience la grabación.", systemImage: "waveform")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Label(
                "El audio y su contenido se procesan de forma privada en este Mac.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Cancelar") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Comenzar") {
                    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    onStart(mode, trimmed.isEmpty ? nil : trimmed)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(mode != .systemAudio && microphone.permissionState == .restricted)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            microphone.refreshPermissionState()
            if let raw = UserDefaults.standard.string(forKey: "bardo.default-recording-mode"),
               let savedMode = BardoRecordingMode(rawValue: raw) {
                mode = savedMode
            }
        }
    }
}

struct BardoInputLevelView: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(.quaternary)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(3, proxy.size.width * min(1, max(0, level))))
                }
        }
        .frame(width: 54, height: 4)
        .accessibilityLabel("Nivel de entrada")
        .accessibilityValue("\(Int(min(1, max(0, level)) * 100)) por ciento")
    }
}
