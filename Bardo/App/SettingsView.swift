import AppKit
import SwiftUI

private enum BardoAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Sistema"
        case .light: "Claro"
        case .dark: "Oscuro"
        }
    }
}

private enum SettingsTab: String {
    case general
    case recording
    case transcription
    case storage
    case privacy
}

struct SettingsView: View {
    @ObserveInjection var redraw
    @State private var selectedTab: SettingsTab = .general
    @StateObject private var model = ModelSettingsViewModel()
    @State private var pendingReset: PendingModelReset?
    @State private var isLibraryRemovalPresented = false
    @State private var storageUsage = BardoStorageUsage.empty

    init(initialTab: String? = nil) {
        _selectedTab = State(initialValue: initialTab.flatMap(SettingsTab.init(rawValue:)) ?? .general)
    }

    @AppStorage("bardo.appearance") private var appearanceRaw = BardoAppearancePreference.system.rawValue
    @AppStorage("bardo.default-recording-mode") private var recordingModeRaw = BardoRecordingMode.conversation.rawValue
    @AppStorage(TranscriptionTrackMode.defaultsKey) private var trackModeRaw = TranscriptionTrackMode.perTrack.rawValue
    @AppStorage(LocalSpeakerName.defaultsKey) private var localSpeakerName = ""
    @AppStorage(TranscriptionEngine.defaultsKey) private var engineRaw = TranscriptionEngine.default.rawValue
    @AppStorage(AudioEncodingPreferences.presetKey) private var qualityRaw = AudioQualityPreset.default.rawValue
    @AppStorage(AudioEncodingPreferences.formatKey) private var formatRaw = AudioStorageFormat.default.rawValue
    @StateObject private var devices = AudioDeviceCatalog()
    /// Bumped when a device is chosen, so the pickers read the saved choice again.
    @State private var deviceChoiceRevision = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .frame(width: Self.width, height: 130)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            recordingTab
                .frame(width: Self.width, height: 600)
                .tabItem { Label("Grabación", systemImage: "mic") }
                .tag(SettingsTab.recording)

            transcriptionTab
                .frame(width: Self.width, height: 720)
                .tabItem { Label("Transcripción", systemImage: "waveform") }
                .tag(SettingsTab.transcription)

            storageTab
                .frame(width: Self.width, height: 460)
                .tabItem { Label("Almacenamiento", systemImage: "externaldrive") }
                .tag(SettingsTab.storage)

