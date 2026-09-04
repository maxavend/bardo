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

struct WhisperPerformanceProfile: Equatable, Sendable {
    static let sixteenGigabyteThreshold: UInt64 = 16 * 1_024 * 1_024 * 1_024

    static let diagnosticsFlag = "BARDO_WHISPER_DIAGNOSTICS"
    static let benchmarkAudioKey = "BARDO_WHISPER_BENCHMARK_AUDIO"
    static let workersOverrideKey = "BARDO_WHISPER_WORKERS"
    static let chunkOverrideKey = "BARDO_WHISPER_CHUNK_SECONDS"
    static let bufferedChunksOverrideKey = "BARDO_WHISPER_BUFFERED_CHUNKS"

    let physicalMemory: UInt64
    let incrementalChunkDurationSeconds: Double
    let maxBufferedChunks: Int
    let concurrentWorkerCount: Int
    let usesVAD: Bool
    let temperatureFallbackCount: Int

    init(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        let isSixteenGigabyteClass = physicalMemory >= Self.sixteenGigabyteThreshold
        var chunkDuration = isSixteenGigabyteClass ? 120.0 : 90.0
        var bufferedChunks = isSixteenGigabyteClass ? 2 : 1
        var workers = isSixteenGigabyteClass ? 8 : 4

        if Self.diagnosticsEnabled(in: environment) {
            if let value = environment[Self.chunkOverrideKey].flatMap(Double.init),
               (30...600).contains(value) {
                chunkDuration = value
            }
            if let value = environment[Self.bufferedChunksOverrideKey].flatMap(Int.init),
               (1...8).contains(value) {
                bufferedChunks = value
            }
            if let value = environment[Self.workersOverrideKey].flatMap(Int.init),
               (1...16).contains(value) {
                workers = value
            }
        }

        self.physicalMemory = physicalMemory
        incrementalChunkDurationSeconds = chunkDuration
        maxBufferedChunks = bufferedChunks
        concurrentWorkerCount = workers
        usesVAD = true
        temperatureFallbackCount = 5
    }

    init(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        incrementalChunkDurationSeconds: Double,
        maxBufferedChunks: Int,
        concurrentWorkerCount: Int,
        usesVAD: Bool = true,
        temperatureFallbackCount: Int = 5
    ) {
        self.physicalMemory = physicalMemory
        self.incrementalChunkDurationSeconds = min(600, max(30, incrementalChunkDurationSeconds))
        self.maxBufferedChunks = min(8, max(1, maxBufferedChunks))
        self.concurrentWorkerCount = min(16, max(1, concurrentWorkerCount))
        self.usesVAD = usesVAD
        self.temperatureFallbackCount = min(10, max(0, temperatureFallbackCount))
    }

    static func diagnosticsEnabled(
        in environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[diagnosticsFlag] == "1"
            || environment[benchmarkAudioKey]?.isEmpty == false
    }
}

