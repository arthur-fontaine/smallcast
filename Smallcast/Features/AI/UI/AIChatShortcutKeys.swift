import SwiftUI

/// ⌘R / ⌘N inside the chat, mirroring its own Actions rows. Its own modifier because
/// `RootPaletteView.body` is long enough that one more inline `onKeyPress` stops type-checking.
struct AIChatShortcutKeys: ViewModifier {
    let isChat: Bool
    let onRegenerate: () -> Void
    let onNewChat: () -> Void
    let onHandled: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(keys: ["r", "R", "n", "N"], phases: .down) { press in
            guard isChat, press.modifiers.contains(.command) else { return .ignored }
            if press.key.character.lowercased() == "n" { onNewChat() } else { onRegenerate() }
            onHandled()
            return .handled
        }
    }
}
