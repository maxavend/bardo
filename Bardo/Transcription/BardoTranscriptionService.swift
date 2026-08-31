import Foundation

actor BardoTranscriptionService: RecordingTranscribing {
    private static let sharedResult: Result<BardoTranscriptionService, Error> = Result {
        try BardoTranscriptionService()
    }

    private let instant: ParakeetTranscriptionService
    private let balanced: WhisperTranscriptionService
    private let maximum: WhisperTranscriptionService
    private let balancedManager: TranscriptionModelManager
    private let maximumManager: TranscriptionModelManager
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let whisperRoot = applicationSupport
            .appendingPathComponent("Bardo", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)

        let balancedManager = TranscriptionModelManager(
            modelID: TranscriptionModelManager.fastModelID,
            downloadRoot: whisperRoot
        )
        let maximumManager = TranscriptionModelManager(
            modelID: TranscriptionModelManager.maximumAccuracyModelID,
            downloadRoot: whisperRoot
        )

        self.instant = ParakeetTranscriptionService()
        self.balancedManager = balancedManager
        self.maximumManager = maximumManager
        self.balanced = WhisperTranscriptionService(modelManager: balancedManager)
        self.maximum = WhisperTranscriptionService(modelManager: maximumManager)
        self.fileManager = fileManager
    }

    static func live() throws -> BardoTranscriptionService {
        try sharedResult.get()
    }

    func transcribe(
        recording: Recording,
        store: RecordingStore,
        progress: @escaping @Sendable (TranscriptionProgressSnapshot) -> Void
    ) async throws -> Transcript {
        switch TranscriptionQuality.current {
        case .instant:
            return try await instant.transcribe(
                recording: recording,
                store: store,
                progress: progress
            )
        case .balanced:
            return try await balanced.transcribe(
                recording: recording,
                store: store,
                progress: progress
            )
        case .maximum:
            return try await maximum.transcribe(
                recording: recording,
                store: store,
                progress: progress
            )
        }
    }

    func warmUpIfInstalled() async {
        await warmUpIfInstalled(for: TranscriptionQuality.current)
    }

    func warmUpIfInstalled(for quality: TranscriptionQuality) async {
        switch quality {
        case .instant:
            await instant.warmUpIfInstalled()
        case .balanced:
            await balanced.warmUpIfInstalled()
        case .maximum:
            await maximum.warmUpIfInstalled()
        }
    }

    func hasInstalledModel(for quality: TranscriptionQuality) async -> Bool {
        switch quality {
        case .instant:
            return await instant.hasInstalledModel()
        case .balanced:
            return await balanced.hasInstalledModel()
        case .maximum:
            return await maximum.hasInstalledModel()
        }
    }

    func prepareForUse(
        quality: TranscriptionQuality,
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws {
        switch quality {
        case .instant:
            try await instant.prepareForUse(progress: progress)
        case .balanced:
            try await balanced.prepareForUse(progress: progress)
        case .maximum:
            try await maximum.prepareForUse(progress: progress)
        }
    }

    func modelState(for quality: TranscriptionQuality) async -> TranscriptionModelState {
        let url: URL?
        switch quality {
        case .instant:
            url = ParakeetTranscriptionService.hasInstalledModelOnDisk()
                ? ParakeetTranscriptionService.modelDirectory
                : nil
        case .balanced:
            url = try? await balancedManager.installedModelURL()
        case .maximum:
            url = try? await maximumManager.installedModelURL()
        }

        return TranscriptionModelState(
            quality: quality,
            isInstalled: url != nil,
            sizeBytes: url.flatMap(directorySize)
        )
    }

    func downloadModel(
        for quality: TranscriptionQuality,
        progress: @escaping @Sendable (TranscriptionSetupProgressSnapshot) -> Void
    ) async throws {
        try await prepareForUse(quality: quality, progress: progress)
    }

    func removeModel(for quality: TranscriptionQuality) async throws {
        let url: URL?
        switch quality {
        case .instant:
            await instant.unload()
            url = ParakeetTranscriptionService.hasInstalledModelOnDisk()
                ? ParakeetTranscriptionService.modelDirectory
                : nil
        case .balanced:
            url = try await balancedManager.installedModelURL()
        case .maximum:
            url = try await maximumManager.installedModelURL()
        }

        guard let url, fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func directorySize(_ url: URL) -> Int64? {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
            .fileSizeKey
        ]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else {
                continue
            }
            let size = values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.fileSize
                ?? 0
            total += Int64(size)
        }
        return total
    }
}
