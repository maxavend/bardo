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

actor TranscriptionModelManager {
    static let defaultModelID = "large-v3-v20240930_626MB"
    static let minimumFreeBytesForDownload: Int64 = 1_500_000_000

    typealias CapacityProvider = @Sendable (URL) throws -> Int64?
    typealias TokenizerPreparer = @Sendable (URL) async throws -> Void

    private let modelID: String
    private let downloadRoot: URL
    private let fileManager: FileManager
    private let availableCapacity: CapacityProvider
    private let prepareTokenizer: TokenizerPreparer

    init(
        modelID: String = TranscriptionModelManager.defaultModelID,
        downloadRoot: URL,
        fileManager: FileManager = .default,
        availableCapacity: @escaping CapacityProvider = { url in
            try TranscriptionModelManager.systemAvailableCapacity(at: url)
        },
        prepareTokenizer: @escaping TokenizerPreparer = { root in
            try await TranscriptionModelManager.prepareLargeV3Tokenizer(in: root)
        }
    ) {
        self.modelID = modelID
        self.downloadRoot = downloadRoot
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
        self.prepareTokenizer = prepareTokenizer
    }

    static func live() throws -> TranscriptionModelManager {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        return TranscriptionModelManager(downloadRoot: root)
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
        return findInstalledModel()
    }

    func ensureResourcesAvailable(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> TranscriptionModelResources {
        try ensureDirectoryExists(downloadRoot)

        let modelFolder: URL
        if let installed = findInstalledModel() {
            modelFolder = installed
            progress(0.9)
        } else {
            try verifyFreeSpace()
            progress(0)

            let downloaded = try await WhisperKit.download(
                variant: modelID,
                downloadBase: downloadRoot,
                progressCallback: { downloadProgress in
                    let modelProgress = min(1, max(0, downloadProgress.fractionCompleted))
                    progress(modelProgress * 0.9)
                }
            )

            guard verifyModelFolder(downloaded) else {
                throw TranscriptionModelError.downloadedModelInvalid(modelID)
            }
            modelFolder = downloaded
            progress(0.9)
        }

        // WhisperKit's tokenizer is a separate Hub artifact in v1.0.0. Preparing it here
        // makes "model setup complete" truthful and avoids a surprise network request when
        // the first transcription begins. The same root is later supplied to WhisperKit.
        try await prepareTokenizer(downloadRoot)
        progress(1)

        return TranscriptionModelResources(
            modelFolder: modelFolder,
            tokenizerFolder: downloadRoot
        )
    }

    func selectedModelID() -> String {
        modelID
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
        ) else {
            return nil
        }

        for case let url as URL in enumerator {
            guard url.lastPathComponent.contains(modelID) else { continue }
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
