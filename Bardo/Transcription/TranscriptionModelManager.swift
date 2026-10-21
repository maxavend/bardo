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
            return String(localized: "Whisper model setup needs about \(formatter.string(fromByteCount: required)) free, but only \(formatter.string(fromByteCount: available)) is available.")
        case .downloadedModelInvalid(let modelID):
            return String(localized: "WhisperKit downloaded \(modelID), but Bardo could not verify the required Core ML model files.")
        }
    }
}

struct TranscriptionModelResources: Equatable, Sendable {
    let modelFolder: URL
    let tokenizerFolder: URL
}

struct WhisperPerformanceProfile: Equatable, Sendable {
    static let sixteenGigabyteThreshold: UInt64 = 16 * 1_024 * 1_024 * 1_024

    let physicalMemory: UInt64
    let incrementalChunkDurationSeconds: Double
    let maxBufferedChunks: Int
    let concurrentWorkerCount: Int
    let usesVAD: Bool
    let temperatureFallbackCount: Int

    init(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemory = physicalMemory
        if physicalMemory >= Self.sixteenGigabyteThreshold {
            incrementalChunkDurationSeconds = 120
            maxBufferedChunks = 2
            concurrentWorkerCount = 8
        } else {
            incrementalChunkDurationSeconds = 90
            maxBufferedChunks = 1
            concurrentWorkerCount = 4
        }
        usesVAD = true
        temperatureFallbackCount = 5
    }
}

