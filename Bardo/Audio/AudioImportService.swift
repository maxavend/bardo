import AVFAudio
import Foundation

struct AudioMetadataReader: Sendable {
    func read(from url: URL) throws -> AudioMetadata {
        do {
            let file = try AVAudioFile(forReading: url)
            let processingFormat = file.processingFormat
            let fileFormat = file.fileFormat
            let sampleRate = processingFormat.sampleRate
            let channelCount = processingFormat.channelCount
            let duration = sampleRate > 0 ? Double(file.length) / sampleRate : 0

            guard duration.isFinite,
                  duration > 0,
                  sampleRate.isFinite,
                  sampleRate > 0,
                  channelCount > 0 else {
                throw AudioImportError.invalidAudio("The file does not contain a readable audio stream.")
            }

            let formatID = (fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value

            return AudioMetadata(
                duration: duration,
                codec: codecName(formatID: formatID),
                sampleRate: sampleRate,
                channelCount: channelCount
            )
        } catch let error as AudioImportError {
            throw error
        } catch {
            throw AudioImportError.invalidAudio(error.localizedDescription)
        }
    }

    private func codecName(formatID: UInt32?) -> String {
        guard let formatID else { return "Unknown" }
        let bytes: [UInt8] = [
            UInt8((formatID >> 24) & 0xff),
            UInt8((formatID >> 16) & 0xff),
            UInt8((formatID >> 8) & 0xff),
            UInt8(formatID & 0xff)
        ]
        let fourCC = String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        switch fourCC.lowercased() {
        case "lpcm": return "Linear PCM"
        case "aac": return "AAC"
        case ".mp3": return "MP3"
        case "flac": return "FLAC"
        case "alac": return "Apple Lossless"
        case "": return String(format: "0x%08X", formatID)
        default: return fourCC.uppercased()
        }
    }
}

actor AudioImportService {
    static let supportedFileExtensions: Set<String> = [
        "m4a", "mp3", "wav", "flac", "aac", "aiff"
    ]

    private let store: RecordingStore
    private let metadataReader: AudioMetadataReader

    init(store: RecordingStore, metadataReader: AudioMetadataReader = AudioMetadataReader()) {
        self.store = store
        self.metadataReader = metadataReader
    }

    func importFile(at sourceURL: URL) async throws -> Recording {
        guard sourceURL.isFileURL else {
            throw AudioImportError.notAFileURL
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.supportedFileExtensions.contains(fileExtension) else {
            throw AudioImportError.unsupportedFileExtension(fileExtension)
        }

        let accessedSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessedSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let metadata = try metadataReader.read(from: sourceURL)
        let asset = AudioAsset(
            originalFileName: sourceURL.lastPathComponent,
            fileExtension: fileExtension,
            metadata: metadata,
            role: .importedOriginal
        )
        let title = sourceURL.deletingPathExtension().lastPathComponent
        let recording = Recording(
            title: title.isEmpty ? "Imported audio" : title,
            duration: metadata.duration,
            sources: [.importedFile],
            processingState: .pending,
            audioAssets: [asset]
        )

        try await store.importRecording(recording, audioAsset: asset, from: sourceURL)
        return recording
    }
}

enum AudioImportError: Error, LocalizedError, Equatable, Sendable {
    case notAFileURL
    case unsupportedFileExtension(String)
    case invalidAudio(String)

    var errorDescription: String? {
        switch self {
        case .notAFileURL:
            return "Only local audio files can be imported."
        case .unsupportedFileExtension(let fileExtension):
            let displayed = fileExtension.isEmpty ? "unknown" : ".\(fileExtension)"
            return "\(displayed) is not a supported audio format."
        case .invalidAudio(let description):
            return "The selected file is not readable audio: \(description)"
        }
    }
}
