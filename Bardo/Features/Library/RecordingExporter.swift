import AppKit
import UniformTypeIdentifiers

/// Saves a copy of a recording's transcript or audio where the person chooses, with the
/// standard macOS save panel.
@MainActor
enum RecordingExporter {
    enum Outcome {
        case saved
        case cancelled
        case failed(String)
    }

    static func save(
        suggestedName: String,
        contentType: UTType,
        write: @escaping (URL) throws -> Void
    ) async -> Outcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(suggestedName, contentType: contentType)
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        guard await panel.begin() == .OK, let destination = panel.url else { return .cancelled }
        do {
            try write(destination)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Replaces whatever the person chose to overwrite with a copy of `source`.
    static func copy(_ source: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            try manager.removeItem(at: destination)
        }
        try manager.copyItem(at: source, to: destination)
    }

    /// A file name without characters macOS reserves, carrying the type's extension.
    private static func fileName(_ name: String, contentType: UTType) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Bardo" : cleaned
        guard let fileExtension = contentType.preferredFilenameExtension else { return base }
        return "\(base).\(fileExtension)"
    }
}
