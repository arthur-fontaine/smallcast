import Foundation
import Observation

/// What voice mode runs with. Every key stays out of settings backups; see docs/features/voice.md.
@MainActor
@Observable
final class VoiceSettingsStore {
    private let defaults: UserDefaults

    /// Holding the launcher shortcut records and asks the AI; off, a long press is a plain press.
    var holdToTalk: Bool {
        didSet { defaults.set(holdToTalk, forKey: AppSettingsKey.voiceHoldToTalk.rawValue) }
    }

    var engine: VoiceEngine {
        didSet { defaults.set(engine.rawValue, forKey: AppSettingsKey.voiceEngine.rawValue) }
    }

    var language: VoiceLanguage {
        didSet { defaults.set(language.code, forKey: AppSettingsKey.voiceLanguage.rawValue) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holdToTalk = defaults.object(forKey: AppSettingsKey.voiceHoldToTalk.rawValue) as? Bool ?? true
        engine =
            defaults.string(forKey: AppSettingsKey.voiceEngine.rawValue).flatMap(VoiceEngine.init(rawValue:))
            ?? .default
        language = VoiceLanguage.named(
            defaults.string(forKey: AppSettingsKey.voiceLanguage.rawValue) ?? VoiceLanguage.auto.code)
    }
}
