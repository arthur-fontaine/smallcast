import SwiftUI

/// Settings › Search: what the launcher has learned from you, and how to forget it. The list is the
/// learned order itself, so it doubles as an explanation of why a result sits where it does.
struct SearchSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppIndex.self) private var appIndex
    @Environment(LaunchHistoryStore.self) private var launchHistory
    @Environment(LauncherRankingStore.self) private var ranking

    @State private var range: UsageResetRange = .today
    @State private var confirmingReset = false

    /// One learned entry, resolved back to what it points at.
    private struct Learned: Identifiable {
        let entry: AppEntry
        let record: LearnedEntry

        var id: String { entry.id }
    }

    /// Most recent first. A hotkey launch taught nothing; an uninstalled key ranks nothing.
    private var learned: [Learned] {
        let byKey = Dictionary(
            appIndex.apps.map { ($0.preferenceKey, $0) }, uniquingKeysWith: { first, _ in first })
        return
            ranking.learnedEntries()
            .compactMap { key, record -> Learned? in
                byKey[key].map { Learned(entry: $0, record: record) }
            }
            .sorted {
                $0.record.lastUsed != $1.record.lastUsed
                    ? $0.record.lastUsed > $1.record.lastUsed
                    : $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
            }
    }

    var body: some View {
        let learned = learned
        let peak = learned.map(\.record.score).max() ?? 1
        return Form {
            Section {
                let order = core.settings.launcherSectionOrder
                ForEach(Array(order.enumerated()), id: \.element) { index, section in
                    SectionOrderRow(
                        section: section, index: index, count: order.count,
                        subtitle: subtitle(for: section), move: { move(index, by: $0) })
                }
            } header: {
                SettingsSectionHeader(.searchSections)
            } footer: {
                Text("The order root search lists its rows in, below a calculation or a meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                            icon: item.entry.icon, score: item.record.score, peak: peak,
                            lastUsed: item.record.lastUsed, queries: item.record.queries,
                            onForget: { forget(item) })
                    }
                }
            } header: {
                Text(learned.isEmpty ? "What It Learned" : "What It Learned (\(learned.count))")
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.search)
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

    private func subtitle(for section: LauncherSection) -> String {
        switch section {
        case .results: return String(localized: "Apps, commands and everything else it finds")
        case .files:
            let settings = core.settings
            guard settings.fileSearchEnabled, settings.fileSearchShowInLauncher else {
                return String(localized: "Off: turn on Show in launcher in File Search")
            }
            return String(localized: "The five best files, by name and contents")
        case .fallbacks: return String(localized: "“Use … with” rows, as Fallbacks lists them")
        }
    }

    private func move(_ index: Int, by delta: Int) {
        var order = core.settings.launcherSectionOrder
        guard order.indices.contains(index + delta) else { return }
        order.swapAt(index, index + delta)
        core.settings.launcherSectionOrder = order
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

/// One of root search's sections, moved with the same chevrons as Settings › Fallbacks.
private struct SectionOrderRow: View {
    let section: LauncherSection
    let index: Int
    let count: Int
    let subtitle: String
    let move: (Int) -> Void

    var body: some View {
        SettingsRow(title: section.title, subtitle: subtitle) {
            Image(systemName: section.symbol)
        } trailing: {
            Button {
                move(-1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel("Move \(section.title) up")
            Button {
                move(1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == count - 1)
            .accessibilityLabel("Move \(section.title) down")
        }
    }
}

/// One learned entry: what it is, how strongly it ranks, and what you typed to get there.
private struct LearnedRow: View {
    let name: String
    let kind: String
    let icon: NSImage
    let score: Double
    let peak: Double
    let lastUsed: Date
    let queries: [String]
    let onForget: () -> Void

    var body: some View {
        SettingsRow(title: name, subtitle: subtitle) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: Theme.Size.settingsRowIcon, height: Theme.Size.settingsRowIcon)
        } trailing: {
            // A decayed score means nothing as a number, so only its share of the strongest is drawn.
            Capsule()
                .fill(Theme.Colors.controlSurface)
                .frame(width: 60, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(4, 60 * score / max(peak, 1)), height: 4)
                }
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
