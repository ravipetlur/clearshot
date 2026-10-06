import Testing
@testable import CSAnnotation

/// The Annotate tool letters' rows in Settings › Shortcuts, found by title, keyword or section title.
struct AnnotateKeySearchTests {
    @Test func pixelateFindsRedact() {
        #expect(AnnotateKeyTarget.matching("pixelate") == [.tool(.redact)])
        #expect(AnnotateKeyTarget.matching("Blur") == [.tool(.redact)])
        #expect(AnnotateKeyTarget.matching("REDACT") == [.tool(.redact)])
    }

    @Test func markerFindsTheHighlighter() {
        #expect(AnnotateKeyTarget.matching("marker") == [.tool(.highlighter)])
        #expect(AnnotateKeyTarget.matching("wallpaper") == [.backgroundPanel])
    }

    @Test func theGroupTitleFindsEveryTarget() {
        #expect(AnnotateKeyTarget.groupTitle == "Annotate tools")
        #expect(AnnotateKeyTarget.matching("annotate tools").count == 14)
        #expect(AnnotateKeyTarget.matching("Annotate Tools") == AnnotateKeyTarget.allCases)
        // A blank query finds everything, as `ClearShotAction.matching` does; nonsense finds nothing.
        #expect(AnnotateKeyTarget.matching("") == AnnotateKeyTarget.allCases)
        #expect(AnnotateKeyTarget.matching("  ") == AnnotateKeyTarget.allCases)
        #expect(AnnotateKeyTarget.matching("zzzz").isEmpty)
    }
}
