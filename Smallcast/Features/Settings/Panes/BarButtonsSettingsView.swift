import SwiftUI

/// The Liquid Glass compact bar's buttons: a switch, then one picker per slot.
struct BarButtonsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    private var isLiquidGlass: Bool { settings.paletteTheme == .liquidGlass }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            if !isLiquidGlass {
                ThemeRequirementSection()
            }

            Section {
                Toggle(isOn: $settings.spotlightButtonsEnabled) {
                    SettingsRowTitle(.barButtonsGeneral, "Show bar buttons")
                    Text("Beside the compact bar, as Spotlight sets its own. ⌘2–⌘5 open them.")
                }
                if !settings.compactMode {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Text("They only appear in the Compact window mode.")
                            .foregroundStyle(.secondary)
                        Spacer(minLength: Theme.Spacing.lg)
                        Button("Use Compact") { settings.compactMode = true }
                    }
                    .settingsEnabled(settings.spotlightButtonsEnabled)
                }
            } header: {
                SettingsSectionHeader(.barButtonsGeneral)
            }
            .settingsEnabled(isLiquidGlass)

            BarButtonSlotsSection()
                .settingsEnabled(isLiquidGlass && settings.spotlightButtonsEnabled)
        }
        .formStyle(.grouped)
    }
}

/// Why everything below is dimmed, with the one click that changes it.
private struct ThemeRequirementSection: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: Theme.Size.settingsRowIcon)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Bar buttons are part of the Liquid Glass theme")
                    Text("The Smallcast theme draws no buttons beside its bar, so these do nothing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.lg)
                Button("Use Liquid Glass") { settings.paletteTheme = .liquidGlass }
            }
        }
    }
}

/// One picker per slot: choosing sets a button, its place and, with None, how many there are.
private struct BarButtonSlotsSection: View {
    @Environment(AppSettings.self) private var settings

    /// The buttons there are, then one empty slot to add another, up to the cap.
    private var slots: Range<Int> {
        0..<min(settings.spotlightButtons.count + 1, SpotlightButton.maximumCount)
    }

    var body: some View {
        Section {
            ForEach(slots, id: \.self) { slot in
                Picker(selection: binding(slot)) {
                    Text("None").tag(SpotlightButton?.none)
                    ForEach(SpotlightButton.allCases) { button in
                        Label(button.title, systemImage: button.systemImage).tag(Optional(button))
                    }
                } label: {
                    Text("Button \(slot + 1)")
                    Text("⌘\(slot + 2)")
                }
            }
        } header: {
            SettingsSectionHeader(.barButtonsSlots)
        } footer: {
            Text("Picking a button from another slot swaps the two. ⌘1 returns to the search field.")
        }
    }

    private func binding(_ slot: Int) -> Binding<SpotlightButton?> {
        Binding(
            get: {
                settings.spotlightButtons.indices.contains(slot)
                    ? settings.spotlightButtons[slot] : nil
            },
            set: { button in
                settings.spotlightButtons = SpotlightButton.assigning(
                    button, toSlot: slot, in: settings.spotlightButtons)
            })
    }
}
