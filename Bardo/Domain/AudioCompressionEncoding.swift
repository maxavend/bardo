import Foundation

/// Output settings for audio already in the library.
struct AudioCompressionEncoding: Hashable, Sendable {
    enum Format: String, CaseIterable, Sendable {
        case aac = "AAC"
        case opus = "Opus"
        case mp3 = "MP3"

        var fileExtension: String {
            self == .aac ? "m4a" : rawValue.lowercased()
        }
    }

    enum BitRate: Int, CaseIterable, Sendable {
        case kbps96 = 96
        case kbps48 = 48
        case kbps24 = 24
        case kbps16 = 16
    }

    enum Channels: Int, CaseIterable, Sendable {
        case mono = 1
        case stereo = 2

        var title: String {
            self == .mono ? "Mono" : "Estéreo"
        }
    }

    var format: Format = .aac
    var bitRate: BitRate = .kbps24
    var channels: Channels = .mono

    var bitsPerSecond: Int { bitRate.rawValue * 1_000 }
    var requiresFFmpeg: Bool { format != .aac || bitsPerSecond < 48_000 }

    var sampleRate: Int {
        if format == .opus { return 48_000 }
        switch bitRate {
        case .kbps96: return 48_000
        case .kbps48: return format == .aac ? 32_000 : 48_000
        case .kbps24: return 24_000
        case .kbps16: return 16_000
        }
    }
}
