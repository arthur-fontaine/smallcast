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
                EmojiColumnCountPicker(selection: $settings.emojiGridColumns)
                SettingsRow(title: "Emoji Skin Tone", anchor: .emojiAppearance) {
                    HStack(spacing: Theme.Spacing.xs) {
                        ForEach(EmojiSkinTone.allCases) { tone in
                            let selected = settings.emojiSkinTone == tone
                            Button {
                                settings.emojiSkinTone = tone
                            } label: {
                                Text(tone.sample)
                                    .font(.system(size: Theme.Size.emojiSkinToneGlyph))
                                    .settingsOptionSegment(isSelected: selected)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(tone.title)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                            .help(tone.title)
                        }
                    }
                }
            } header: {
                SettingsSectionHeader(.emojiAppearance)
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

/// Five previews make the picker's starting density legible before the user opens it.
private struct EmojiColumnCountPicker: View {
    @Binding var selection: EmojiGridColumns

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            SettingsRowTitle(.emojiAppearance, "Column Count")

            HStack(spacing: Theme.Spacing.xl) {
                ForEach(EmojiGridColumns.allCases) { columns in
                    option(columns)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private func option(_ columns: EmojiGridColumns) -> some View {
        let isSelected = selection == columns
        return Button {
            selection = columns
        } label: {
            VStack(spacing: Theme.Spacing.sm) {
                EmojiColumnCountPreview(columns: columns.rawValue, isSelected: isSelected)
                Text(columns.rawValue, format: .number)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(columns.rawValue) columns")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct EmojiColumnCountPreview: View {
    let columns: Int
    let isSelected: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        EmojiGridDots(columns: columns)
            .fill(isSelected ? Theme.Colors.textTertiary : Theme.Colors.border)
            .background(
                shape.fill(isSelected ? Theme.Colors.controlSurface : Color.clear)
            )
            .overlay(
                shape.strokeBorder(
                    isSelected ? Theme.Colors.border : Theme.Colors.cardStroke,
                    lineWidth: Theme.Size.hairline)
            )
            .clipShape(shape)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: Theme.Size.emojiSettingsGridPreview)
    }
}

/// Dots share one lattice, so horizontal and vertical runs meet on the exact same point.
private struct EmojiGridDots: Shape {
    let columns: Int

    private static let pointsPerCell = 4
    /// Match the outline's raster weight; subpixel circles render visibly fainter at the same alpha.
    private static let dotDiameter = Theme.Size.hairline

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let subdivisions = columns * Self.pointsPerCell
        guard subdivisions > 0 else { return path }
        let horizontalStep = rect.width / CGFloat(subdivisions)
        let verticalStep = rect.height / CGFloat(subdivisions)
        let radius = Self.dotDiameter / 2

        for row in 0...subdivisions {
            for column in 0...subdivisions {
                let onVertical =
                    column.isMultiple(of: Self.pointsPerCell)
                    && column > 0 && column < subdivisions
                let onHorizontal =
                    row.isMultiple(of: Self.pointsPerCell)
                    && row > 0 && row < subdivisions
                guard onVertical || onHorizontal else { continue }
                let center = CGPoint(
                    x: rect.minX + CGFloat(column) * horizontalStep,
                    y: rect.minY + CGFloat(row) * verticalStep)
                path.addEllipse(
                    in: CGRect(
                        x: center.x - radius, y: center.y - radius,
                        width: Self.dotDiameter, height: Self.dotDiameter))
            }
        }
        return path
    }
}
