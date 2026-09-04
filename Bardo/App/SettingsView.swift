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

struct SettingsView: View {
    @ObserveInjection var redraw
    @StateObject private var model = ModelSettingsViewModel()
    @State private var pendingReset: PendingModelReset?
    @State private var isLegacyQwenRemovalPresented = false
    @State private var isLibraryRemovalPresented = false
    @State private var storageUsage = BardoStorageUsage.empty

    @AppStorage("bardo.appearance") private var appearanceRaw = BardoAppearancePreference.system.rawValue
    @AppStorage("bardo.start-section") private var startSectionRaw = BardoLibrarySection.home.rawValue
    @AppStorage("bardo.default-recording-mode") private var recordingModeRaw = BardoRecordingMode.conversation.rawValue
    @AppStorage("bardo.minutes-detail") private var minutesDetail = "balanced"
    @AppStorage("bardo.minutes-language") private var minutesLanguage = "conversation"
    @AppStorage("bardo.minutes-instructions") private var minutesInstructions = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            recordingTab
                .tabItem { Label("Grabación", systemImage: "mic") }

            transcriptionTab
                .tabItem { Label("Transcripción", systemImage: "waveform") }

            minutesTab
                .tabItem { Label("Minutas", systemImage: "list.bullet.clipboard") }

            storageTab
                .tabItem { Label("Almacenamiento", systemImage: "externaldrive") }

