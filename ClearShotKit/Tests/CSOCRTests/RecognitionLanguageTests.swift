import CSCore
import Foundation
import Testing
@testable import CSOCR

struct RecognitionLanguageTests {
    private let english = Locale(identifier: "en_US")

    @Test func everyLanguageVisionReadsRoundTrips() {
        let languages = TextRecognizer.supportedLanguages()
        #expect(!languages.isEmpty)
        for language in languages {
            let tag = RecognitionLanguage.tag(for: language)
            #expect(Locale.Language(identifier: tag) == language, "\(tag)")
        }
    }

    @Test func theChoicesHaveUniqueIDsAndAreSortedByName() {
        let choices = RecognitionLanguage.supported(locale: english)
        #expect(choices.count == TextRecognizer.supportedLanguages().count)
        #expect(Set(choices.map(\.id)).count == choices.count)
        #expect(zip(choices, choices.dropFirst()).allSatisfy { $0.name.localizedStandardCompare($1.name) != .orderedDescending })
    }

    @Test func theDefaultPrimaryLanguageIsAChoice() {
        let tag = Prefs.textRecognitionPrimaryLanguage.defaultValue
        #expect(tag == "en-US")
        #expect(TextRecognizer.supportedLanguages().contains(Locale.Language(identifier: tag)))
        #expect(RecognitionLanguage.supported(locale: english).first { $0.id == tag }?.name == "English (United States)")
    }

    @Test func aLikelyScriptStaysOutOfTheTag() {
        // `Locale.Language.script` reports "Kore" or "Latn" here though none was given; a tag with it reads back as
        // another language.
        #expect(RecognitionLanguage.tag(for: Locale.Language(identifier: "ko-KR")) == "ko-KR")
        #expect(RecognitionLanguage.tag(for: Locale.Language(identifier: "en-US")) == "en-US")
        #expect(RecognitionLanguage.tag(for: Locale.Language(identifier: "no-NO")) == "no-NO")
        #expect(RecognitionLanguage.tag(for: Locale.Language(identifier: "zh-Hans")) == "zh-Hans")
    }

    @Test func aRegionWithoutANameFallsBackToTheLanguageName() {
        // Vision's Vietnamese is "vi-VT", a region Foundation doesn't name.
        #expect(RecognitionLanguage(Locale.Language(identifier: "vi-VT"), locale: english).name == "Vietnamese")
        #expect(RecognitionLanguage(Locale.Language(identifier: "ja-JP"), locale: english).name == "Japanese (Japan)")
        #expect(RecognitionLanguage(Locale.Language(identifier: "ja-JP"), locale: english).id == "ja-JP")
    }
}
