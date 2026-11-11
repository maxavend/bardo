import Foundation

/// How much space Bardo takes on this Mac, conversation by conversation.
struct LibraryStorageReport: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// Everything in the conversation's folder: audio, transcript and notes.
        let totalBytes: Int64
        /// Each audio track's size.
        let audioBytes: [AudioAsset.ID: Int64]

        var audioTotal: Int64 { audioBytes.values.reduce(0, +) }
    }

    var entries: [Recording.ID: Entry] = [:]
    /// The whole Library folder, including what belongs to no listed conversation.
    var libraryBytes: Int64 = 0
    /// Speech and speaker models.
    var modelsBytes: Int64 = 0
    /// Free space on the Library's volume, as macOS counts it for important files.
    var availableBytes: Int64?

    static let empty = LibraryStorageReport()

    var audioBytes: Int64 { entries.values.reduce(0) { $0 + $1.audioTotal } }
    /// Transcripts, notes and anything else in the Library that is not audio.
    var otherLibraryBytes: Int64 { max(0, libraryBytes - audioBytes) }
    var totalBytes: Int64 { libraryBytes + modelsBytes }

    /// Every track's size, for estimating compression.
    var allAudioBytes: [AudioAsset.ID: Int64] {
        entries.values.reduce(into: [:]) { result, entry in
            result.merge(entry.audioBytes) { current, _ in current }
        }
    }
}

enum LibraryStorage {
    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// The size of every regular file below `root`.
    static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: []
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

    /// The speech and speaker models Bardo has installed.
    static func modelsSize() -> Int64 {
        guard let store = try? BardoModelStore.live() else { return 0 }
        let roots = Set(ManagedModel.allCases.map { store.root(for: $0).standardizedFileURL })
        return roots.reduce(0) { $0 + directorySize($1) }
    }

    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// A compression of one or several conversations, while it runs and once it ends.
struct AudioCompressionRun: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preparing
        case encoding(TrackProgress)
        case saving
        case preparingPlayback
    }

    struct TrackProgress: Equatable, Sendable {
        let id = UUID()
        let title: String
        let number: Int
        let count: Int
        let duration: TimeInterval
        let precedingDuration: TimeInterval
        let recordingDuration: TimeInterval
        var processed: TimeInterval = 0

        var recordingFraction: Double? {
            guard recordingDuration > 0 else { return nil }
            return (precedingDuration + processed) / recordingDuration
        }
    }

    struct Failure: Equatable, Sendable {
        let title: String
        let reason: String
    }

    let total: Int
    var copyFolder: URL?
    var completed = 0
    var currentTitle: String?
    var phase: Phase = .preparing
    var stoppingAfterCurrent = false
    var savedBytes: Int64 = 0
    var copiedBytes: Int64 = 0
    var copyURLs: [URL] = []
    var failures: [Failure] = []
    var isRunning = true
    /// Stopped before every conversation was compressed.
    var wasStopped = false
}
