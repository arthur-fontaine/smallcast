import SwiftUI

/// Settings › Search: what a query that matched nothing offers instead. The list order *is* the row
/// order in the launcher, so this is a reorderable list rather than a set of checkboxes.
struct FallbackCommandsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AppCore.self) private var core
    /// Observed so adding or deleting an argument-taking quicklink updates the candidates at once.
    @Environment(QuicklinkStore.self) private var quicklinks

    var body: some View {
        @Bindable var settings = settings
        return Group {
            Section {
                Toggle(isOn: $settings.fallbackCommandsEnabled) {
                    Text("Enable Fallback Commands")
                    Text(
                        """
                        When a search matches nothing, offer commands that take what you typed as \
                        their input instead of an empty result list.
                        """
                    )
                }
            } header: {
                Text("Fallback Commands")
            }

            Section {
                if listed.isEmpty {
                    Text("Add a command below and it will show up under a search with no results.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(listed) { row in
                        SettingsRow(title: row.name) {
                            Image(systemName: row.sfSymbol)
                                .frame(width: Theme.Size.settingsRowIcon)
                        } trailing: {
                            Button {
                                remove(row.command)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(row.name)")
                        }
                    }
                    .onMove(perform: move)
                }

                if !candidates.isEmpty {
                    Menu("Add…") {
                        ForEach(candidates) { row in
                            Button(row.name) { add(row.command) }
                        }
                    }
                    .fixedSize()
                }
            } header: {
                Text("Order")
            } footer: {
                Text("Drag to reorder. The first row is the one ↵ runs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .settingsEnabled(settings.fallbackCommandsEnabled)

            Section {
                TextField("Search URL", text: $settings.webSearchTemplate)
                if settings.webSearchTemplate != FallbackCommands.defaultWebTemplate {
                    Button("Restore Default") {
                        settings.webSearchTemplate = FallbackCommands.defaultWebTemplate
                    }
                }
            } header: {
                Text("Search the Web")
            } footer: {
                Text(
                    "Put \(FallbackCommands.queryPlaceholder) where the search text belongs, as in "
                        + FallbackCommands.defaultWebTemplate + "."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .settingsEnabled(settings.fallbackCommandsEnabled)
        }
    }

    /// The configured order, named. Unlike the launcher's own rows this keeps entries whose feature
    /// is currently off, so turning File Search back on doesn't silently lose its place.
    private var listed: [FallbackRow] {
        core.fallbackCoordinator.configured.map {
            FallbackRow(command: $0, name: core.fallbackCoordinator.name(of: $0))
        }
    }

    private var candidates: [FallbackRow] {
        core.fallbackCoordinator.candidates.map {
            FallbackRow(command: $0, name: core.fallbackCoordinator.name(of: $0))
        }
    }

    private func add(_ command: FallbackCommandID) {
        settings.fallbackCommands.append(command.rawValue)
    }

    private func remove(_ command: FallbackCommandID) {
        settings.fallbackCommands.removeAll { $0 == command.rawValue }
    }

    private func move(from source: IndexSet, to destination: Int) {
        settings.fallbackCommands.move(fromOffsets: source, toOffset: destination)
    }
}
