import AppKit
import SwiftUI

struct MeetingMinutesView: View {
    @ObserveInjection var redraw
    let recording: Recording
    @ObservedObject var model: LibraryViewModel
    var bottomContentInset: CGFloat = 0
    var onSwitchToTranscript: (() -> Void)? = nil

    @State private var isRegenerateConfirmationPresented = false
    @State private var copyFeedback: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: BardoSpacing.section) {
                if let error = model.meetingMinutesErrorMessage {
                    errorView(error)
                }

                if model.isGeneratingMeetingMinutes {
                    generationProgressView

                    if let streaming = model.streamingMeetingMinutesText, !streaming.isEmpty {
                        minutesDocument(text: streaming, isStreaming: true)
                    } else {
                        preparingModelPlaceholder
                    }
                } else if let minutes = model.meetingMinutes,
                          minutes.recordingID == recording.id {
                    if model.meetingMinutesIsStale {
                        staleMinutesView
                    }

                    minutesDocument(text: minutes.text, isStreaming: false)
                } else {
                    emptyStateView
                }
            }
            .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
            .padding(.horizontal, BardoSpacing.detailHorizontal)
            .padding(.top, BardoSpacing.detailBodyTop)
            .padding(.bottom, BardoSpacing.section + bottomContentInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var generationProgressView: some View {
        let snapshot = model.meetingMinutesProgressSnapshot
        let message = snapshot?.message ?? String(localized: "Generating meeting minutes…")
        let fraction = model.meetingMinutesProgress ?? 0

        return GroupBox {
            VStack(alignment: .leading, spacing: BardoSpacing.compact) {
                ProgressView(value: fraction)

                HStack(alignment: .firstTextBaseline, spacing: BardoSpacing.compact) {
                    Text(String(localized: "Processing locally on your Mac."))
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 12)

                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button(String(localized: "Cancel"), role: .cancel) {
                        model.cancelMeetingMinutes()
                    }
                }
            }
        } label: {
            HStack {
                Label {
                    Text(message)
                } icon: {
                    ProgressView()
                        .controlSize(.small)
                }

                if let streaming = model.streamingMeetingMinutesText, !streaming.isEmpty {
                    Spacer()
                    Text(String.localizedStringWithFormat(String(localized: "%lld characters"), streaming.count))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var preparingModelPlaceholder: some View {
        ContentUnavailableView {
            Label(String(localized: "Preparing Meeting Minutes"), systemImage: "list.bullet.clipboard")
        } description: {
            Text(String(localized: "Preparing the conversation analysis locally on this Mac."))
        } actions: {
            ProgressView()
        }
        .frame(maxWidth: .infinity, minHeight: BardoLayout.inlineUnavailableMinHeight)
    }

    private func minutesDocument(text: String, isStreaming: Bool) -> some View {
        VStack(alignment: .leading, spacing: BardoSpacing.section) {
            BardoMarkdownView(
                text: text,
                isStreaming: isStreaming,
                cursorVisible: isStreaming
            )

            if !isStreaming {
                Divider()

                HStack(spacing: BardoSpacing.compact) {
                    Label(
                        String(localized: "Generated on-device from transcript"),
                        systemImage: "lock.shield"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                    Button {
                        isRegenerateConfirmationPresented = true
                    } label: {
                        Label(String(localized: "Regenerate"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!model.canGenerateMeetingMinutes)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var emptyStateView: some View {
        BardoEmptyState(
            systemImage: "list.bullet.clipboard",
            title: String(localized: "Meeting Minutes"),
            detail: model.canGenerateMeetingMinutes
                ? String(localized: "Create a structured record of topics, decisions, pending work, and next steps from the transcript.")
                : String(localized: "Complete the transcript before generating meeting minutes."),
            footnote: model.canGenerateMeetingMinutes
                ? String(localized: "Generated locally on this Mac")
                : nil
        ) {
            if model.canGenerateMeetingMinutes {
                Button(String(localized: "Generate Minutes")) {
                    model.beginMeetingMinutes()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            } else if let onSwitchToTranscript {
                Button(String(localized: "Go to Transcript")) {
                    onSwitchToTranscript()
                }
                .controlSize(.regular)
            }
        }
    }

    private func errorView(_ message: String) -> some View {
        GroupBox {
            HStack(alignment: .firstTextBaseline, spacing: BardoSpacing.compact) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 12)

                Button(String(localized: "Retry")) {
                    model.beginMeetingMinutes()
                }

                Button(String(localized: "Dismiss")) {
                    model.clearMeetingMinutesError()
                }
            }
        } label: {
            Label(String(localized: "Meeting Minutes Need Attention"), systemImage: "exclamationmark.triangle")
        }
    }

    private var staleMinutesView: some View {
        HStack(alignment: .firstTextBaseline, spacing: BardoSpacing.compact) {
            Label(
                String(localized: "The transcript changed after these minutes were generated."),
                systemImage: "arrow.triangle.2.circlepath"
            )
            .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Button(String(localized: "Regenerate")) {
                isRegenerateConfirmationPresented = true
            }
        }
        .font(.callout)
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
        VStack(alignment: .leading, spacing: BardoSpacing.compact) {
            let lines = text.components(separatedBy: "\n")

            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isLastLine = index == lines.count - 1

                if trimmed.hasPrefix("# ") {
                    Text(.init(String(trimmed.dropFirst(2))))
                        .font(.title2.weight(.semibold))
                        .padding(.top, index == 0 ? 0 : BardoSpacing.compact)
                } else if trimmed.hasPrefix("## ") {
                    Text(.init(String(trimmed.dropFirst(3))))
                        .font(.title3.weight(.semibold))
                        .padding(.top, BardoSpacing.compact)
                } else if trimmed.hasPrefix("### ") {
                    Text(.init(String(trimmed.dropFirst(4))))
                        .font(.headline)
                        .padding(.top, BardoSpacing.small)
                } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    HStack(alignment: .top, spacing: BardoSpacing.small) {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(.init(String(trimmed.dropFirst(2))))
                            .font(.body)
                            .lineSpacing(3)
                    }
                } else if trimmed.isEmpty {
                    Spacer()
                        .frame(height: 2)
                } else {
                    HStack(alignment: .bottom, spacing: BardoSpacing.micro) {
                        Text(.init(trimmed))
                            .font(.body)
                            .lineSpacing(3)

                        if isStreaming && isLastLine && cursorVisible {
                            Text("▌")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if isStreaming,
               lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true,
               cursorVisible {
                Text("▌")
                    .font(.body.weight(.semibold))
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
            window.contentView = NSHostingView(
                rootView: DetachedMinutesContentView(title: title, text: minutesText)
            )
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
        win.contentView = NSHostingView(
            rootView: DetachedMinutesContentView(title: title, text: minutesText)
        )
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
            HStack(spacing: BardoSpacing.compact) {
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
            }
            .padding(BardoSpacing.standard)

            Divider()

            ScrollView {
                BardoMarkdownView(text: text, isStreaming: false)
                    .padding(BardoSpacing.large)
                    .frame(maxWidth: BardoLayout.detailContentMaxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}