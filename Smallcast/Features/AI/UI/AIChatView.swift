import SwiftUI

/// The transcript. Streams into the last row, and stays pinned to the bottom while it does — a
/// reply that scrolls itself out of view is the one thing a chat must never do.
struct AIChatView: View {
    let messages: [AIMessage]
    let isStreaming: Bool
    /// A reasoning model has produced only private thinking so far; the row says so.
    let isThinking: Bool
    let selectedID: AIMessage.ID?
    let scroll: ScrollIntent
    let onSelect: (AIMessage) -> Void
    let onActions: (AIMessage) -> Void

    private static let bottomAnchor = "ai-transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(messages) { message in
                        AIMessageRow(
                            message: message,
                            selected: message.id == selectedID,
                            isAwaiting: isStreaming && message.id == messages.last?.id,
                            isThinking: isThinking
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { onSelect(message) }
                        .onRightClick { onActions(message) }
                        .id(message.id.uuidString)
                    }
                    Color.clear.frame(height: 1).id(Self.bottomAnchor)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID?.uuidString, atOrigin: selectedID == messages.first?.id,
                proxy: proxy)
            // The streamed tail, not the selection: text arriving is what moves the view.
            .onChange(of: messages.last?.text) { pinToBottom(proxy) }
            .onChange(of: messages.count) { pinToBottom(proxy) }
            .onAppear { pinToBottom(proxy) }
        }
    }

    private func pinToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
    }
}

private struct AIMessageRow: View {
    let message: AIMessage
    let selected: Bool
    /// The answer being waited on: nothing has arrived yet, so the row shows that rather than a gap.
    let isAwaiting: Bool
    let isThinking: Bool

    @State private var hovered = false

    private var isUser: Bool { message.role == .user }

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: isUser ? "person.crop.circle" : "sparkles")
                    .foregroundStyle(.secondary)
                Text(isUser ? "You" : "Assistant")
                    .font(Theme.Typography.sectionHeader)
                    .foregroundStyle(.secondary)
            }
            if isUser {
                Text(message.text)
                    .font(Theme.Typography.rowTitle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let failure = message.failure {
                AIFailureNote(text: failure)
            } else if message.isEmpty && isAwaiting {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    // A local reasoning model can think for a minute; a bare spinner reads as a hang.
                    if isThinking {
                        Text("Thinking…")
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                AIMarkdownView(markdown: message.text)
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
    }
}

/// A failed turn, reported where the answer would have been. See docs/features/ai.md.
private struct AIFailureNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(Theme.Typography.rowTitle)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
