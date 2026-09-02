import Foundation
@preconcurrency import WhisperKit

enum TranscriptionModelError: Error, LocalizedError, Equatable, Sendable {
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)
    case downloadedModelInvalid(String)

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "Whisper model setup needs about \(formatter.string(fromByteCount: required)) free, but only \(formatter.string(fromByteCount: available)) is available."
        case .downloadedModelInvalid(let modelID):
            return "WhisperKit downloaded \(modelID), but Bardo could not verify the required Core ML model files."
        }
    }
}

struct TranscriptionModelResources: Equatable, Sendable {
    let modelFolder: URL
    let tokenizerFolder: URL
}

struct TranscriptionModelDefinition: Equatable, Sendable {
    let id: String
    let displayName: String
    let requiredFreeBytes: Int64
    let isDefault: Bool
}

actor TranscriptionModelManager {
    // Turbo keeps Whisper large-v3 multilingual quality while reducing the decoder from
    // 32 layers to 4. The compressed variant is a better default for a 16 GB Mac because
    // it substantially reduces model storage and memory pressure without falling back to
    // a small/medium accuracy tier.
    static let balancedModelID = "large-v3-v20240930_turbo_632MB"
    static let maximumAccuracyModelID = "large-v3-v20240930_626MB"
    static let fastModelID = balancedModelID
    static let defaultModelID = balancedModelID
    static let minimumFreeBytesForDownload: Int64 = 1_500_000_000

    static let catalog: [TranscriptionModelDefinition] = [
        TranscriptionModelDefinition(
            id: balancedModelID,
            displayName: "WhisperKit large-v3 Turbo",
            requiredFreeBytes: minimumFreeBytesForDownload,
            isDefault: true
        ),
        TranscriptionModelDefinition(
            id: maximumAccuracyModelID,
            displayName: "WhisperKit large-v3",
            requiredFreeBytes: minimumFreeBytesForDownload,
            isDefault: false
        )
    ]

    static let defaultDefinition = catalog.first(where: \.isDefault)!

    typealias CapacityProvider = @Sendable (URL) throws -> Int64?
    typealias TokenizerPreparer = @Sendable (URL) async throws -> Void

    private let definition: TranscriptionModelDefinition
    private let downloadRoot: URL
    private let fileManager: FileManager
    private let availableCapacity: CapacityProvider
    private let prepareTokenizer: TokenizerPreparer
    private var cachedResources: TranscriptionModelResources?
    private var modelState: ManagedModelState = .notInstalled

    init(
        definition: TranscriptionModelDefinition = TranscriptionModelManager.defaultDefinition,
        downloadRoot: URL,
        fileManager: FileManager = .default,
        availableCapacity: @escaping CapacityProvider = { url in
            try TranscriptionModelManager.systemAvailableCapacity(at: url)
        },
        prepareTokenizer: @escaping TokenizerPreparer = { root in
            try await TranscriptionModelManager.prepareLargeV3Tokenizer(in: root)
        }
    ) {
        self.definition = definition
        self.downloadRoot = downloadRoot
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
        self.prepareTokenizer = prepareTokenizer
    }

    static func live() throws -> TranscriptionModelManager {
        try live(definition: defaultDefinition)
    }

    static func live(
        definition: TranscriptionModelDefinition
    ) throws -> TranscriptionModelManager {
        let store = try BardoModelStore.live()
        return TranscriptionModelManager(
            definition: definition,
            downloadRoot: store.root(for: managedModel(for: definition))
        )
    }

    private static func managedModel(
        for definition: TranscriptionModelDefinition
    ) -> ManagedModel {
        if definition.id == maximumAccuracyModelID {
            return .whisperMaximumAccuracy
        }
        return .whisperBalanced
    }

    static func preset(
        for definition: TranscriptionModelDefinition
    ) -> TranscriptionPreset {
        definition.id == maximumAccuracyModelID ? .maximumAccuracy : .balanced
    }

    nonisolated static func systemAvailableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        guard let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(available)
    }

    nonisolated static func prepareLargeV3Tokenizer(in root: URL) async throws {
        _ = try await ModelUtilities.loadTokenizer(
            for: .largev3,
            tokenizerFolder: root,
            useBackgroundSession: false
        )
    }

    func installedModelURL() throws -> URL? {
        try ensureDirectoryExists(downloadRoot)
        if let cachedResources, verifyModelFolder(cachedResources.modelFolder) {
            modelState = .installed
            return cachedResources.modelFolder
        }
        let installed = findInstalledModel()
        modelState = installed == nil ? .notInstalled : .installed
        return installed
    }

    func hasInstalledModel() throws -> Bool {
        try installedModelURL() != nil
    }

    func ensureResourcesAvailable(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TranscriptionModelResources {
        do {
            try ensureDirectoryExists(downloadRoot)

            if let cachedResources, verifyModelFolder(cachedResources.modelFolder) {
                modelState = .installed
                progress(1)
                return cachedResources
            }

            let modelFolder: URL
            if let installed = findInstalledModel() {
                modelFolder = installed
                modelState = .preparing(0.9)
                progress(0.9)
            } else {
                try verifyFreeSpace()
                modelState = .downloading(0)
                progress(0)

                let downloaded = try await WhisperKit.download(
                    variant: definition.id,
                    downloadBase: downloadRoot,
                    progressCallback: { downloadProgress in
                        let modelProgress = min(1, max(0, downloadProgress.fractionCompleted))
                        let overallProgress = modelProgress * 0.9
                        progress(overallProgress)
                    }
                )

                guard verifyModelFolder(downloaded) else {
                    throw TranscriptionModelError.downloadedModelInvalid(definition.id)
                }
                modelFolder = downloaded
                modelState = .preparing(0.9)
                progress(0.9)
            }

            // Tokenizer preparation is intentionally cached for the lifetime of this manager.
            // The previous implementation repeated this Hub/cache resolution for every 8-second
            // transcription even when nothing had changed.
            try await prepareTokenizer(downloadRoot)
            modelState = .preparing(1)
            let resources = TranscriptionModelResources(
                modelFolder: modelFolder,
                tokenizerFolder: downloadRoot
            )
            cachedResources = resources
            modelState = .installed
            progress(1)
            return resources
        } catch {
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    func selectedModelID() -> String {
        definition.id
    }

    func selectedDefinition() -> TranscriptionModelDefinition {
        definition
    }

    func selectedSelection() -> TranscriptionSelection {
        TranscriptionSelection(
            preset: Self.preset(for: definition),
            backend: .whisperKit,
            modelID: definition.id
        )
    }

    func state() -> ManagedModelState {
        modelState
    }

    private func verifyFreeSpace() throws {
        guard let availableBytes = try availableCapacity(downloadRoot) else { return }
        guard availableBytes >= definition.requiredFreeBytes else {
            throw TranscriptionModelError.insufficientDiskSpace(
                requiredBytes: definition.requiredFreeBytes,
                availableBytes: availableBytes
            )
        }
    }

    private func findInstalledModel() -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: downloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.contains(definition.id) else { continue }
            if verifyModelFolder(url) {
                return url
            }
        }
        return nil
    }

    private func verifyModelFolder(_ folder: URL) -> Bool {
        let requiredNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        var found = Set<String>()
        for case let url as URL in enumerator {
            let baseName = url.deletingPathExtension().lastPathComponent
            let supportedModelExtension = url.pathExtension == "mlmodelc"
                || url.pathExtension == "mlpackage"
            if requiredNames.contains(baseName), supportedModelExtension {
                found.insert(baseName)
            }
            if found.count == requiredNames.count { return true }
        }
        return false
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