actor TranscriptionModelManager {
    /// Whisper large-v3 Turbo is the only ASR model exposed by Bardo.
    static let modelID = "large-v3-v20240930_turbo_632MB"
    static let defaultModelID = modelID
    static let minimumFreeBytesForDownload: Int64 = 1_500_000_000

    typealias CapacityProvider = @Sendable (URL) throws -> Int64?
    typealias TokenizerPreparer = @Sendable (URL) async throws -> Void

    private let downloadRoot: URL
    private let fileManager: FileManager
    private let availableCapacity: CapacityProvider
    private let prepareTokenizer: TokenizerPreparer
    private var cachedResources: TranscriptionModelResources?
    private var modelState: ManagedModelState = .notInstalled

    init(
        downloadRoot: URL,
        fileManager: FileManager = .default,
        availableCapacity: @escaping CapacityProvider = { url in
            try TranscriptionModelManager.systemAvailableCapacity(at: url)
        },
        prepareTokenizer: @escaping TokenizerPreparer = { root in
            try await TranscriptionModelManager.prepareLargeV3Tokenizer(in: root)
        }
    ) {
        self.downloadRoot = downloadRoot.standardizedFileURL
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
        self.prepareTokenizer = prepareTokenizer
    }

    static func live() throws -> TranscriptionModelManager {
        let store = try BardoModelStore.live()
        return TranscriptionModelManager(downloadRoot: store.root(for: .whisperTurbo))
    }

    nonisolated static func systemAvailableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
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

    /// Exposed only for static tests and diagnostics; the root is always Bardo-owned.
    func modelRootURL() -> URL { downloadRoot }

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

    func reset() throws {
        cachedResources = nil
        guard downloadRoot.resolvingSymlinksInPath() == downloadRoot else {
            throw TranscriptionModelError.downloadedModelInvalid(Self.modelID)
        }
        if fileManager.fileExists(atPath: downloadRoot.path) {
            try fileManager.removeItem(at: downloadRoot)
        }
        modelState = .notInstalled
    }

    func ensureResourcesAvailable(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TranscriptionModelResources {
        do {
            try Task.checkCancellation()
            try ensureDirectoryExists(downloadRoot)

            if let cachedResources, verifyModelFolder(cachedResources.modelFolder), tokenizerIsAvailable {
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
                    variant: Self.modelID,
                    downloadBase: downloadRoot,
                    useBackgroundSession: false,
                    progressCallback: { downloadProgress in
                        let fraction = min(1, max(0, downloadProgress.fractionCompleted))
                        progress(fraction * 0.9)
                    }
                )
                guard verifyModelFolder(downloaded) else {
                    throw TranscriptionModelError.downloadedModelInvalid(Self.modelID)
                }
                modelFolder = downloaded
                modelState = .preparing(0.9)
                progress(0.9)
            }

            try Task.checkCancellation()
            try await prepareTokenizer(downloadRoot)
            guard verifyModelFolder(modelFolder), tokenizerIsAvailable else {
                throw TranscriptionModelError.downloadedModelInvalid(Self.modelID)
            }
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

    func selectedModelID() -> String { Self.modelID }

    func selectedDefinition() -> TranscriptionModelDefinition {
        TranscriptionModelDefinition(id: Self.modelID, displayName: "WhisperKit large-v3 Turbo")
    }

    func selectedSelection() -> TranscriptionSelection {
        TranscriptionSelection(modelID: Self.modelID)
    }

    func state() -> ManagedModelState { modelState }

    private var tokenizerIsAvailable: Bool {
        guard let enumerator = fileManager.enumerator(
            at: downloadRoot,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "tokenizer.json",
                  let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { continue }
            return true
        }
        return false
    }

    private func verifyFreeSpace() throws {
        guard let availableBytes = try availableCapacity(downloadRoot) else { return }
        guard availableBytes >= Self.minimumFreeBytesForDownload else {
            throw TranscriptionModelError.insufficientDiskSpace(
                requiredBytes: Self.minimumFreeBytesForDownload,
                availableBytes: availableBytes
            )
        }
    }

    private func findInstalledModel() -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: downloadRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.contains(Self.modelID), verifyModelFolder(url) else { continue }
            return url
        }
        return nil
    }

    private func verifyModelFolder(_ folder: URL) -> Bool {
        let requiredNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }

        var found = Set<String>()
        for case let url as URL in enumerator {
            let baseName = url.deletingPathExtension().lastPathComponent
            let supportedModelExtension = url.pathExtension == "mlmodelc" || url.pathExtension == "mlpackage"
            if requiredNames.contains(baseName), supportedModelExtension { found.insert(baseName) }
            if found.count == requiredNames.count { return true }
        }
        return false
    }

    private func ensureDirectoryExists(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

struct TranscriptionModelDefinition: Equatable, Sendable {
    let id: String
    let displayName: String
}
