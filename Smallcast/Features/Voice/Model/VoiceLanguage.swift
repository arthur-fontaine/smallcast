import Foundation

/// The language a voice engine is told to expect. Stored as a BCP-47 code, `auto` for none.
struct VoiceLanguage: Hashable, Sendable, Identifiable {
    let code: String
    let name: String

    var id: String { code }

    static let auto = VoiceLanguage(code: "auto", name: "Automatic")

    var isAuto: Bool { code == Self.auto.code }

    /// Ordered for a picker: the automatic choice, then names alphabetically.
    static let all: [VoiceLanguage] =
        [auto]
        + [
            ("ar", "Arabic"), ("bg", "Bulgarian"), ("zh", "Chinese"), ("hr", "Croatian"),
            ("cs", "Czech"), ("da", "Danish"), ("nl", "Dutch"), ("en", "English"),
            ("et", "Estonian"), ("fi", "Finnish"), ("fr", "French"), ("de", "German"),
            ("el", "Greek"), ("he", "Hebrew"), ("hi", "Hindi"), ("hu", "Hungarian"),
            ("id", "Indonesian"), ("it", "Italian"), ("ja", "Japanese"), ("ko", "Korean"),
            ("lv", "Latvian"), ("lt", "Lithuanian"), ("ms", "Malay"), ("nb", "Norwegian"),
            ("pl", "Polish"), ("pt", "Portuguese"), ("ro", "Romanian"), ("ru", "Russian"),
            ("sk", "Slovak"), ("sl", "Slovenian"), ("es", "Spanish"), ("sv", "Swedish"),
            ("th", "Thai"), ("tr", "Turkish"), ("uk", "Ukrainian"), ("vi", "Vietnamese"),
        ].map { VoiceLanguage(code: $0.0, name: $0.1) }

    static func named(_ code: String) -> VoiceLanguage {
        all.first { $0.code == code } ?? auto
    }

    /// The bare language of a locale identifier, so `fr_FR` and `fr-CA` both read as `fr`.
    static func base(of identifier: String) -> String {
        String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
            .lowercased()
    }
}
