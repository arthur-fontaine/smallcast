import SwiftUI

struct EmojiSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(EmojiSuggestionManager.self) private var suggestions

    var body: some View {
        @Bindable var settings = settings
        return Form {
            FeatureCommandsSection(owner: .emoji, anchor: .emojiCommands)

            Section {
                // A hand per tone, quicker to scan than a dropdown of tone names.
                Picker(selection: $settings.emojiSkinTone) {
                    ForEach(EmojiSkinTone.allCases) { tone in
                        Text(tone.sample).tag(tone)
                    }
                } label: {
                    SettingsRowTitle(.emojiAppearance, "Emoji Skin Tone")
                }
                .pickerStyle(.segmented)
            } header: {
                SettingsSectionHeader(.emojiAppearance)
            } footer: {
                Text("Applied when an emoji supports skin tones; pastes use it too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Enabling is also consent to record typing, so it uses the confirming setter.
                Toggle(
                    isOn: Binding(
                        get: { settings.emojiSuggestionsEnabled },
                        set: { core.emojiCoordinator.setSuggestionsEnabled($0) })
                ) {
                    SettingsRowTitle(.emojiSuggestions, "Suggest emoji from what you type")
                    Text("A Suggested row in the picker, matched to the sentence you were writing.")
                }
                if settings.emojiSuggestionsEnabled {
                    suggestionsStatus
                }
            } header: {
                SettingsSectionHeader(.emojiSuggestions)
            } footer: {
                suggestionsFooter
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.emoji)
    }

    @ViewBuilder
    private var suggestionsStatus: some View {
        if suggestions.recorder.status == .needsAccessibility {
            LabeledContent {
                Button("Grant Access…") { Permissions.openAccessibilitySettings() }
            } label: {
                Label("Suggestions need the Accessibility permission.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text("The same grant pasting uses. Nothing is recorded until it is given.")
            }
        }
        switch suggestions.status {
        case .off, .ready:
            EmptyView()
        case .downloading:
            LabeledContent {
                ProgressView(value: suggestions.modelProgress ?? 0)
                    .frame(width: 120)
            } label: {
                Text("Downloading the Emo model…")
            }
        case .loading:
            Text("Loading the Emo model…")
                .foregroundStyle(.secondary)
        case .failed(let message):
            LabeledContent {
                Button("Retry", action: suggestions.retry)
            } label: {
                Label("The Emo model isn’t available.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
            }
        }
    }

    private var suggestionsFooter: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(
                "Keeps the last sentence typed in other apps, on this Mac and in memory only. "
                    + "Turning it off forgets it and deletes the downloaded model."
            )
            Link(destination: EmoModelStore.providerURL) {
                HStack(spacing: Theme.Spacing.xxs) {
                    Text("Powered by Emo from \(EmoModelStore.provider)")
                    Image(systemName: "arrow.up.right.square")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