            privacyTab
                .tabItem { Label("Privacidad", systemImage: "hand.raised") }
        }
        .frame(width: 660, height: 520)
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
        .alert("¿Eliminar archivos antiguos?", isPresented: $isLegacyQwenRemovalPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Eliminar archivos", role: .destructive) {
                model.removeLegacyQwenData()
                refreshStorageUsage()
            }
        } message: {
            Text("Se eliminarán solamente recursos antiguos que Bardo ya no utiliza. Tus grabaciones, transcripciones y minutas no se verán afectadas.")
        }
        .alert("¿Mover todas las conversaciones a la Papelera?", isPresented: $isLibraryRemovalPresented) {
            Button("Cancelar", role: .cancel) {}
            Button("Mover a la Papelera", role: .destructive) {
                moveLibraryContentsToTrash()
            }
        } message: {
            Text("Se moverán a la Papelera de macOS todas las grabaciones, transcripciones y minutas guardadas por Bardo. Podrás recuperarlas desde Finder mientras no vacíes la Papelera.")
        }
        .enableInjection()
    }

    private var generalTab: some View {
        Form {
            Section("Al abrir Bardo") {
                Picker("Mostrar", selection: $startSectionRaw) {
                    Text("Inicio").tag(BardoLibrarySection.home.rawValue)
                    Text("Grabaciones").tag(BardoLibrarySection.recordings.rawValue)
                    Text("Minutas").tag(BardoLibrarySection.minutes.rawValue)
                }
            }

            Section("Apariencia") {
                Picker("Apariencia", selection: $appearanceRaw) {
                    ForEach(BardoAppearancePreference.allCases) { preference in
                        Text(preference.title).tag(preference.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                Text("Bardo sigue los comportamientos nativos de macOS para ventanas, menús, atajos de teclado y modo de pantalla completa.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var recordingTab: some View {
        Form {
            Section("Fuente predeterminada") {
                Picker("Al crear una grabación", selection: $recordingModeRaw) {
                    ForEach(BardoRecordingMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol)
                            .tag(mode.rawValue)
                    }
                }

                Text("Siempre podrás cambiar la fuente antes de comenzar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Micrófono") {
                LabeledContent("Entrada") {
                    Text("Micrófono seleccionado en macOS")
                        .foregroundStyle(.secondary)
                }

                Button("Abrir ajustes de sonido…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Section {
                Text("Bardo conserva el audio original de cada fuente para que puedas volver a escucharlo o procesarlo más tarde.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var transcriptionTab: some View {
        Form {
            Section("Idioma") {
                LabeledContent("Idioma de la conversación", value: "Detectar automáticamente")
                Text("Bardo reconoce el idioma a partir del audio y mantiene la transcripción en ese idioma.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recursos locales") {
                if model.rows.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Comprobando lo necesario…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.rows) { row in
                        ModelSettingsRow(row: row) { action in
                            handle(action, for: row.id)
                        }
                    }
                }

                HStack {
                    Spacer()
                    Button("Comprobar recursos") {
                        model.refresh()
                    }
                    .disabled(model.isRefreshing)

                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            } footer: {
                Text("Estos recursos se guardan en este Mac y permiten transcribir, distinguir voces y preparar minutas sin enviar tus conversaciones a servicios externos.")
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var minutesTab: some View {
        Form {
            Section("Contenido") {
                Picker("Nivel de detalle", selection: $minutesDetail) {
                    Text("Breve").tag("brief")
                    Text("Equilibrado").tag("balanced")
                    Text("Detallado").tag("detailed")
                }

                Picker("Idioma", selection: $minutesLanguage) {
                    Text("El de la conversación").tag("conversation")
                    Text("Español").tag("es")
                    Text("Inglés").tag("en")
                }
            }

            Section("Instrucciones personalizadas") {
                TextEditor(text: $minutesInstructions)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(alignment: .topLeading) {
                        if minutesInstructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("Ejemplo: prioriza decisiones de producto y deja los pendientes al final.")
                                .foregroundStyle(.tertiary)
                                .allowsHitTesting(false)
                                .padding(.top, 6)
                                .padding(.leading, 5)
                        }
                    }

                Text("Estas indicaciones se aplican a las próximas minutas que generes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Button("Mostrar conversaciones en Finder") {
                    guard let url = try? RecordingStore.defaultLibraryURL() else { return }
                    NSWorkspace.shared.open(url)
                }

                Button("Mostrar recursos locales en Finder") {
                    model.revealModelsFolder()
                }
            }

            if model.hasLegacyQwenData {
                Section("Limpieza") {
                    Button("Eliminar archivos antiguos…", role: .destructive) {
                        isLegacyQwenRemovalPresented = true
                    }
                }
            }

            Section("Datos de Bardo") {
                Button("Mover todas las conversaciones a la Papelera…", role: .destructive) {
                    isLibraryRemovalPresented = true
                }

                Text("Los recursos necesarios para transcribir y preparar minutas se conservan. Puedes eliminarlos individualmente desde Transcripción.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }

    private var privacyTab: some View {
        Form {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tus conversaciones se quedan en este Mac")
                            .font(.headline)
                        Text("Bardo procesa el audio, la transcripción, los hablantes y las minutas de forma local. El contenido de tus reuniones no necesita enviarse a un servicio externo.")
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
                LabeledContent("Micrófono") {
                    Text("Solo se solicita cuando quieres grabar tu voz.")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Grabación del sistema") {
                    Text("macOS muestra su selector antes de capturar audio de una app, ventana o pantalla.")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Almacenamiento") {
                Text("Las grabaciones, transcripciones y minutas se guardan dentro de la biblioteca privada de Bardo en tu carpeta de usuario.")
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
            let roots = ManagedModel.allCases.map(store.root(for:))
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

            if row.usesIndeterminateProgress {
                ProgressView()
                    .progressViewStyle(LinearProgressViewStyle())
            } else if let progress = row.progressFraction {
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
            .controlSize(.small)
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
            if id == .meetingMinutes { return String(localized: "Downloading…") }
            return String.localizedStringWithFormat(String(localized: "Downloading %@"), percentage(fraction))
        case .preparing(let fraction):
            if id == .meetingMinutes { return String(localized: "Checking…") }
            return String.localizedStringWithFormat(String(localized: "Preparing %@"), percentage(fraction))
        case .installed:
            return id == .meetingMinutes
                ? String(localized: "Ready")
                : String(localized: "Installed")
        case .failed:
            return String(localized: "Failed")
        }
    }

    var usesIndeterminateProgress: Bool {
        guard id == .meetingMinutes else { return false }
        switch state {
        case .downloading, .preparing:
            return true
        case .notInstalled, .installed, .failed:
            return false
        }
    }

    var progressFraction: Double? {
        if usesIndeterminateProgress { return nil }
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
    @Published private(set) var hasLegacyQwenData = false
    @Published private(set) var legacyQwenCleanupErrorMessage: String?
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
        case .whisperTurbo:
            try await WhisperTranscriptionService.live().reset()
        case .speakerKit:
            try await SpeakerDiarizationService.live().reset()
        case .meetingMinutes:
            let generator = try? MeetingMinutesGenerator.live()
            await generator?.reset()
            MeetingMinutesRuntimeReadiness.invalidate()
        }
        try BardoModelStore.live().reset(model)
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
            case .whisperTurbo:
                let manager = try TranscriptionModelManager.live()
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
            case .meetingMinutes:
                let generator = try MeetingMinutesGenerator.live()
                try await generator.prepareForSetup { [weak self] snapshot in
                    let state = Self.meetingMinutesState(for: snapshot)
                    Task { @MainActor [weak self] in
                        self?.setState(state, for: model)
                    }
                }
            }

            try Task.checkCancellation()
            setState(.installed, for: model)
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
        if operationTasks[.whisperTurbo] == nil {
            do {
                let whisper = try WhisperTranscriptionService.live()
                let installed = await whisper.hasInstalledModel()
                setState(installed ? .installed : .notInstalled, for: .whisperTurbo)
            } catch { setState(.failed(error.localizedDescription), for: .whisperTurbo) }
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

        refreshMeetingMinutesState()
        if let store = try? BardoModelStore.live() {
            hasLegacyQwenData = store.hasLegacyQwenData()
        }
    }

    private func refreshModel(_ model: ManagedModel) async {
        guard (try? BardoModelStore.live()) != nil else { return }
        switch model {
        case .whisperTurbo:
            let service = try? WhisperTranscriptionService.live()
            setState(await service?.hasInstalledModel() == true ? .installed : .notInstalled, for: model)
        case .speakerKit:
            let service = try? SpeakerDiarizationService.live()
            setState(await service?.hasInstalledModels() == true ? .installed : .notInstalled, for: model)
        case .meetingMinutes:
            refreshMeetingMinutesState()
        }
    }

    func removeLegacyQwenData() {
        legacyQwenCleanupErrorMessage = nil
        do {
            let store = try BardoModelStore.live()
            try store.removeLegacyQwenData()
            hasLegacyQwenData = store.hasLegacyQwenData()
        } catch {
            legacyQwenCleanupErrorMessage = error.localizedDescription
        }
    }

    private func refreshMeetingMinutesState() {
        guard MeetingMinutesModelResourceResolver.isInstalled() else {
            setState(.notInstalled, for: .meetingMinutes)
            return
        }

        if MeetingMinutesRuntimeReadiness.isReady() {
            setState(.installed, for: .meetingMinutes)
        } else {
            setState(
                .failed(String(localized: "The model is downloaded but still needs a local runtime check. Retry to verify it.")),
                for: .meetingMinutes
            )
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
        case .whisperTurbo:
            return ModelSettingsRowState(id: model, title: "Transcripción", detail: "Convierte el audio en texto y conserva los tiempos necesarios para la reproducción.", supportsInstallation: true, state: state)
        case .speakerKit:
            return ModelSettingsRowState(id: model, title: "Identificación de hablantes", detail: "Distingue las voces para organizar la conversación por participante.", supportsInstallation: true, state: state)
        case .meetingMinutes:
            return ModelSettingsRowState(
                id: model,
                title: "Minutas",
                detail: "Organiza la conversación en un documento con temas, decisiones, acuerdos y próximos pasos.",
                supportsInstallation: true,
                state: state
            )
        }
    }

    private nonisolated static func runtimeDownloadState(for fraction: Double) -> ManagedModelState {
        .downloading(min(1, max(0, fraction)))
    }

    private nonisolated static func transcriptionState(for snapshot: TranscriptionSetupProgressSnapshot) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .checking, .optimizingForMac:
            return .preparing(value)
        case .downloading:
            return .downloading(value)
        }
    }

    private nonisolated static func meetingMinutesState(
        for snapshot: MeetingMinutesSetupProgressSnapshot
    ) -> ManagedModelState {
        let value = min(1, max(0, snapshot.fractionCompleted))
        switch snapshot.stage {
        case .downloading:
            return .downloading(value)
        case .loading, .checkingRuntime:
            return .preparing(value)
        }
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
