import SwiftUI

/// Settings › Search: what the ranking has learned from you, and how to forget it. The list is the
/// frecency order itself — the same `UsageScore` the launcher sorts by — so it doubles as an
/// explanation of why a result sits where it does.
struct SearchSettingsView: View {
    @EnvironmentObject private var appIndex: AppIndex
    @ObservedObject private var usage = AppCore.shared.usage

    @State private var range: UsageResetRange = .today
    @State private var confirmingReset = false

    /// Records resolved back to entries, most relevant first. A key with nothing behind it any more
    /// (uninstalled app, disabled feature) can't rank anything, so it isn't shown.
    private var ranked: [RankedUsage] {
        let now = Date()
        let byKey = Dictionary(
            appIndex.apps.map { ($0.usageKey, $0) }, uniquingKeysWith: { first, _ in first })
        return
            usage.records
            .compactMap { key, record -> RankedUsage? in
                guard let entry = byKey[key] else { return nil }
                return RankedUsage(
                    entry: entry, record: record, score: UsageScore.score(record, now: now))
            }
            .sorted {
                $0.score != $1.score
                    ? $0.score > $1.score
                    : $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
            }
    }

    var body: some View {
        let ranked = ranked
        let today = Calendar.current.startOfDay(for: Date())
        let todayCount = ranked.reduce(0) { $0 + $1.record.launches(since: today) }

        SettingsPane(
            title: "Search",
            subtitle: "What the launcher has learned from you, and how to forget it."
        ) {
            SettingsCard(header: "Learned usage") {
                SettingsRow(
                    title: "Reset learned usage",
                    subtitle: resetSubtitle(entries: ranked.count, today: todayCount),
                    systemImage: "arrow.counterclockwise",
                    tint: .orange
                ) {
                    Picker("", selection: $range) {
                        ForEach(UsageResetRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Reset…") { confirmingReset = true }
                        .controlSize(.small)
                        .disabled(usage.records.isEmpty)
                }
            }

            SettingsCard(header: "Most used") {
                if ranked.isEmpty {
                    SettingsRow(
                        title: "Nothing learned yet",
                        subtitle:
                            "Launch a few things and they'll rank themselves here — recent use counts for more than old use.",
                        systemImage: "chart.bar",
                        tint: .gray
                    ) {}
                } else {
                    UsageTable(rows: ranked, best: ranked.first?.score ?? 1) { entry in
                        usage.forget(key: entry.usageKey)
                        appIndex.invalidateMatches()
                    }
                }
            }
        }
        .alert("Reset learned usage?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                usage.reset(range)
                appIndex.invalidateMatches()
            }
        } message: {
            Text(alertMessage)
        }
    }

    private func resetSubtitle(entries: Int, today: Int) -> String {
        guard entries > 0 else { return "Nothing has been learned yet." }
        let items = entries == 1 ? "1 item" : "\(entries) items"
        let launches = today == 1 ? "1 launch" : "\(today) launches"
        return "Ranking \(items), \(launches) of them today."
    }

    private var alertMessage: String {
        switch range {
        case .everything:
            return "Every launch Smallcast remembers is forgotten. Favorites and shortcuts are untouched."
        default:
            return
                "Launches from \(range.title.lowercased()) are forgotten; anything older keeps counting. Favorites and shortcuts are untouched."
        }
    }
}

/// One row of the table: the entry, its record, and the score the launcher would give it right now.
private struct RankedUsage: Identifiable {
    let entry: AppEntry
    let record: UsageRecord
    let score: Int
    var id: String { entry.id }
}

/// The frecency table: a bar per row makes the ranking legible at a glance, which a bare number can't.
private struct UsageTable: View {
    let rows: [RankedUsage]
    let best: Int
    let onForget: (AppEntry) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(rows) { row in
                    UsageRow(row: row, best: best, onForget: { onForget(row.entry) })
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.sm)
            .overlayScroller()
        }
        .frame(minHeight: 220)
    }
}

private struct UsageRow: View {
    let row: RankedUsage
    let best: Int
    let onForget: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(nsImage: row.entry.icon)
                .resizable()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.entry.name).lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.lg)
            ScoreBar(fraction: best > 0 ? Double(row.score) / Double(best) : 0)
                .help("Frecency score \(row.score)")
            Button(action: onForget) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Forget \(row.entry.name)")
            // Reserve the slot so rows don't shift as the pointer moves down the list.
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(hovered ? Theme.Colors.rowHover : .clear)
        )
        .onHover { hovered = $0 }
    }

    private var detail: String {
        let launches = row.record.count == 1 ? "1 launch" : "\(row.record.count) launches"
        let relative = row.record.lastUsed.formatted(.relative(presentation: .numeric))
        return "\(row.entry.kindLabel) · \(launches) · \(relative)"
    }
}

private struct ScoreBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Theme.Colors.controlSurface)
            .frame(width: 90, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.accentColor.opacity(0.7))
                    // Never fully empty: a row that's in the table did get used at least once.
                    .frame(width: max(4, 90 * min(max(fraction, 0), 1)), height: 6)
            }
    }
}
