import AppKit
import Foundation
import SwiftUI

/// Presentation-only formatting shared by the Library feature.
enum LibraryFormatting {
    static func recordingTitle(_ recording: Recording) -> String {
        let title = recording.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, !isTechnicalRecordingTitle(title, id: recording.id) {
            return title
        }

        return String.localizedStringWithFormat(
            String(localized: "Recording from %@"),
            recording.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        )
    }

    static func duration(_ duration: TimeInterval?) -> String {
        guard let duration else { return String(localized: "Unknown") }
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

    /// The compact date Mail and Notes show in a list: the time for today, then
    /// "Yesterday", the weekday for the past week and a short date before that.
    static func listDate(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        // Whole calendar days between the two dates, measured against `now` rather than
        // the system clock.
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: date),
            to: calendar.startOfDay(for: now)
        ).day ?? .max
        switch days {
        case 0:
            return date.formatted(date: .omitted, time: .shortened)
        case 1:
            return String(localized: "Yesterday")
        case 2..<7:
            return date.formatted(.dateTime.weekday(.wide)).localizedCapitalized
        default:
            break
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func searchTerms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Marks every occurrence of the query's terms, ignoring case and accents.
    static func highlighted(
        _ text: String,
        matching query: String,
        style: SearchHighlightStyle
    ) -> AttributedString {
        var attributed = AttributedString(text)
        for term in searchTerms(query) {
            var searchStart = attributed.startIndex
            while searchStart < attributed.endIndex,
                  let range = attributed[searchStart..<attributed.endIndex]
                      .range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) {
                switch style {
                case .emphasis:
                    attributed[range].inlinePresentationIntent = .stronglyEmphasized
                case .findIndicator:
                    attributed[range].backgroundColor = Color(nsColor: .findHighlightColor)
                    attributed[range].foregroundColor = .black
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }

    static func containsSearchTerms(_ text: String, query: String) -> Bool {
        let terms = searchTerms(query)
        return !terms.isEmpty && terms.contains {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func processingDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration.rounded()))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60

        if hours > 0 {
            return remainingSeconds > 0
                ? "\(hours) h \(minutes) min \(remainingSeconds) s"
                : "\(hours) h \(minutes) min"
        }
        if minutes > 0 {
            return remainingSeconds > 0
                ? "\(minutes) min \(remainingSeconds) s"
                : "\(minutes) min"
        }
        return "\(seconds) s"
    }

    static func sampleRate(_ sampleRate: Double) -> String {
        if sampleRate >= 1_000 {
            return String(format: "%.1f kHz", sampleRate / 1_000)
        }
        return String(format: "%.0f Hz", sampleRate)
    }

    static func source(_ sources: Set<AudioSource>) -> String {
        guard !sources.isEmpty else { return String(localized: "Unknown source") }
        return sources
            .sorted { $0.rawValue < $1.rawValue }
            .map { source in
                switch source {
                case .microphone: String(localized: "Microphone")
                case .systemAudio: String(localized: "System Audio")
                case .importedFile: String(localized: "Imported File")
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
        case .pending: String(localized: "Ready")
        case .processing: String(localized: "Processing")
        case .completed: String(localized: "Transcribed")
        case .failed: String(localized: "Needs Attention")
        }
    }

    static func stateSymbol(_ state: ProcessingState) -> String {
        switch state {
        case .pending: "circle"
        case .processing: "clock.arrow.circlepath"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        }
    }

    static func language(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return String(localized: "Auto-detected") }
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    private static func isTechnicalRecordingTitle(_ title: String, id: UUID) -> Bool {
        let uuid = id.uuidString
        if title == uuid { return true }
        if title.localizedCaseInsensitiveContains(uuid) { return true }
        if title.localizedCaseInsensitiveContains("Recording ") && title.contains(uuid.prefix(8)) { return true }
        return false
    }
}

enum SearchHighlightStyle {
    /// Bold, for result lists where a coloured background would fight the selection.
    case emphasis
    /// The system find indicator, for matches inside a transcript.
    case findIndicator
}

enum RecordingSearch {
    static func matches(_ recording: Recording, query: String) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }

        let formattedTitle = LibraryFormatting.recordingTitle(recording)
        let rawTitle = recording.title
        let terms = normalizedQuery.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        return terms.allSatisfy { term in
            formattedTitle.localizedCaseInsensitiveContains(term) ||
            rawTitle.localizedCaseInsensitiveContains(term)
        }
    }
}
