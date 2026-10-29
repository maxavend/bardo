import Foundation

// Just enough of the macOS app for its persistence types to compile on their own.
enum LibraryFormatting {
    static func duration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds) }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

enum TranscriptionModelManager {
    static let modelID = "large-v3-v20240930_turbo_632MB"
    static let largeModelID = "large-v3"
}

enum TranscriptionEngine: String {
    case apple
}
