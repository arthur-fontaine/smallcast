import SwiftUI

/// Settings → AI's Voice section: the hold switch, the engine and its language.
struct VoiceSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(VoiceSettingsStore.self) private var voice
    @Environment(VoiceModelStore.self) private var models
    @State private var enginesPresented = false

    var body: some View {
        @Bindable var voice = voice
        Section {
            Toggle(isOn: $voice.holdToTalk) {
                SettingsRowTitle(.aiVoice, "Hold the launcher shortcut to talk")
                Text("Keep it held half a second and speak. Release it and what you said is asked.")
            }
            SettingsRow(title: "Engine", subtitle: engineSummary, anchor: .aiVoice) {
                Button("Choose…") { enginesPresented = true }
            }
            Picker(selection: $voice.language) {
                ForEach(VoiceLanguage.all) { Text($0.name).tag($0) }
            } label: {
                SettingsRowTitle(.aiVoice, "Language")
                Text(languageHint)
            }
            .disabled(!voice.engine.takesLanguage)
        } header: {
            SettingsSectionHeader(.aiVoice)
        } footer: {
            Text("Speech is turned into text on this Mac. Only that text reaches the AI model you chose.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(isPresented: $enginesPresented) {
            VoiceEngineSheet(onDone: { enginesPresented = false })
        }
        .onChange(of: voice.engine) { core.voiceCoordinator.applyEngine() }
        .onChange(of: voice.holdToTalk) { core.voiceCoordinator.applyEngine() }
    }

    private var engineSummary: String {
        let engine = voice.engine
        switch models.status(for: engine) {
        case .installed: return engine.title
        case .downloading(let progress): return "\(engine.title) · downloading \(Int(progress * 100)) %"
        case .notInstalled: return "\(engine.title) · not downloaded"
        case .failed: return "\(engine.title) · download failed"
        }
    }

    private var languageHint: String {
        let engine = voice.engine
        if !engine.takesLanguage { return "\(engine.title) hears English only." }
        if engine.requiresLanguage { return "\(engine.title) needs to be told the language." }
        return "Automatic lets the engine detect it; naming one helps with short questions."
    }
}

/// Every engine as a card, with the trade-offs FluidVoice-style: what it does well, what it does not.
struct VoiceEngineSheet: View {
    @Environment(VoiceSettingsStore.self) private var voice
    @Environment(VoiceModelStore.self) private var models
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Voice Engines").font(.title2.weight(.bold))
                Text("Every engine runs on this Mac. Pick the trade-off that suits how you talk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.top, Theme.Spacing.xxl)

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.lg) {
                    ForEach(VoiceEngine.allCases) { engine in
                        VoiceEngineCard(engine: engine)
                    }
                }
                .padding(Theme.Spacing.xxl)
            }

            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.xxl)
        }
        .frame(width: Theme.Size.editorSheetWidth, height: 640)
    }
}

private struct VoiceEngineCard: View {
    @Environment(VoiceSettingsStore.self) private var voice
    @Environment(VoiceModelStore.self) private var models
    let engine: VoiceEngine

    private var isSelected: Bool { voice.engine == engine }
    private var status: VoiceModelStatus { models.status(for: engine) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(engine.title).font(.headline)
                    Text(engine.tagline).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Spacing.md)
                action
            }
            HStack(spacing: Theme.Spacing.sm) {
                pill(engine.vendor.rawValue)
                pill(engine.languages)
                pill(sizeLabel)
                if case .downloading(let progress) = status {
                    ProgressView(value: progress).frame(width: 80)
                }
            }
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                points("Strengths", engine.strengths, symbol: "checkmark.circle", tint: .green)
                points("Weaknesses", engine.weaknesses, symbol: "minus.circle", tint: .orange)
            }
            if case .failed(let reason) = status {
                Text(reason).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
    }

    @ViewBuilder private var action: some View {
        HStack(spacing: Theme.Spacing.sm) {
            switch status {
            case .installed:
                if engine.assets != nil, !isSelected {
                    Button("Remove") { models.remove(engine) }
                }
                if isSelected {
                    Label("In use", systemImage: "checkmark").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Use") { voice.engine = engine }
                }
            case .downloading:
                Button("Cancel") { models.cancelInstall(engine) }
            case .notInstalled, .failed:
                Button(isSelected ? "Download" : "Download and Use") {
                    models.install(engine)
                    voice.engine = engine
                }
            }
        }
    }

    private var sizeLabel: String {
        guard let bytes = engine.downloadBytes else { return "Built in" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    private func points(_ title: String, _ items: [String], symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                Label { Text(item).font(.caption) } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
