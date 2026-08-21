import SwiftUI

/// Renders a reply. `AttributedString` handles inline styling; block layout comes from
/// `AIMarkdownBlock`. AI owns this rather than sharing the extension host's renderer: that one is
/// tuned for untrusted third-party content and must stay free to change without this following it.
struct AIMarkdownView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(AIMarkdownBlock.parse(markdown)) { block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text))
                        .font(.system(size: Self.headingSize(level), weight: .semibold))
                        .padding(.top, Theme.Spacing.xs)
                case .paragraph(let text):
                    Text(inline(text))
                        .font(Theme.Typography.rowTitle)
                        .textSelection(.enabled)
                case .bullet(let text):
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text)).font(Theme.Typography.rowTitle)
                    }
                case .numbered(let index, let text):
                    HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                        Text("\(index).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(text)).font(Theme.Typography.rowTitle)
                    }
                case .quote(let text):
                    HStack(spacing: Theme.Spacing.sm) {
                        Rectangle().fill(Theme.Colors.separator).frame(width: 2)
                        Text(inline(text))
                            .font(Theme.Typography.rowTitle)
                            .foregroundStyle(.secondary)
                    }
                case .code(let language, let text):
                    AICodeBlock(language: language, code: text)
                case .rule:
                    Rectangle().fill(Theme.Colors.separator).frame(height: 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 20
        case 2: return 17
        case 3: return 15
        default: return 14
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A fenced block, with the copy button Raycast puts there — the thing most often wanted from a
/// reply is the code in it, and selecting it by hand inside a floating panel is fiddly.
private struct AICodeBlock: View {
    let language: String
    let code: String

    @Environment(AppCore.self) private var core
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        return ScrollView(.horizontal) {
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(Theme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Theme.Colors.cardFill))
        .overlay(shape.strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
        .overlay(alignment: .topTrailing) { header }
        .hideNativeScrollers()
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if !language.isEmpty {
                Text(language)
                    .font(Theme.Typography.keyCap)
                    .foregroundStyle(.tertiary)
            }
            Button {
                Paster.copyPlainText(code)
                core.showMessage("Copied code")
            } label: {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy code")
        }
        .padding(Theme.Spacing.sm)
        .opacity(hovered ? 1 : 0)
    }
}
