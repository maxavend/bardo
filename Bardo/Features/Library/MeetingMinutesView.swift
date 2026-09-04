import AppKit
import SwiftUI

struct MeetingMinutesView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    var onSwitchToTranscript: (() -> Void)? = nil

    @State private var isRegenerateConfirmationPresented = false
    @State private var copyFeedback: String?
    @State private var cursorBlink = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BardoSpacing.group) {
                if let error = model.meetingMinutesErrorMessage {
                    errorBanner(error)
                }

                    if model.isGeneratingMeetingMinutes {
                        generationProgressBanner

                        if let streaming = model.streamingMeetingMinutesText, !streaming.isEmpty {
                            minutesContentCard(text: streaming, isStreaming: true)
                        } else {
                            preparingModelPlaceholder
                        }
                    } else if let minutes = model.meetingMinutes,
                              minutes.recordingID == recording.id {
                        if model.meetingMinutesIsStale {
                            staleMinutesBanner
                        }
                        minutesContentCard(text: minutes.text, isStreaming: false)
                    } else {
                        emptyStateView
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(.horizontal, BardoSpacing.detailHorizontal)
                .padding(.vertical, BardoSpacing.section)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollClipDisabled(false)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            if model.isGeneratingMeetingMinutes {
                cursorBlink.toggle()
            }
        }
        .confirmationDialog(
            String(localized: "Regenerate Meeting Minutes?"),
            isPresented: $isRegenerateConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Regenerate"), role: .destructive) {
                model.beginMeetingMinutes()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This replaces the current minutes with a new local generation from the edited transcript."))
        }
        .enableInjection()
    }

    private var generationProgressBanner: some View {
        let snapshot = model.meetingMinutesProgressSnapshot
        let message = snapshot?.message ?? String(localized: "Generating meeting minutes…")
        let fraction = model.meetingMinutesProgress ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(message)
                    .font(.headline)
                Spacer()
                if let streaming = model.streamingMeetingMinutesText, !streaming.isEmpty {
                    Text(String.localizedStringWithFormat(String(localized: "%lld characters"), streaming.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    model.cancelMeetingMinutes()
                }
                .controlSize(.small)
            }

            ProgressView(value: fraction)

            HStack {
                Text(String(localized: "Processing locally on your Mac."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var preparingModelPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text(String(localized: "Preparing the conversation analysis…"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(.fill.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func minutesContentCard(text: String, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            BardoMarkdownView(text: text, isStreaming: isStreaming, cursorVisible: cursorBlink)

            if !isStreaming {
                Divider()

                HStack(spacing: 10) {
                    Text(String(localized: "Generated on-device from transcript"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if let copyFeedback {
                        Label(copyFeedback, systemImage: "checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        copyMinutes(text)
                    } label: {
                        Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(20)
        .background(.fill.tertiary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary.opacity(0.8))

            VStack(spacing: 5) {
                Text(String(localized: "Meeting Minutes"))
                    .font(.system(size: 15, weight: .semibold))
                Text(String(localized: "Create a detailed, structured record of the conversation's topics, decisions, pending work, and next steps."))
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            if model.canGenerateMeetingMinutes {
                Button(String(localized: "Generate Minutes")) {
                    model.beginMeetingMinutes()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else {
                VStack(spacing: 6) {
                    Text(String(localized: "A completed transcript is required before generating meeting minutes."))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.tertiary)

                    if let onSwitchToTranscript {
                        Button(String(localized: "Go to Transcript")) {
                            onSwitchToTranscript()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 12, weight: .medium))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
        .padding(.vertical, 32)
        .padding(.horizontal, 24)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
            Spacer()
            Button(String(localized: "Retry")) { model.beginMeetingMinutes() }
                .buttonStyle(.link)
            Button(String(localized: "Dismiss")) { model.clearMeetingMinutesError() }
                .buttonStyle(.link)
        }
        .padding(12)
        .background(.fill.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var staleMinutesBanner: some View {
        Label(
            String(localized: "The transcript changed after these minutes were generated. Regenerate to update them."),
            systemImage: "arrow.triangle.2.circlepath"
        )
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copyMinutes(_ text: String) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { return }
        copyFeedback = String(localized: "Copied")
    }
}

// MARK: - Markdown Viewer

struct BardoMarkdownView: View {
    let text: String
    var isStreaming: Bool = false
    var cursorVisible: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let lines = text.components(separatedBy: "\n")
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isLastLine = index == lines.count - 1

                if trimmed.hasPrefix("# ") {
                    let content = String(trimmed.dropFirst(2))
                    Text(.init(content))
                        .font(.title2.weight(.bold))
                        .textSelection(.enabled)
                        .padding(.top, index == 0 ? 0 : 8)
                } else if trimmed.hasPrefix("## ") {
                    let content = String(trimmed.dropFirst(3))
                    Text(.init(content))
                        .font(.title3.weight(.bold))
                        .textSelection(.enabled)
                        .padding(.top, 8)
                } else if trimmed.hasPrefix("### ") {
                    let content = String(trimmed.dropFirst(4))
                    Text(.init(content))
                        .font(.headline)
                        .textSelection(.enabled)
                        .padding(.top, 4)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    let content = String(trimmed.dropFirst(2))
                    HStack(alignment: .top, spacing: 8) {
                        Text("•")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(.init(content))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                    }
                    .padding(.leading, 4)
                } else if trimmed.isEmpty {
                    Spacer().frame(height: 2)
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        Text(.init(trimmed))
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)

                        if isStreaming && isLastLine && cursorVisible {
                            Text("▌")
                                .font(.body.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if isStreaming && lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true && cursorVisible {
                Text("▌")
                    .font(.body.weight(.bold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detached Floating Window

@MainActor
final class DetachedMinutesWindowManager {
    @MainActor static let shared = DetachedMinutesWindowManager()
    private var window: NSWindow?

    @MainActor
    func show(minutesText: String, title: String) {
        if let window {
            window.title = String.localizedStringWithFormat(String(localized: "Meeting Minutes: %@"), title)
            window.contentView = NSHostingView(rootView: DetachedMinutesContentView(title: title, text: minutesText))
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: 680, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = String.localizedStringWithFormat(String(localized: "Meeting Minutes: %@"), title)
        win.isReleasedWhenClosed = false
        win.center()
        win.contentView = NSHostingView(rootView: DetachedMinutesContentView(title: title, text: minutesText))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = win
    }
}

private struct DetachedMinutesContentView: View {
    let title: String
    let text: String
    @State private var copyFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label(String(localized: "Meeting Minutes"), systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                if let copyFeedback {
                    Label(copyFeedback, systemImage: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text, forType: .string) {
                        copyFeedback = String(localized: "Copied")
                    }
                } label: {
                    Label(String(localized: "Copy"), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding()

            Divider()

            ScrollView {
                BardoMarkdownView(text: text, isStreaming: false)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}
