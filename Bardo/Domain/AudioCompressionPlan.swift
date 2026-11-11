import Foundation

/// The stored mix is reusable only if it covers the original sources and timeline.
struct AudioCompressionMix {
    let originals: [AudioAsset]
    let existing: AudioAsset?
    let duration: TimeInterval

    init?(recording: Recording) {
        guard recording.audioAssets.count > 1 else { return nil }
        let originals = recording.audioAssets.filter { !$0.role.isDerived }
        guard !originals.isEmpty else { return nil }
        let sourceIDs = Set(originals.map(\.id))
        let sourceEnd = originals.map { $0.timelineOffset + $0.metadata.duration }.max() ?? 0
        let existing = recording.audioAssets.first {
            $0.role == .conversationMix && $0.timelineOffset == 0
                && sourceIDs.isSubset(of: Set($0.derivedFromAssetIDs))
                && $0.metadata.duration >= sourceEnd - 0.25
        }
        self.originals = originals
        self.existing = existing
        duration = max(sourceEnd, existing?.metadata.duration ?? 0)
    }
}

/// What compressing some conversations would leave behind, estimated before any audio
/// is touched. A replacement requires a worthwhile saving. A test copy includes
/// all tracks so the same recording can be compared across formats.
struct AudioCompressionPlan: Equatable, Sendable {
    /// A track is replaced only when its estimate is below this share of its size.
    static let worthwhileShare = 0.8

    /// Bytes the audio takes now.
    let currentBytes: Int64
    /// Bytes it would take afterwards.
    let estimatedBytes: Int64
    /// Bytes a complete copy would take.
    let copyBytes: Int64
    /// Conversations with at least one track that would shrink.
    let shrinkingRecordingIDs: Set<Recording.ID>

    var savedBytes: Int64 { max(0, currentBytes - estimatedBytes) }
    var savesSpace: Bool { !shrinkingRecordingIDs.isEmpty && savedBytes > 0 }

    /// - Parameter audioBytes: each track's size on disk; tracks without one are left
    ///   out, as compression cannot weigh them either.
    init(
        recordings: [Recording],
        audioBytes: [AudioAsset.ID: Int64],
        encoding: AudioCompressionEncoding = AudioCompressionEncoding(),
        mergeTracks: Bool = false
    ) {
        var current: Int64 = 0
        var estimated: Int64 = 0
        var copy: Int64 = 0
        var shrinking: Set<Recording.ID> = []

        for recording in recordings {
            if mergeTracks, let mix = AudioCompressionMix(recording: recording) {
                let sizes = recording.audioAssets.compactMap { audioBytes[$0.id] }
                let before = sizes.reduce(0, +)
                let after = Self.compressedBytes(duration: mix.duration, encoding: encoding)
                let hasSources = mix.originals.allSatisfy { audioBytes[$0.id] != nil }
                    || mix.existing.flatMap { audioBytes[$0.id] } != nil
                copy += after
                current += before
                if hasSources, Double(after) < Double(before) * Self.worthwhileShare {
                    estimated += after
                    shrinking.insert(recording.id)
                } else {
                    estimated += before
                }
                continue
            }
            for asset in recording.audioAssets {
                let compressed = Self.compressedBytes(of: asset, encoding: encoding)
                copy += compressed
                guard let size = audioBytes[asset.id] else { continue }
                current += size
                if Double(compressed) < Double(size) * Self.worthwhileShare {
                    estimated += compressed
                    shrinking.insert(recording.id)
                } else {
                    estimated += size
                }
            }
        }

        currentBytes = current
        estimatedBytes = estimated
        copyBytes = copy
        shrinkingRecordingIDs = shrinking
    }

    static func compressedBytes(of asset: AudioAsset, encoding: AudioCompressionEncoding) -> Int64 {
        compressedBytes(duration: asset.metadata.duration, encoding: encoding)
    }

    static func compressedBytes(duration: TimeInterval, encoding: AudioCompressionEncoding) -> Int64 {
        guard duration.isFinite, duration > 0 else { return 0 }
        let bytes = Double(encoding.bitsPerSecond) * duration / 8
        return Int64(bytes.rounded())
    }
}
