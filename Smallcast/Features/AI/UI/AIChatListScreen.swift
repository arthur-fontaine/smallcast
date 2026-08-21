import SwiftUI

/// Saved conversations, newest first. Its own mode rather than a section of the launcher: a chat is
/// a document, not an entry, and it carries no shortcut, favorite or visibility of its own.
struct AIChatListScreen: PaletteScreen {
    let conversations: AIConversationStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [AIConversation] {
        let query = vm.query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return conversations.conversations }
        return conversations.conversations.filter { chat in
            chat.messages.contains { $0.text.localizedCaseInsensitiveContains(query) }
        }
    }

    var primaryActionTitle: String { "Open Chat" }

    private func chat(at selection: Int) -> AIConversation? {
        let rows = rows
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard let chat = chat(at: selection) else { return nil }
        return PopoverMenuContent(
            header: chat.title,
            items: [
                PopoverMenuItem(title: "Open Chat", systemImage: "bubble.left", shortcut: "↵") {
                    core.aiCoordinator.open(chat)
                },
                PopoverMenuItem(
                    title: "Delete Chat", systemImage: "trash", shortcut: "⌃X", isDestructive: true
                ) {
                    core.aiCoordinator.delete(chat)
                },
                PopoverMenuItem(
                    title: "Delete All Chats", systemImage: "trash", shortcut: "⌃⇧X",
                    isDestructive: true
                ) {
                    Task { await core.aiCoordinator.deleteAllChats() }
                }
            ])
    }

    func activate(at selection: Int) {
        guard let chat = chat(at: selection) else { return }
        core.aiCoordinator.open(chat)
    }

    /// ⌘⌫ / ⌃X — the screen owns the chord, the same way the clipboard and calculator lists do.
    func delete(at selection: Int) {
        guard let chat = chat(at: selection) else { return }
        core.aiCoordinator.delete(chat)
    }

    /// ⌃⇧X — mirrors the Actions row, confirmation included.
    func deleteAll() {
        Task { await core.aiCoordinator.deleteAllChats() }
    }

    /// ⌘↵ — a chat has one destination, so there is no second thing to do with it.
    func secondary(at selection: Int) -> Bool { false }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        let rows = rows
        if rows.isEmpty {
            EmptyResults(
                text: vm.query.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "No chats yet" : "No matching chats")
        } else {
            AIChatList(
                chats: rows,
                selectedID: chat(at: selection)?.id,
                scroll: scroll,
                onActivate: { core.aiCoordinator.open($0) },
                onActions: { chat in
                    if let index = rows.firstIndex(of: chat) { vm.selection = index }
                    openActions()
                }
            )
        }
    }
}
