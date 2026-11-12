import Testing
@testable import CSAnnotation

/// The Annotate tool letters' rows in Settings › Shortcuts, found by title, keyword or section title.
struct AnnotateKeySearchTests {
    /// A keyword or a title, in any case, finds its row: pixelate finds Redact, marker the highlighter.
    @Test(arguments: [("pixelate", AnnotateKeyTarget.tool(.redact)), ("Blur", .tool(.redact)), ("REDACT", .tool(.redact)),
                      ("marker", .tool(.highlighter)), ("wallpaper", .backgroundPanel)])
    func aKeywordFindsItsTarget(query: String, target: AnnotateKeyTarget) {
        #expect(AnnotateKeyTarget.matching(query) == [target])
    }

    @Test func theGroupTitleFindsEveryTarget() {
        #expect(AnnotateKeyTarget.groupTitle == "Annotate tools")
        #expect(AnnotateKeyTarget.matching("annotate tools").count == 15)
        #expect(AnnotateKeyTarget.matching("Annotate Tools") == AnnotateKeyTarget.allCases)
        // A blank query finds everything, as `ClearShotAction.matching` does; nonsense finds nothing.
        #expect(AnnotateKeyTarget.matching("") == AnnotateKeyTarget.allCases)
        #expect(AnnotateKeyTarget.matching("  ") == AnnotateKeyTarget.allCases)
        #expect(AnnotateKeyTarget.matching("zzzz").isEmpty)
    }
}
