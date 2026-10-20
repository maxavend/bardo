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
            "Graba lo que suena en el Mac, como una llamada, y tu micrófono en pistas separadas."
        case .systemAudio:
            "Graba todo lo que suena en el Mac, como una llamada o un video."
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
    @StateObject private var devices = AudioDeviceCatalog()
    @State private var mode: BardoRecordingMode = .conversation
    @State private var title = ""
    @State private var inputUID: String?
    @State private var outputUID: String?
    @FocusState private var isTitleFocused: Bool

    private let preferences = AudioDevicePreferences()

    /// The microphone this recording will use: the chosen one, or the default.
    private var effectiveInput: AudioDevice? {
        AudioDevicePreferences.resolve(preferredUID: inputUID, among: devices.inputs) ?? devices.defaultInput
    }

    private var effectiveOutput: AudioDevice? {
        AudioDevicePreferences.resolve(preferredUID: outputUID, among: devices.outputs) ?? devices.defaultOutput
    }

    private var handsFreeRisk: HandsFreeRisk? {
        HandsFreeRisk(input: effectiveInput, output: mode == .microphone ? nil : effectiveOutput)
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

            TextField("Nombre de la conversación", text: $title, prompt: Text("Nombre de la conversación (opcional)"))
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)

            VStack(alignment: .leading, spacing: 10) {
                Text("Fuente")
                    .font(.headline)

                // A native radio group: arrow keys move between sources, and VoiceOver
                // reads it as one choice.
                Picker("Fuente", selection: $mode) {
                    ForEach(BardoRecordingMode.allCases) { option in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(option.title)
                            Text(option.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 3)
                        .tag(option)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                    if mode != .systemAudio {
                        GridRow {
                            Text("Micrófono:")
                                .gridColumnAlignment(.trailing)
                            AudioDevicePicker(
                                title: "Micrófono",
                                selection: $inputUID,
                                devices: devices.inputs,
                                defaultDevice: devices.defaultInput,
                                rememberedName: preferences.inputDeviceName
                            )
                        }
                    }
                    if mode != .microphone {
                        GridRow {
                            Text("Salida:")
                                .gridColumnAlignment(.trailing)
                            AudioDevicePicker(
                                title: "Salida",
                                selection: $outputUID,
                                devices: devices.outputs,
                                defaultDevice: devices.defaultOutput,
                                rememberedName: preferences.outputDeviceName
                            )
                            .help("Bardo graba todo lo que suena en el Mac. Elige la salida con la que escuchas la llamada.")
                        }
                    }
                }

                if let handsFreeRisk, let input = effectiveInput {
                    Label {
                        switch handsFreeRisk {
                        case .microphoneAndOutput:
                            Text("Al usar el micrófono de \(input.name), macOS lo pasa a modo manos libres: tu voz y el audio del Mac se grabarán con calidad de teléfono. Para un mejor resultado, elige otro micrófono.")
                        case .microphone:
                            Text("Al usar el micrófono de \(input.name), macOS lo pasa a modo manos libres y tu voz se grabará con calidad de teléfono.")
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                if mode != .systemAudio {
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
        .onChange(of: inputUID) { _, uid in
            remember(uid, among: devices.inputs, for: .input)
        }
        .onChange(of: outputUID) { _, uid in
            remember(uid, among: devices.outputs, for: .output)
        }
        .onDisappear {
            devices.stopObserving()
        }
        .onAppear {
            devices.startObserving()
            inputUID = preferences.inputDeviceUID
            outputUID = preferences.outputDeviceUID
            isTitleFocused = true
            microphone.refreshPermissionState()
            if let raw = UserDefaults.standard.string(forKey: "bardo.default-recording-mode"),
               let savedMode = BardoRecordingMode(rawValue: raw) {
                mode = savedMode
            }
        }
    }

    /// Saves a choice made in a picker. A disconnected device stays chosen until the
    /// person picks another, so it is used again once it reconnects.
    private func remember(_ uid: String?, among available: [AudioDevice], for direction: AudioDeviceDirection) {
        let saved = direction == .input ? preferences.inputDeviceUID : preferences.outputDeviceUID
        guard uid != saved else { return }
        if let uid {
            guard let device = available.first(where: { $0.uid == uid }) else { return }
            preferences.setDevice(device, for: direction)
        } else {
            preferences.setDevice(nil, for: direction)
        }
    }
}

/// A pop-up menu of the Mac's microphones or outputs, with the macOS default first.
private struct AudioDevicePicker: View {
    let title: LocalizedStringKey
    @Binding var selection: String?
    let devices: [AudioDevice]
    let defaultDevice: AudioDevice?
    let rememberedName: String?

    /// A chosen device that is not connected right now: recordings use the default
    /// until it comes back.
    private var missingUID: String? {
        guard let selection, !devices.contains(where: { $0.uid == selection }) else { return nil }
        return selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: $selection) {
                Text(defaultTitle).tag(String?.none)
                Divider()
                ForEach(devices) { device in
                    Text(device.menuTitle).tag(Optional(device.uid))
                }
                if let missingUID {
                    Text("\(rememberedName ?? "Dispositivo") (no conectado)").tag(Optional(missingUID))
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            if missingUID != nil {
                Text("Mientras no esté conectado, se usará el predeterminado del sistema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var defaultTitle: String {
        if let defaultDevice {
            "Predeterminado del sistema (\(defaultDevice.name))"
        } else {
            "Predeterminado del sistema"
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
