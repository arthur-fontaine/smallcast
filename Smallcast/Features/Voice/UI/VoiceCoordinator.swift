import AppKit
import Foundation

/// Hold to talk: the toggle shortcut held past the threshold records, and its release asks the AI.
@MainActor
final class VoiceCoordinator {
    private let session: VoiceSession
    private let settings: AppSettings
    private let voiceSettings: VoiceSettingsStore
    private let models: VoiceModelStore
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private unowned let core: AppCore
    private let recorder = VoiceRecorder()
    private var holding = false
    private var loaded: (engine: VoiceEngine, transcriber: any VoiceTranscriber)?
    private var loading: (engine: VoiceEngine, task: Task<any VoiceTranscriber, Error>)?
    private var transcription: Task<Void, Never>?

    /// Shorter than this is a slip of the finger, not a question.
    private static let minimumDuration: TimeInterval = 0.4

    init(
        session: VoiceSession, settings: AppSettings, voiceSettings: VoiceSettingsStore,
        models: VoiceModelStore, paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator, core: AppCore
    ) {
        self.session = session
        self.settings = settings
        self.voiceSettings = voiceSettings
        self.models = models
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.core = core
        recorder.onLevel = { [weak session] level in session?.heard(level) }
    }

    /// The toggle shortcut has been held past `HoldDetector.threshold`.
    func beginHold() {
        // Off means fully off: a hold is a plain press while AI Chat or the switch is off.
        guard settings.aiEnabled, voiceSettings.holdToTalk, !session.isActive else { return }
        let engine = voiceSettings.engine
        guard models.status(for: engine) == .installed else {
            core.showMessage("Download \(engine.title) in Settings → AI before talking to the AI.", tone: .neutral)
            return
        }
        if engine.requiresLanguage, voiceSettings.language.isAuto {
            core.showMessage("\(engine.title) needs a language. Pick one in Settings → AI.", tone: .neutral)
            return
        }
        holding = true
        Task { await listen(with: engine) }
    }

    /// The held shortcut has been released.
    func endHold() {
        holding = false
        guard session.phase == .listening else { return }
        let audio = recorder.stop()
        guard let engine = session.engine, audio.duration >= Self.minimumDuration else {
            session.reset()
            return
        }
        session.transcribe()
        transcription = Task { [weak self] in
            await self?.transcribe(audio, with: engine)
        }
    }

    /// Escape, or leaving the screen: the recording is dropped and nothing is asked.
    func cancel() {
        holding = false
        transcription?.cancel()
        transcription = nil
        if recorder.isRecording { _ = recorder.stop() }
        session.reset()
    }

    /// Loads the chosen engine ahead of the first hold, so releasing never waits on a load.
    func warmUp() {
        guard settings.aiEnabled, voiceSettings.holdToTalk else { return }
        let engine = voiceSettings.engine
        guard models.status(for: engine) == .installed else { return }
        _ = load(engine)
    }

    private func listen(with engine: VoiceEngine) async {
        var access = Permissions.microphoneAccess()
        if access == .notDetermined {
            _ = await Permissions.requestMicrophoneAccess()
            access = Permissions.microphoneAccess()
        }
        guard access == .granted else {
            holding = false
            core.showMessage("Allow the microphone in System Settings › Privacy & Security.", tone: .neutral)
            return
        }
        // The key may have come up while macOS was asking; that hold is over.
        guard holding, !session.isActive else { return }
        do {
            try recorder.start()
        } catch {
            holding = false
            core.showMessage(error.localizedDescription, tone: .neutral)
            return
        }
        session.listen(with: engine)
        _ = load(engine)
        paletteCoordinator.showPalette(mode: .ai)
    }

    private func transcribe(_ audio: VoiceAudio, with engine: VoiceEngine) async {
        do {
            let transcriber = try await load(engine).value
            let text = try await transcriber.transcribe(audio, language: voiceSettings.language)
            guard !Task.isCancelled else { return }
            session.reset()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                core.showMessage("Nothing heard.", tone: .neutral)
                return
            }
            // Escape during the pause meant "never mind": the question is not asked behind the user.
            guard paletteCoordinator.isVisible else { return }
            core.aiChatCoordinator.ask(trimmed)
        } catch is CancellationError {
            session.reset()
        } catch {
            session.reset()
            core.showMessage(error.localizedDescription, tone: .neutral)
        }
    }

    /// One loaded engine at a time; a change of engine drops the old one with its memory.
    private func load(_ engine: VoiceEngine) -> Task<any VoiceTranscriber, Error> {
        if let loaded, loaded.engine == engine {
            return Task { loaded.transcriber }
        }
        if let loading, loading.engine == engine { return loading.task }
        loading?.task.cancel()
        loaded = nil
        let root = models.root
        let task = Task<any VoiceTranscriber, Error> { [weak self] in
            let transcriber = try await VoiceTranscriberFactory.load(engine, root: root)
            // One silent second specialises the graphs now rather than on the first real question.
            // Cohere's encoder costs its full 35 s window every time, so it alone is not warmed.
            if engine.runtime == .cohere { return transcriber }
            _ = try? await transcriber.transcribe(
                VoiceAudio(samples: [Float](repeating: 0, count: VoiceAudio.sampleRate)),
                language: engine.requiresLanguage ? .named("en") : .auto)
            await MainActor.run { self?.loaded = (engine, transcriber) }
            return transcriber
        }
        loading = (engine, task)
        return task
    }

    /// Settings changed the engine: forget the old one so the next hold loads the new one.
    func applyEngine() {
        if loaded?.engine != voiceSettings.engine {
            loading?.task.cancel()
            loading = nil
            loaded = nil
        }
        warmUp()
    }

    func showSettings() {
        paletteCoordinator.hidePalette(restoreFocus: false)
        settingsCoordinator.showSettings(tab: .ai)
    }
}
