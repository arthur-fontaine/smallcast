import SwiftUI

/// A file's preview over the list it was picked from. Inside the panel, because a system preview
/// window would take key and close the palette, and with it the search the reader came from.
struct FilePreviewOverlay: ViewModifier {
    /// The row under the selection, which the preview follows while it is open.
    let selected: FileSearchResult?
    let vm: PaletteState

    func body(content: Content) -> some View {
        content
            .overlay {
                if let file = vm.filePreview {
                    FilePreviewCard(result: file) { vm.filePreview = nil }
                }
            }
            // A selection that is no file closes it, so moving back up never reopens it unasked.
            .onChange(of: selected?.id) {
                if vm.filePreview != nil { vm.filePreview = selected.flatMap { $0.isDirectory ? nil : $0 } }
            }
    }
}

extension View {
    func filePreviewOverlay(selected: FileSearchResult?, vm: PaletteState) -> some View {
        modifier(FilePreviewOverlay(selected: selected, vm: vm))
    }
}

private struct FilePreviewCard: View {
    @Environment(\.metrics) private var metrics
    let result: FileSearchResult
    let onClose: () -> Void

    /// Concentric: every corner inside the panel is the one outside it less its own inset.
    private var cardRadius: CGFloat { metrics.radius.panel - metrics.spacing.md }
    private var surfaceRadius: CGFloat { cardRadius - metrics.spacing.md }

    var body: some View {
        ZStack {
            // Only the margin dismisses: a click over the preview belongs to its own transport.
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            card
        }
    }

    private var card: some View {
        VStack(spacing: metrics.spacing.md) {
            FileSearchSurface(url: result.url)
                .clipShape(RoundedRectangle(cornerRadius: surfaceRadius, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: metrics.spacing.sm) {
                Text(result.name)
                    .font(metrics.typography.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: metrics.spacing.lg)
                BarButton(action: onClose) {
                    HStack(spacing: metrics.spacing.sm) {
                        Text("Close")
                            .font(metrics.typography.bar)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        KeyCapChip(text: "esc", style: .outline)
                    }
                }
            }
        }
        .padding(metrics.spacing.md)
        .frosted(in: RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .padding(metrics.spacing.md)
        .id(result.id)
    }
}