            privacyTab
                .frame(width: Self.width, height: 390)
                .tabItem { Label("Privacidad", systemImage: "hand.raised") }
                .tag(SettingsTab.privacy)
        }
        .task {
            await model.refreshIfNeeded()
            refreshStorageUsage()
            applyAppearance()
        }
        .onChange(of: appearanceRaw) { _, _ in
            applyAppearance()
        }
        .alert(item: $pendingReset) { request in
            Alert(
                title: Text("¿Eliminar este recurso local?"),
                message: Text("Bardo puede volver a descargarlo cuando lo necesites."),
                primaryButton: .destructive(Text(request.reinstall ? "Eliminar y descargar de nuevo" : "Eliminar")) {
                    if request.reinstall {
                        model.resetAndInstall(request.model)
                    } else {
                        model.reset(request.model)
                    }
                },
                secondaryButton: .cancel(Text("Cancelar"))
            )
        }
        .alert("¿Mover todas las conversaciones a la Papelera?", isPresented: $isLibraryRemovalPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Mover a la Papelera", role: .destructive) {
                moveLibraryContentsToTrash()
            }
        } message: {
            Text("Se moverán a la Papelera de macOS todas las grabaciones y transcripciones guardadas por Bardo. Podrás recuperarlas desde Finder mientras no vacíes la Papelera.")
        }
        #if DEBUG
        .onDesignReviewCommand { step in
            if step.action == "settingsTab", let tab = SettingsTab(rawValue: step.value) {
                selectedTab = tab
            }
        }
        #endif
        .enableInjection()
    }

    /// Like the Settings of Apple's apps, the window keeps one width and takes the
    /// height of the selected tab.
    private static let width: CGFloat = 660

    private var generalTab: some View {
        Form {
            Section {
                Picker("Apariencia", selection: $appearanceRaw) {
                    ForEach(BardoAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("«Sistema» sigue el aspecto claro u oscuro que elegiste en Ajustes del Sistema.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var recordingTab: some View {
        Form {
            Section {
                Picker("Al crear una grabación", selection: $recordingModeRaw) {
                    ForEach(BardoRecordingMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol)
                            .tag(mode.rawValue)
                    }
                }
                LabeledContent("Micrófono") {
                    AudioDevicePicker(
                        title: "Micrófono",
                        selection: deviceBinding(.input),
                        devices: devices.inputs,
                        defaultDevice: devices.defaultInput,
                        rememberedName: AudioDevicePreferences().inputDeviceName
                    )
                    .fixedSize()
                }
                LabeledContent("Salida") {
                    AudioDevicePicker(
                        title: "Salida",
                        selection: deviceBinding(.output),
                        devices: devices.outputs,
                        defaultDevice: devices.defaultOutput,
                        rememberedName: AudioDevicePreferences().outputDeviceName
                    )
                    .fixedSize()
                }
            } header: {
                Text("Fuente")
            } footer: {
                Text("Siempre podrás cambiarlos antes de empezar a grabar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Calidad", selection: $qualityRaw) {
                    ForEach(AudioQualityPreset.allCases) { preset in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(preset == .default ? "\(preset.title) (recomendada)" : preset.title)
                            Text("\(preset.detail) Unos \(Self.megabytes(AudioEncoding(preset: preset, format: encoding.format).meetingBytesPerMinute)) por minuto.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(preset.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)

                Picker("Formato", selection: $formatRaw) {
                    ForEach(AudioStorageFormat.allCases) { format in
                        Text("\(format.title) — \(format.detail)").tag(format.rawValue)
                    }
                }
            } header: {
                Text("Calidad del audio")
            } footer: {
                Text("Con cualquier calidad se entiende y se transcribe todo. Los pesos son por minuto de reunión, con tu micrófono y el audio del Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { devices.startObserving() }
    }

    private var selectedEngine: TranscriptionEngine {
        TranscriptionEngine(rawValue: engineRaw).flatMap { $0.isSupported ? $0 : nil } ?? .default
    }

    /// Uses an engine once it can transcribe: Apple's after macOS has its language,
    /// Whisper's once downloaded.
    private func select(_ engine: TranscriptionEngine) {
        if engine == .apple, !model.isAppleReady {
            model.prepareApple { engineRaw = engine.rawValue }
        } else {
            engineRaw = engine.rawValue
        }
    }

    private var encoding: AudioEncoding {
        AudioEncoding(
            preset: AudioQualityPreset(rawValue: qualityRaw) ?? .default,
            format: AudioStorageFormat(rawValue: formatRaw) ?? .default
        )
    }

    static func megabytes(_ bytes: Double) -> String {
        let megabytes = bytes / 1_000_000
        return "\(megabytes.formatted(.number.precision(.fractionLength(megabytes < 10 ? 1 : 0)))) MB"
    }

    /// The device the next recording uses; `nil` follows macOS.
    private func deviceBinding(_ direction: AudioDeviceDirection) -> Binding<String?> {
        Binding(
            get: {
                _ = deviceChoiceRevision
                let preferences = AudioDevicePreferences()
                return direction == .input ? preferences.inputDeviceUID : preferences.outputDeviceUID
            },
            set: { uid in
                let list = direction == .input ? devices.inputs : devices.outputs
                if uid == nil {
                    AudioDevicePreferences().setDevice(nil, for: direction)
                } else if let device = list.first(where: { $0.uid == uid }) {
                    AudioDevicePreferences().setDevice(device, for: direction)
                }
                deviceChoiceRevision += 1
            }
        )
    }

    private var transcriptionTab: some View {
        Form {
            Section {
                ForEach(TranscriptionEngine.allCases) { engine in
                    TranscriptionEngineRow(
                        engine: engine,
                        isSelected: selectedEngine == engine,
                        managedRow: engine.managedModel.flatMap { model.row(for: $0) },
                        isAppleReady: model.isAppleReady,
                        isPreparingApple: model.isPreparingApple,
                        appleFailure: model.appleFailure,
                        select: { select(engine) },
                        action: { action in
                            if let managed = engine.managedModel { handle(action, for: managed) }
                        }
                    )
                }
            } header: {
                Text("Transcripción")
            } footer: {
                Text("Todos transcriben en este Mac, sin enviar tus conversaciones a internet. El que elijas se usa en las próximas transcripciones.")
            }

            Section {
                if let row = model.row(for: .speakerKit) {
                    ModelSettingsRow(row: row) { action in
                        handle(action, for: .speakerKit)
                    }
                }
            } header: {
                Text("Participantes")
            } footer: {
                Text("Es el mismo con cualquier forma de transcribir.")
            }

            Section("Idioma") {
                LabeledContent("Idioma de la conversación", value: "Detectar automáticamente")
                Text("Bardo reconoce el idioma a partir del audio y mantiene la transcripción en ese idioma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Transcribir", selection: $trackModeRaw) {
                    Text("Cada pista por separado").tag(TranscriptionTrackMode.perTrack.rawValue)
                    Text("La mezcla de la conversación").tag(TranscriptionTrackMode.mix.rawValue)
                }
                TextField("Tu nombre", text: $localSpeakerName, prompt: Text("Tú"))
            } header: {
                Text("Reuniones en este Mac")
            } footer: {
                Text(trackModeRaw == TranscriptionTrackMode.mix.rawValue
                    ? "Bardo transcribe la conversación como una sola pista. Las voces que se superponen pueden mezclarse."
                    : "Tu micrófono y el audio del Mac se transcriben por separado: las voces no se pisan y lo que dices tú queda con tu nombre. Si la llamada sonó por los parlantes, Bardo descarta el eco que captó el micrófono.")
            }

        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var storageTab: some View {
        Form {
            Section("Uso local") {
                LabeledContent("Conversaciones", value: storageUsage.libraryText)
                LabeledContent("Recursos locales", value: storageUsage.modelsText)
                LabeledContent("Total", value: storageUsage.totalText)
            }

            Section("Ubicaciones") {
                LabeledContent("Conversaciones") {
                    Button("Mostrar en Finder") {
                        guard let url = try? RecordingStore.defaultLibraryURL() else { return }
                        NSWorkspace.shared.open(url)
                    }
                }

                LabeledContent("Recursos locales") {
                    Button("Mostrar en Finder") {
                        model.revealModelsFolder()
                    }
                }
            }

            Section("Datos de Bardo") {
                LabeledContent {
                    Button("Mover a la Papelera…", role: .destructive) {
                        isLibraryRemovalPresented = true
                    }
                } label: {
                    Text("Todas las conversaciones")
                    Text("Los recursos para transcribir se conservan; puedes eliminarlos desde Transcripción.")
                }
            }
        }
        .formStyle(.grouped)
        .bardoSecondaryAction()
        .padding(.top, 8)
    }

    private var privacyTab: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tus conversaciones se quedan en este Mac")
                            .font(.headline)
                        Text("Bardo procesa el audio, la transcripción y la identificación de hablantes de forma local. El contenido de tus conversaciones no necesita enviarse a un servicio externo.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: "lock.shield")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Permisos") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Micrófono")
                    Text("Solo se solicita cuando quieres grabar tu voz.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grabación del sistema")
                    Text("macOS muestra su selector antes de capturar audio de una app, ventana o pantalla.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Almacenamiento") {
                Text("Las grabaciones y transcripciones se guardan dentro de la biblioteca privada de Bardo en tu carpeta de usuario.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private func handle(_ action: ModelSettingsAction, for modelID: ManagedModel) {
        switch action {
        case .install:
            model.install(modelID)
        case .cancel:
            model.cancel(modelID)
        case .retry:
            model.install(modelID)
        case .reset:
            pendingReset = PendingModelReset(model: modelID, reinstall: false)
        case .resetAndInstall:
            pendingReset = PendingModelReset(model: modelID, reinstall: true)
        case .reveal:
            model.revealModelFolder(modelID)
        case .unavailable:
            break
        }
    }

    private func applyAppearance() {
        #if DEBUG
        // The design review sets the appearance it captures.
        if DesignReview.forcesAppearance { return }
        #endif
        let preference = BardoAppearancePreference(rawValue: appearanceRaw) ?? .system
        switch preference {
        case .system:
            NSApp.appearance = nil
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func refreshStorageUsage() {
        storageUsage = BardoStorageUsage.current()
    }

    private func moveLibraryContentsToTrash() {
        guard let libraryURL = try? RecordingStore.defaultLibraryURL(),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: libraryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return
        }

        for entry in entries {
            _ = try? FileManager.default.trashItem(at: entry, resultingItemURL: nil)
        }

        refreshStorageUsage()
        NotificationCenter.default.post(name: BardoCommandNotification.libraryChanged, object: nil)
    }
}

private struct BardoStorageUsage {
    let libraryBytes: Int64
    let modelsBytes: Int64

    static let empty = BardoStorageUsage(libraryBytes: 0, modelsBytes: 0)

    var libraryText: String { formatted(libraryBytes) }
    var modelsText: String { formatted(modelsBytes) }
    var totalText: String { formatted(libraryBytes + modelsBytes) }

    static func current() -> BardoStorageUsage {
        let library = (try? RecordingStore.defaultLibraryURL()).map(directorySize) ?? 0
        let models: Int64
        if let store = try? BardoModelStore.live() {
            let roots = ManagedModel.allCases.map { store.root(for: $0) }
            let parentRoots = Set(roots.map { $0.standardizedFileURL })
            models = parentRoots.reduce(0) { $0 + directorySize($1) }
        } else {
            models = 0
        }
        return BardoStorageUsage(libraryBytes: library, modelsBytes: models)
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private struct PendingModelReset: Identifiable {
    let model: ManagedModel
    let reinstall: Bool

    var id: String { "\(model.rawValue)-\(reinstall)" }
}

private struct ModelSettingsRow: View {
    let row: ModelSettingsRowState
    let action: (ModelSettingsAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .fontWeight(.medium)
                            .lineLimit(1)

                        Text(row.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } icon: {
                    Image(systemName: row.symbol)
                        .foregroundStyle(row.stateColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !row.stateLabel.isEmpty {
                    Text(row.stateLabel)
                        .font(.caption)
                        .foregroundStyle(row.stateColor)
                        .lineLimit(1)
                }

                stateControl
            }

            if let progress = row.progressFraction {
                ProgressView(value: progress)
            }

            if case .failed(let message) = row.state {
                Text(String.localizedStringWithFormat(String(localized: "Failed: %@"), message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        [row.title, row.stateLabel, row.detail]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    @ViewBuilder
    private var stateControl: some View {
        switch row.primaryAction {
        case .install:
            Button(String(localized: "Install")) {
                action(.install)
            }
            .controlSize(.small)

        case .cancel:
            Button(String(localized: "Cancel"), role: .cancel) {
                action(.cancel)
            }
            .controlSize(.small)

        case .retry:
            Button(String(localized: "Retry")) {
                action(.retry)
            }
            .controlSize(.small)

        case .reset, .resetAndInstall:
            Menu {
                Button(String(localized: "Show in Finder")) {
                    action(.reveal)
                }

                Divider()

                Button(String(localized: "Reinstall Model…"), role: .destructive) {
                    action(.resetAndInstall)
                }

                Button(String(localized: "Remove Model"), role: .destructive) {
                    action(.reset)
                }
            } label: {
                Label(
                    String.localizedStringWithFormat(String(localized: "More actions for %@"), row.title),
                    systemImage: "ellipsis.circle"
                )
                .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(String(localized: "Show more actions"))

        case .reveal, .unavailable:
            EmptyView()
        }
    }
}

struct ModelSettingsRowState: Identifiable, Equatable, Sendable {
    let id: ManagedModel
    let title: String
    let detail: String
    let supportsInstallation: Bool
    var state: ManagedModelState

    var primaryAction: ModelSettingsAction {
        ModelSettingsActionPolicy.action(for: state, supportsInstallation: supportsInstallation)
    }

    var stateLabel: String {
        switch state {
        case .notInstalled:
            return supportsInstallation ? "" : String(localized: "On demand")
        case .downloading(let fraction):
            return String.localizedStringWithFormat(String(localized: "Downloading %@"), percentage(fraction))
        case .preparing(let fraction):
            return String.localizedStringWithFormat(String(localized: "Preparing %@"), percentage(fraction))
        case .installed:
            return String(localized: "Installed")
        case .failed:
            return String(localized: "Failed")
        }
    }

    var progressFraction: Double? {
        switch state {
        case .downloading(let fraction), .preparing(let fraction):
            return min(1, max(0, fraction))
        default:
            return nil
        }
    }

    var symbol: String {
        switch state {
        case .notInstalled: return "arrow.down.circle"
        case .downloading: return "arrow.down.circle.fill"
        case .preparing: return "gearshape"
        case .installed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    var stateColor: Color {
        switch state {
        case .notInstalled: return .secondary
        case .downloading, .preparing: return .secondary
        case .installed: return .green
        case .failed: return .orange
        }
    }

    private func percentage(_ fraction: Double) -> String {
        "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}

@MainActor
private final class ModelSettingsViewModel: ObservableObject {
    @Published private(set) var rows: [ModelSettingsRowState] = []
    @Published private(set) var isRefreshing = false
    /// Whether macOS has Apple's recognition ready for this Mac's language.
    @Published private(set) var isAppleReady = false
    @Published private(set) var isPreparingApple = false
    private var didRefresh = false
    private var refreshTask: Task<Void, Never>?
    private var operationTasks: [ManagedModel: Task<Void, Never>] = [:]

    init() {
        rows = ManagedModel.allCases.map { makeRow(for: $0, state: .notInstalled) }
    }

    deinit {
        refreshTask?.cancel()
        operationTasks.values.forEach { $0.cancel() }
    }

    func refreshIfNeeded() async {
        guard !didRefresh else { return }
        await refreshAsync()
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshAsync()
        }
    }

    func install(_ model: ManagedModel) {
        guard operationTasks[model] == nil else { return }
        setState(.downloading(0), for: model)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runInstall(model)
        }
        operationTasks[model] = task
    }

    func cancel(_ model: ManagedModel) {
        operationTasks[model]?.cancel()
    }

    func reset(_ model: ManagedModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await resetRuntimeModel(model)
                setState(.notInstalled, for: model)
                NotificationCenter.default.post(name: .bardoModelsChanged, object: nil)
            } catch {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    func resetAndInstall(_ model: ManagedModel) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await resetRuntimeModel(model)
                setState(.notInstalled, for: model)
                install(model)
            } catch {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    private func resetRuntimeModel(_ model: ManagedModel) async throws {
        switch model {
        case .whisperTurbo, .whisperLarge:
            try await WhisperTranscriptionService.live().reset(model)
        case .speakerKit:
            try await SpeakerDiarizationService.live().reset()
        }
        try BardoModelStore.live().reset(model)
    }

    /// Asks macOS for Apple's recognition in this Mac's language, then selects it.
    func prepareApple(then select: @escaping @MainActor () -> Void) {
        guard #available(macOS 26.0, *), !isPreparingApple else { return }
        isPreparingApple = true
        Task { @MainActor [weak self] in
            do {
                try await AppleSpeechTranscriber.prepare { _ in }
                self?.isAppleReady = true
                select()
            } catch {
                self?.appleFailure = error.localizedDescription
            }
            self?.isPreparingApple = false
        }
    }

    @Published var appleFailure: String?

    func row(for model: ManagedModel) -> ModelSettingsRowState? {
        rows.first { $0.id == model }
    }

    func revealModelsFolder() {
        guard let store = try? BardoModelStore.live() else { return }
        let root = store.root(for: .whisperTurbo).deletingLastPathComponent()
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func revealModelFolder(_ model: ManagedModel) {
        guard let store = try? BardoModelStore.live() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([store.root(for: model)])
    }

    private func runInstall(_ model: ManagedModel) async {
        defer { operationTasks[model] = nil }

        do {
            _ = try BardoModelStore.live()
            switch model {
            case .whisperTurbo, .whisperLarge:
                let manager = try TranscriptionModelManager.live(for: model)
                _ = try await manager.ensureResourcesAvailable { [weak self] fraction in
                    let state = Self.runtimeDownloadState(for: fraction)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            case .speakerKit:
                let service = try SpeakerDiarizationService.live()
                try await service.prepareForUse { [weak self] snapshot in
                    let state = Self.diarizationState(for: snapshot)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            }

            try Task.checkCancellation()
            setState(.installed, for: model)
            NotificationCenter.default.post(name: .bardoModelsChanged, object: nil)
        } catch {
            if error is CancellationError || Task.isCancelled {
                await refreshModel(model)
            } else {
                setState(.failed(error.localizedDescription), for: model)
            }
        }
    }

    private func refreshAsync() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            didRefresh = true
            refreshTask = nil
        }

        do {
            _ = try BardoModelStore.live()
        } catch {
            rows = ManagedModel.allCases.map {
                makeRow(for: $0, state: .failed(error.localizedDescription))
            }
            return
        }

        for whisperModel in [ManagedModel.whisperTurbo, .whisperLarge] where operationTasks[whisperModel] == nil {
            do {
                let whisper = try WhisperTranscriptionService.live()
                let installed = await whisper.hasInstalledModel(whisperModel)
                setState(installed ? .installed : .notInstalled, for: whisperModel)
            } catch {
                setState(.failed(error.localizedDescription), for: whisperModel)
            }
        }
        if #available(macOS 26.0, *) {
            isAppleReady = await AppleSpeechTranscriber.isReady()
        }

        if operationTasks[.speakerKit] == nil {
            do {
                let speakers = try SpeakerDiarizationService.live()
                let installed = await speakers.hasInstalledModels()
                if installed {
                    setState(.installed, for: .speakerKit)
                } else {
                    let state = await speakers.state()
                    setState(state == .notInstalled ? .notInstalled : state, for: .speakerKit)
                }
            } catch {
                setState(.failed(error.localizedDescription), for: .speakerKit)
            }
        }
    }

    private func refreshModel(_ model: ManagedModel) async {
        guard (try? BardoModelStore.live()) != nil else { return }
        switch model {
        case .whisperTurbo, .whisperLarge:
            let service = try? WhisperTranscriptionService.live()
            setState(await service?.hasInstalledModel(model) == true ? .installed : .notInstalled, for: model)
        case .speakerKit:
            let service = try? SpeakerDiarizationService.live()
            setState(await service?.hasInstalledModels() == true ? .installed : .notInstalled, for: model)
        }
    }

    private func setState(_ state: ManagedModelState, for model: ManagedModel) {
        guard let index = rows.firstIndex(where: { $0.id == model }) else {
            rows.append(makeRow(for: model, state: state))
            return
        }
        rows[index].state = state
    }

    private func makeRow(for model: ManagedModel, state: ManagedModelState) -> ModelSettingsRowState {
        switch model {
        case .whisperTurbo, .whisperLarge:
            let engine: TranscriptionEngine = model == .whisperLarge ? .precise : .balanced
            return ModelSettingsRowState(
                id: model,
                title: engine.title,
                detail: engine.detail,
                supportsInstallation: true,
                state: state
            )
        case .speakerKit:
            return ModelSettingsRowState(
                id: model,
                title: "Identificación de hablantes",
                detail: "Distingue las voces para organizar la conversación por participante.",
                supportsInstallation: true,
                state: state
            )
        }
    }

    private nonisolated static func runtimeDownloadState(for fraction: Double) -> ManagedModelState {
        .downloading(min(1, max(0, fraction)))
    }

    private nonisolated static func diarizationState(for snapshot: DiarizationSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .checking, .optimizingForMac:
            return .preparing(value)
        case .downloading:
            return .downloading(value)
        }
    }
}
