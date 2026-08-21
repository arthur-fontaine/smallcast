import SwiftUI

/// Saved chats under the same coarse date buckets the clipboard and calculator histories use.
struct AIChatList: View {
    let chats: [AIConversation]
    let selectedID: AIConversation.ID?
    let scroll: ScrollIntent
    let onActivate: (AIConversation) -> Void
    let onActions: (AIConversation) -> Void

    private enum Row: Identifiable {
        case header(String)
        case chat(AIConversation)

        var id: String {
            switch self {
            case .header(let title): return "header-" + title
            case .chat(let chat): return chat.id.uuidString
            }
        }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        var bucket: DateBucket?
        for chat in chats {
            let next = DateBucket(for: chat.updatedAt)
            if next != bucket {
                rows.append(.header(next.title))
                bucket = next
            }
            rows.append(.chat(chat))
        }
        return rows
    }

    private var firstRowSelected: Bool { selectedID != nil && selectedID == chats.first?.id }

    var body: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        switch row {
                        case .header(let title):
                            SectionHeader(title: title, isFirst: row.id == rows.first?.id)
                        case .chat(let chat):
                            AIChatRow(chat: chat, selected: chat.id == selectedID)
                                .contentShape(Rectangle())
                                .onTapGesture { onActivate(chat) }
                                .onRightClick { onActions(chat) }
                                .selectionFrame(chat.id == selectedID)
                        }
                    }
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.top, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.md)
                .hideNativeScrollers()
                .scrollOriginAnchor()
            }
            .edgeDissolve()
            .thinScrollbar()
            .scrollFollowsSelection(
                scroll, row: selectedID?.uuidString, atOrigin: firstRowSelected, proxy: proxy)
        }
    }
}

private struct AIChatRow: View {
    let chat: AIConversation
    let selected: Bool

    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "bubble.left")
                .frame(width: Theme.Size.rowIcon)
                .foregroundStyle(.secondary)
            Text(chat.title)
                .font(Theme.Typography.rowTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Text(chat.messages.count == 1 ? "1 message" : "\(chat.messages.count) messages")
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(fill)
        )
        .armedHover($hovered)
    }
}
