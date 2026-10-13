import SwiftUI

/// A list's header that says DigUp is still reading, once a search has run long enough to notice.
struct ContentSearchHeader: View {
    @Environment(\.metrics) private var metrics
    let title: String
    var isFirst = false
    let isSearching: Bool
    /// With no rows under it yet, the header waits too, so a quick search never flashes it.
    var waitsToAppear = false
    @State private var noticed = false

    var body: some View {
        SectionHeader(title: title, isFirst: isFirst)
            .overlay(alignment: .bottomTrailing) {
                if isSearching, noticed {
                    HStack(spacing: metrics.spacing.xs) {
                        ProgressView().controlSize(.mini)
                        Text("Searching contents")
                    }
                    .font(metrics.typography.sectionHeader)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, metrics.spacing.md)
                    .padding(.bottom, metrics.spacing.sectionHeaderBottom)
                    .transition(.opacity)
                }
            }
            .opacity(waitsToAppear && !noticed ? 0 : 1)
            .task(id: isSearching) {
                noticed = false
                guard isSearching else { return }
                try? await Task.sleep(for: DigUpSearchPolicy.progressDelay)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.15)) { noticed = true }
            }
            .accessibilityValue(isSearching ? "Searching contents" : "")
    }
}

/// The empty screen while only DigUp is left to answer: no name matched, its contents may.
struct ContentSearchPlaceholder: View {
    @State private var noticed = false

    var body: some View {
        Group {
            if noticed {
                EmptyResults(
                    text: "Searching inside your files…",
                    detail: "No name matches. DigUp is reading what files say and show.",
                    systemImage: "sparkle.magnifyingglass")
                .transition(.opacity)
            } else {
                Color.clear
            }
        }
        .task {
            try? await Task.sleep(for: DigUpSearchPolicy.progressDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { noticed = true }
        }
    }
}

/// The passage DigUp matched: why a file named nothing like the query is in the list.
struct DigUpMatchSection: View {
    @Environment(\.metrics) private var metrics
    let excerpt: String

    private var text: AttributedString {
        DigUpSearchPolicy.excerptRuns(excerpt).reduce(into: AttributedString()) { text, run in
            var part = AttributedString(run.text)
            if run.matched {
                part.foregroundColor = Theme.Colors.textPrimary
                part.inlinePresentationIntent = .stronglyEmphasized
            }
            text += part
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text("Why It Matched")
                .font(metrics.typography.sectionHeader)
                .foregroundStyle(.secondary)
            Text(text)
                .font(metrics.typography.keyCap)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, metrics.spacing.md)
    }
}
