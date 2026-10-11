import CSCore

public extension Prefs {
    // Text recognition (Advanced pane).
    static let textRecognitionKeepLineBreaks = PrefKey("textRecognitionKeepLineBreaks", default: true)
    static let textRecognitionAutoDetectLanguage = PrefKey("textRecognitionAutoDetectLanguage", default: true)
    /// A BCP-47 identifier, matched against Vision's languages with `Locale.Language(identifier:)`.
    static let textRecognitionPrimaryLanguage = PrefKey("textRecognitionPrimaryLanguage", default: "en-US")
    static let textRecognitionDetectLinks = PrefKey("textRecognitionDetectLinks", default: true)
}

/// The language settings a recognition runs with.
public struct TextRecognitionOptions: Equatable, Sendable {
    public var automaticallyDetectsLanguage: Bool
    /// A BCP-47 identifier such as "en-US"; used only when `automaticallyDetectsLanguage` is off.
    public var primaryLanguage: String
    /// Whether Vision corrects what it reads against the language (on for text a person reads). Correction can rewrite
    /// the characters of a token or a key, so a reading that looks for those turns it off.
    public var usesLanguageCorrection: Bool

    public init(automaticallyDetectsLanguage: Bool, primaryLanguage: String, usesLanguageCorrection: Bool = true) {
        self.automaticallyDetectsLanguage = automaticallyDetectsLanguage
        self.primaryLanguage = primaryLanguage
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    /// The options Settings › Advanced has chosen.
    @MainActor
    public init(preferences: Preferences) {
        self.init(automaticallyDetectsLanguage: preferences[Prefs.textRecognitionAutoDetectLanguage],
                  primaryLanguage: preferences[Prefs.textRecognitionPrimaryLanguage])
    }
}
