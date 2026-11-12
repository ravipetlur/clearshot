import CoreGraphics
import Testing
@testable import CSOCR

struct TextAssemblerTests {
    /// Lines stacked down the page; the assembler reads only their text.
    private func lines(_ texts: String...) -> [OCRLine] {
        texts.enumerated().map { index, text in
            OCRLine(text: text, box: CGRect(x: 10, y: 10 + 40 * index, width: 300, height: 30))
        }
    }

    private func lines(_ texts: [String]) -> [OCRLine] {
        texts.enumerated().map { index, text in
            OCRLine(text: text, box: CGRect(x: 10, y: 10 + 40 * index, width: 300, height: 30))
        }
    }

    @Test func withLineBreaksJoinsLinesWithNewlines() {
        let text = TextAssembler.text(from: lines("First line", "  Second line ", "infor-", "mation"), keepLineBreaks: true)
        #expect(text == "First line\nSecond line\ninfor-\nmation")
    }

    @Test func withoutLineBreaksJoinsWithSpaces() {
        let text = TextAssembler.text(from: lines("The quick brown", " fox jumps ", "over the dog."), keepLineBreaks: false)
        #expect(text == "The quick brown fox jumps over the dog.")
    }

    @Test(arguments: [
        // A hyphen before a lowercase word is removed; joins chain, each line's own ending deciding.
        (["More infor-", "mation here"], "More information here"),
        (["infor-", "ma-", "tion"], "information"),
        // Before a capital it is kept without a space, and before anything other than a lowercase letter: a digit, a CJK
        // character.
        (["Jean-", "Paul Sartre"], "Jean-Paul Sartre"),
        (["COVID-", "19 cases"], "COVID-19 cases"),
        // A dash after a space is not a hyphen, and nor is a line that is only a dash: it has no letter before it.
        (["costs -", "less"], "costs - less"),
        (["one", "-", "two"], "one - two"),
    ])
    func aHyphenAtTheEndOfALineJoinsAWordOnlyBeforeALowercaseLetter(texts: [String], text: String) {
        #expect(TextAssembler.text(from: lines(texts), keepLineBreaks: false) == text)
    }

    @Test(arguments: [
        // Chinese and Japanese lines join without spaces; full-width punctuation, the usual line end in Chinese, runs on too.
        (["日本語の", "テキスト"], "日本語のテキスト"),
        (["中文。", "下一行"], "中文。下一行"),
        (["カタカナ", "「引用」"], "カタカナ「引用」"),
        (["中文，", "下一行"], "中文，下一行"),
        (["ﾊﾝｶｸ", "カナ"], "ﾊﾝｶｸカナ"),
        // Korean separates words with spaces, so a wrap between Hangul lines is one; Hanja beside Hangul too.
        (["한국어", "텍스트"], "한국어 텍스트"),
        (["大韓民國", "헌법"], "大韓民國 헌법"),
        (["한국어", "Text"], "한국어 Text"),
        // CJK next to Latin gets a space.
        (["日本語", "English"], "日本語 English"),
        (["Hello", "世界"], "Hello 世界"),
        (["価格 100", "円"], "価格 100 円"),
    ])
    func linesOfEachScriptJoinWithTheSpaceItUses(texts: [String], text: String) {
        #expect(TextAssembler.text(from: lines(texts), keepLineBreaks: false) == text)
    }

    @Test func emptyAndWhitespaceLinesAreSkipped() {
        let input = lines("", "First", "   ", "\t", "Second", " ")
        #expect(TextAssembler.text(from: input, keepLineBreaks: true) == "First\nSecond")
        #expect(TextAssembler.text(from: input, keepLineBreaks: false) == "First Second")
        #expect(TextAssembler.text(from: lines("", " "), keepLineBreaks: false).isEmpty)
        #expect(TextAssembler.text(from: [], keepLineBreaks: true).isEmpty)
    }
}