actor TranscriptionModelManager {
    /// Whisper large-v3 Turbo: fast and very accurate, and what first-run setup installs.
    static let modelID = "large-v3-v20240930_turbo_632MB"
    static let defaultModelID = modelID
    /// Whisper large-v3 in full: the most accurate, and slower.
    static let largeModelID = "large-v3"
    static let minimumFreeBytesForDownload: Int64 = 1_500_000_000

    /// The WhisperKit variant this manager installs; each lives in its own folder.
    let variant: String
    private let minimumFreeBytes: Int64

    typealias CapacityProvider = @Sendable (URL) throws -> Int64?
    typealias TokenizerPreparer = @Sendable (URL) async throws -> Void
    /// Downloads `variant` under the root and returns the model folder.
    typealias ModelDownloader = @Sendable (
        _ variant: String,
        _ downloadRoot: URL,
        _ progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL

    private let downloadRoot: URL
    private let fileManager: FileManager
    private let availableCapacity: CapacityProvider
    private let prepareTokenizer: TokenizerPreparer
    private let downloadModel: ModelDownloader
    private var cachedResources: TranscriptionModelResources?
    private var modelState: ManagedModelState = .notInstalled
    /// One download/preparation at a time, shared by setup, Settings and transcription.
    private var inFlightPreparation: Task<TranscriptionModelResources, Error>?
    private var preparationWaiters = 0
    private let preparationProgress = ProgressFanOut<Double>()

    private static let sharedManagerResult: Result<TranscriptionModelManager, Error> = Result {
        TranscriptionModelManager(downloadRoot: try BardoModelStore.live().root(for: .whisperTurbo))
    }
    private static let sharedLargeManagerResult: Result<TranscriptionModelManager, Error> = Result {
        TranscriptionModelManager(
            downloadRoot: try BardoModelStore.live().root(for: .whisperLarge),
            variant: largeModelID,
            minimumFreeBytes: 3_600_000_000
        )
    }

    init(
        downloadRoot: URL,
        variant: String = TranscriptionModelManager.modelID,
        minimumFreeBytes: Int64 = TranscriptionModelManager.minimumFreeBytesForDownload,
        fileManager: FileManager = .default,
        availableCapacity: @escaping CapacityProvider = { url in
            try TranscriptionModelManager.systemAvailableCapacity(at: url)
        },
        prepareTokenizer: @escaping TokenizerPreparer = { root in
            try await TranscriptionModelManager.prepareLargeV3Tokenizer(in: root)
        },
        downloadModel: @escaping ModelDownloader = { variant, root, progress in
            try await WhisperKit.download(
                variant: variant,
                downloadBase: root,
                useBackgroundSession: false,
                progressCallback: { downloadProgress in
                    progress(downloadProgress.fractionCompleted)
                }
            )
        }
    ) {
        self.downloadRoot = downloadRoot.standardizedFileURL
        self.variant = variant
        self.minimumFreeBytes = minimumFreeBytes
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
        self.prepareTokenizer = prepareTokenizer
        self.downloadModel = downloadModel
    }

    /// The app-wide manager. Every caller shares it so concurrent requests coalesce
    /// into one download instead of racing in the same folder.
    static func live() throws -> TranscriptionModelManager {
        try sharedManagerResult.get()
    }

    /// The app-wide manager of one Whisper model.
    static func live(for model: ManagedModel) throws -> TranscriptionModelManager {
        model == .whisperLarge ? try sharedLargeManagerResult.get() : try sharedManagerResult.get()
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
        guard inFlightPreparation == nil else { throw ModelOperationError.inUse }
        cachedResources = nil
        guard downloadRoot.resolvingSymlinksInPath().path == downloadRoot.path else {
            throw TranscriptionModelError.downloadedModelInvalid(variant)
        }
        if fileManager.fileExists(atPath: downloadRoot.path) {
            try fileManager.removeItem(at: downloadRoot)
        }
        modelState = .notInstalled
    }

    func ensureResourcesAvailable(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TranscriptionModelResources {
        try Task.checkCancellation()
        if let cachedResources, verifyModelFolder(cachedResources.modelFolder), tokenizerIsAvailable {
            modelState = .installed
            progress(1)
            return cachedResources
        }

        // A cancelled download may still be unwinding; never start a second one into
        // the same folder until it has stopped. Waiting honours this caller's own cancel.
        while let current = inFlightPreparation, current.isCancelled {
            _ = try? await CancellableAwait.value(of: current, cancelUnderlyingTask: false)
            try Task.checkCancellation()
            if inFlightPreparation == current { inFlightPreparation = nil }
        }

        let preparation: Task<TranscriptionModelResources, Error>
        if let inFlightPreparation {
            preparation = inFlightPreparation
        } else {
            preparationProgress.reset()
            let fanOut = preparationProgress
            preparation = Task { try await self.prepareResources(progress: { fanOut.send($0) }) }
            inFlightPreparation = preparation
            Task {
                _ = try? await preparation.value
                self.preparationFinished(preparation)
            }
        }

        let observer = preparationProgress.add(progress)
        preparationWaiters += 1
        defer {
            preparationProgress.remove(observer)
            preparationWaiters -= 1
            // Setup, Settings and a transcription can share one download. Stop it only
            // when the last of them gave up.
            if Task.isCancelled, preparationWaiters == 0, inFlightPreparation == preparation {
                preparation.cancel()
            }
        }
        return try await CancellableAwait.value(of: preparation, cancelUnderlyingTask: false)
    }

    private func preparationFinished(_ preparation: Task<TranscriptionModelResources, Error>) {
        if inFlightPreparation == preparation {
            inFlightPreparation = nil
        }
    }

    var isPreparing: Bool { inFlightPreparation != nil }

    private func prepareResources(
        progress: @escaping @Sendable (Double) -> Void
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
                let downloaded = try await downloadModel(variant, downloadRoot) { fraction in
                    progress(min(1, max(0, fraction.isFinite ? fraction : 0)) * 0.9)
                }
                guard verifyModelFolder(downloaded) else {
                    throw TranscriptionModelError.downloadedModelInvalid(variant)
                }
                modelFolder = downloaded
                modelState = .preparing(0.9)
                progress(0.9)
            }

            try Task.checkCancellation()
            try await prepareTokenizer(downloadRoot)
            guard verifyModelFolder(modelFolder), tokenizerIsAvailable else {
                throw TranscriptionModelError.downloadedModelInvalid(variant)
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

    func selectedModelID() -> String { variant }

    func selectedDefinition() -> TranscriptionModelDefinition {
        TranscriptionModelDefinition(
            id: variant,
            displayName: variant == Self.largeModelID ? "WhisperKit large-v3" : "WhisperKit large-v3 Turbo"
        )
    }

    func selectedSelection() -> TranscriptionSelection {
        TranscriptionSelection(modelID: variant)
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
        guard availableBytes >= minimumFreeBytes else {
            throw TranscriptionModelError.insufficientDiskSpace(
                requiredBytes: minimumFreeBytes,
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
            guard url.lastPathComponent.hasSuffix(variant), verifyModelFolder(url) else { continue }
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
