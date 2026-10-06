import Foundation

/// A language accurate text recognition reads, as Settings › Advanced offers it for Primary language.
public struct RecognitionLanguage: Identifiable, Equatable, Sendable {
    /// What `Prefs.textRecognitionPrimaryLanguage` stores: `tag(for:)` of the language.
    public let id: String
    /// The language's name in `locale`'s language, such as "English (United States)".
    public let name: String

    public init(_ language: Locale.Language, locale: Locale = .current) {
        let id = Self.tag(for: language)
        self.id = id
        // A region Foundation doesn't know (Vision's Vietnamese is "vi-VT") has no name: the language's is used.
        name = locale.localizedString(forIdentifier: id)
            ?? language.languageCode.flatMap { locale.localizedString(forLanguageCode: $0.identifier) }
            ?? id
    }

    /// Every language Vision reads on this Mac, sorted by name.
    public static func supported(locale: Locale = .current) -> [RecognitionLanguage] {
        TextRecognizer.supportedLanguages()
            .map { RecognitionLanguage($0, locale: locale) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A BCP-47 tag that `Locale.Language(identifier:)` reads back as `language` itself: the first of language-region,
    /// language-script and language-script-region that does ("en-US", "zh-Hans", "ko-KR"). The recognizer then asks Vision
    /// for exactly its own language, and the default "en-US" matches Vision's entry. Each candidate is checked because
    /// `script` reports the likely script when none was given (Vision's "ko-KR" says "Kore"), and "ko-Kore-KR" is
    /// another language to `==`.
    public static func tag(for language: Locale.Language) -> String {
        let code = language.languageCode?.identifier
        let script = language.script?.identifier
        let region = language.region?.identifier
        let candidates = [[code, region], [code, script], [code, script, region]]
            .map { $0.compactMap { $0 }.joined(separator: "-") }
        return candidates.first { Locale.Language(identifier: $0) == language } ?? language.maximalIdentifier
    }
}
