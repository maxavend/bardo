import Foundation

/// What compressing some conversations would leave behind, estimated before any audio
/// is touched. A track is re-encoded as AAC at the chosen quality, and kept as it is
/// unless the new file would save a real share of its space: the same rule the
/// compression itself follows once the new file exists.
struct AudioCompressionPlan: Equatable, Sendable {
    /// A track is replaced only when its estimate is below this share of its size.
    static let worthwhileShare = 0.8

    /// Bytes the audio takes now.
    let currentBytes: Int64
    /// Bytes it would take afterwards.
    let estimatedBytes: Int64
    /// Conversations with at least one track that would shrink.
    let shrinkingRecordingIDs: Set<Recording.ID>

    var savedBytes: Int64 { max(0, currentBytes - estimatedBytes) }
    var savesSpace: Bool { !shrinkingRecordingIDs.isEmpty && savedBytes > 0 }

    /// - Parameter audioBytes: each track's size on disk; tracks without one are left
    ///   out, as compression cannot weigh them either.
    init(
        recordings: [Recording],
        audioBytes: [AudioAsset.ID: Int64],
        preset: AudioQualityPreset
    ) {
        let encoding = AudioEncoding(preset: preset, format: .aac)
        var current: Int64 = 0
        var estimated: Int64 = 0
        var shrinking: Set<Recording.ID> = []

        for recording in recordings {
            for asset in recording.audioAssets {
                guard let size = audioBytes[asset.id] else { continue }
                current += size
                let compressed = Self.compressedBytes(of: asset, encoding: encoding)
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
        shrinkingRecordingIDs = shrinking
    }

    /// About what one track takes as AAC: never more samples than it already has.
    static func compressedBytes(of asset: AudioAsset, encoding: AudioEncoding) -> Int64 {
        let channels = Int(max(1, asset.metadata.channelCount))
        let bytes = encoding.bytesPerMinute(channels: channels) * max(0, asset.metadata.duration) / 60
        return Int64(bytes.rounded())
    }
}
