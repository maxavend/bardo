import Foundation
import WhisperKit

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

actor TranscriptionModelManager {
    static let defaultModelID = "large-v3-v20240930_626MB"
    static let minimumFreeBytesForDownload: Int64 = 1_500_000_000

    typealias CapacityProvider = @Sendable (URL) throws -> Int64?

    private let modelID: String
    private let downloadRoot: URL
    private let fileManager: FileManager
    private let availableCapacity: CapacityProvider

    init(
        modelID: String = TranscriptionModelManager.defaultModelID,
        downloadRoot: URL,
        fileManager: FileManager = .default,
        availableCapacity: @escaping CapacityProvider = { url in
            try TranscriptionModelManager.systemAvailableCapacity(at: url)
        }
    ) {
        self.modelID = modelID
        self.downloadRoot = downloadRoot
        self.fileManager = fileManager
        self.availableCapacity = availableCapacity
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

    func installedModelURL() throws -> URL? {
        try ensureDirectoryExists(downloadRoot)
        return findInstalledModel()
    }

    func ensureModelAvailable(
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        try ensureDirectoryExists(downloadRoot)
        if let installed = findInstalledModel() {
            progress(1)
            return installed
        }

        try verifyFreeSpace()
        progress(0)

        let downloaded = try await WhisperKit.download(
            variant: modelID,
            downloadBase: downloadRoot,
            progressCallback: { downloadProgress in
                progress(min(1, max(0, downloadProgress.fractionCompleted)))
            }
        )

        guard verifyModelFolder(downloaded) else {
            throw TranscriptionModelError.downloadedModelInvalid(modelID)
        }
        progress(1)
        return downloaded
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
            if requiredNames.contains(baseName),
               url.pathExtension == "mlmodelc" || url.pathExtension == "mlpackage" {
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
