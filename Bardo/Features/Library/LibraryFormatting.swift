import Foundation

/// Presentation-only formatting shared by the Library feature.
enum LibraryFormatting {
    static func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return "Unknown" }
        return self.duration(duration)
    }

    static func duration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func sampleRate(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    static func source(_ sources: Set<AudioSource>) -> String {
        guard !sources.isEmpty else { return "Unknown source" }
        return sources
            .sorted { $0.rawValue < $1.rawValue }
            .map { source in
                switch source {
                case .microphone: "Microphone"
                case .systemAudio: "System Audio"
                case .importedFile: "Imported File"
                }
            }
            .joined(separator: " + ")
    }

    static func sourceSymbol(_ sources: Set<AudioSource>) -> String {
        if sources == [.microphone] { return "mic.fill" }
        if sources == [.systemAudio] { return "macbook.and.iphone" }
        if sources == [.importedFile] { return "waveform" }
        if sources.contains(.systemAudio), sources.contains(.microphone) { return "person.wave.2.fill" }
        return "waveform"
    }

    static func state(_ state: ProcessingState) -> String {
        switch state {
        case .pending: "Ready"
        case .processing: "Processing"
        case .completed: "Transcribed"
        case .partial: "Partial Transcript"
        case .failed: "Needs Attention"
        }
    }

    static func stateSymbol(_ state: ProcessingState) -> String {
        switch state {
        case .pending: "circle"
        case .processing: "clock.arrow.circlepath"
        case .completed: "checkmark.circle.fill"
        case .partial: "exclamationmark.circle"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return "Auto-detected" }
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }
}
