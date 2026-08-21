import SwiftUI

/// The live conversation. The search field is the composer here, not a filter: ↵ sends what is in
/// it, the way the quicklink argument screen submits rather than activating a row.
struct AIChatScreen: PaletteScreen {
    let session: AIChatSession
    let conversations: AIConversationStore
    let core: AppCore
    let vm: PaletteState
    let openActions: () -> Void

    var rows: [AIMessage] { session.messages }

    private var typed: String { vm.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The turn a ⌘K row acts on: the highlighted one, else the newest answer.
    private var target: AIMessage? {
        if rows.indices.contains(vm.selection) { return rows[vm.selection] }
        return rows.last
    }

    var primaryActionTitle: String {
        if !typed.isEmpty { return "Send" }
        if session.isStreaming { return "Stop" }
        return "Copy Answer"
    }

    /// The composer always has something to do, so the pill never goes away on an empty chat.
    func hasPrimaryAction(at selection: Int) -> Bool { true }

    func actions(at selection: Int) -> PopoverMenuContent? {
        AIActionsMenu.content(message: target, session: session, core: core)
    }

    func activate(at selection: Int) {
        if !typed.isEmpty {
            core.aiCoordinator.send(vm.query)
            return
        }
        if session.isStreaming {
            core.aiCoordinator.stop()
            return
        }
        guard let target, target.role == .assistant else { return }
        core.aiCoordinator.copyAnswer(target)
    }

    /// ⌘↵ — nothing here: the composer's ↵ is the whole interaction.
    func secondary(at selection: Int) -> Bool { false }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(content(selection: selection, scroll: scroll))
    }

    @ViewBuilder
    private func content(selection: Int, scroll: ScrollIntent) -> some View {
        if rows.isEmpty {
            AIChatEmptyState(isConfigured: core.aiCoordinator.config != nil)
        } else {
            AIChatView(
                messages: rows,
                isStreaming: session.isStreaming,
                isThinking: session.isThinking,
                selectedID: rows.indices.contains(selection) ? rows[selection].id : nil,
                scroll: scroll,
                onSelect: { message in
                    if let index = rows.firstIndex(of: message) { vm.selection = index }
                },
                onActions: { message in
                    if let index = rows.firstIndex(of: message) { vm.selection = index }
                    openActions()
                }
            )
        }
    }
}

/// A chat with nothing in it yet. It says what is missing when nothing is configured, because an
/// unconfigured provider only ever fails at the moment a question is asked otherwise.
private struct AIChatEmptyState: View {
    let isConfigured: Bool

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tertiary)
            Text(isConfigured ? "Ask anything" : "Choose a provider in Settings › AI")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The ⌘K rows for a conversation, shown bottom-right like every other mode's.
@MainActor
enum AIActionsMenu {
    static func content(
        message: AIMessage?, session: AIChatSession, core: AppCore
    ) -> PopoverMenuContent {
        var items: [PopoverMenuItem] = []
        if session.isStreaming {
            items.append(
                PopoverMenuItem(title: "Stop", systemImage: "stop.circle", shortcut: "↵") {
                    core.aiCoordinator.stop()
                })
        }
        if let message, message.role == .assistant, !message.isEmpty {
            items.append(
                PopoverMenuItem(title: "Copy Answer", systemImage: "doc.on.doc", shortcut: "↵") {
                    core.aiCoordinator.copyAnswer(message)
                })
        }
        if session.canRegenerate {
            items.append(
                PopoverMenuItem(
                    title: "Regenerate Answer", systemImage: "arrow.clockwise", shortcut: "⌘R"
                ) {
                    core.aiCoordinator.regenerate()
                })
        }
        items.append(
            PopoverMenuItem(title: "New Chat", systemImage: "plus.bubble", shortcut: "⌘N") {
                core.aiCoordinator.newChat()
            })
        items.append(
            PopoverMenuItem(
                title: CommandID.searchAIChats.name,
                systemImage: CommandID.searchAIChats.sfSymbol
            ) {
                core.aiCoordinator.showChats()
            })
        return PopoverMenuContent(header: session.conversation?.title, items: items)
    }
}
