import SwiftUI

/// Settings › Search: what the launcher has learned from you, and how to forget it. The list is the
/// learned order itself, so it doubles as an explanation of why a result sits where it does.
struct SearchSettingsView: View {
    @Environment(AppIndex.self) private var appIndex
    @Environment(LaunchHistoryStore.self) private var launchHistory
    @Environment(LauncherRankingStore.self) private var ranking

    @State private var range: UsageResetRange = .today
    @State private var confirmingReset = false

    /// One learned entry, resolved back to what it points at.
    private struct Learned: Identifiable {
        let entry: AppEntry
        let record: LaunchRecord
        /// The queries that led here, most-used first — what the ranking actually associated.
        let queries: [String]

        var id: String { entry.id }
    }

    /// Most recently used first. A key with nothing behind it any more — an uninstalled app, a
    /// command from a disabled feature — can't rank anything, so it isn't shown.
    private var learned: [Learned] {
        let byKey = Dictionary(
            appIndex.apps.map { ($0.preferenceKey, $0) }, uniquingKeysWith: { first, _ in first })
        var queriesByKey: [String: [(query: String, count: Int)]] = [:]
        for record in ranking.records {
            queriesByKey[record.itemKey, default: []].append((record.query, record.count))
        }
        return
            launchHistory.records
            .compactMap { key, record -> Learned? in
                guard let entry = byKey[key] else { return nil }
                // Only the longest spelling of each habit: every prefix of it is stored too.
                let queries =
                    (queriesByKey[key] ?? [])
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.query.count > $1.query.count }
                    .map(\.query)
                    .reduce(into: [String]()) { kept, query in
                        guard !kept.contains(where: { $0.hasPrefix(query) }) else { return }
                        kept.append(query)
                    }
                return Learned(entry: entry, record: record, queries: Array(queries.prefix(3)))
            }
            .sorted {
                $0.record.lastUsed != $1.record.lastUsed
                    ? $0.record.lastUsed > $1.record.lastUsed
                    : $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
            }
    }

    var body: some View {
        let learned = learned
        let peak = learned.map(\.record.count).max() ?? 1
        return Form {
            Section {
                SettingsRow(title: "Forget", subtitle: resetSubtitle(entries: learned.count)) {
                    Image(systemName: "arrow.counterclockwise")
                } trailing: {
                    Picker("", selection: $range) {
                        ForEach(UsageResetRange.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Reset…") { confirmingReset = true }
                        .disabled(launchHistory.isEmpty && ranking.isEmpty)
                }
            } header: {
                Text("Learned Ranking")
            } footer: {
                Text(
                    "The launcher learns which result you meant for what you typed, and how recently "
                        + "you opened it. Nothing here leaves your Mac."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                if learned.isEmpty {
                    Text("Open a few things and they will rank themselves here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(learned) { item in
                        LearnedRow(
                            name: item.entry.name, kind: item.entry.kindLabel,
                            icon: item.entry.icon, count: item.record.count, peak: peak,
                            lastUsed: item.record.lastUsed, queries: item.queries,
                            onForget: { forget(item) })
                    }
                }
            } header: {
                Text(learned.isEmpty ? "What It Learned" : "What It Learned (\(learned.count))")
            }

            FallbackCommandsSection()
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Forget \(range.title.lowercased())?", isPresented: $confirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Smallcast will relearn your preferred results as you use the launcher.")
        }
    }

    private func resetSubtitle(entries: Int) -> String {
        guard entries > 0 else { return "Nothing learned yet." }
        return "\(entries) \(entries == 1 ? "entry" : "entries") learned."
    }

    private func forget(_ item: Learned) {
        launchHistory.reset(itemKey: item.entry.preferenceKey)
        ranking.reset(itemKey: item.entry.preferenceKey)
    }

    private func reset() {
        let cutoff = range.cutoff(now: Date())
        launchHistory.reset(since: cutoff)
        ranking.reset(since: cutoff)
    }
}

/// One learned entry: what it is, how often it has been opened, and what you typed to get there.
private struct LearnedRow: View {
    let name: String
    let kind: String
    let icon: NSImage
    let count: Int
    let peak: Int
    let lastUsed: Date
    let queries: [String]
    let onForget: () -> Void

    var body: some View {
        SettingsRow(title: name, subtitle: subtitle) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
        } trailing: {
            // The bar is the comparison the number alone doesn't make.
            Capsule()
                .fill(Theme.Colors.controlSurface)
                .frame(width: 60, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(4, 60 * CGFloat(count) / CGFloat(max(peak, 1))), height: 4)
                }
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 28, alignment: .trailing)
            Button(action: onForget) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.plain)
            .help("Forget \(name)")
        }
    }

    private var subtitle: String {
        let when = lastUsed.formatted(.relative(presentation: .named))
        guard !queries.isEmpty else { return "\(kind) · \(when)" }
        return "\(kind) · \(when) · " + queries.map { "“\($0)”" }.joined(separator: ", ")
    }
}
