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

    @Test func withLineBreaksJoinsLinesWithNewlines() {
        let text = TextAssembler.text(from: lines("First line", "  Second line ", "infor-", "mation"), keepLineBreaks: true)
        #expect(text == "First line\nSecond line\ninfor-\nmation")
    }

    @Test func withoutLineBreaksJoinsWithSpaces() {
        let text = TextAssembler.text(from: lines("The quick brown", " fox jumps ", "over the dog."), keepLineBreaks: false)
        #expect(text == "The quick brown fox jumps over the dog.")
    }

    @Test func aHyphenBeforeALowercaseWordIsRemoved() {
        #expect(TextAssembler.text(from: lines("More infor-", "mation here"), keepLineBreaks: false) == "More information here")
        // Joins chain: each line's own ending decides.
        #expect(TextAssembler.text(from: lines("infor-", "ma-", "tion"), keepLineBreaks: false) == "information")
    }

    @Test func aHyphenBeforeACapitalIsKeptWithoutASpace() {
        #expect(TextAssembler.text(from: lines("Jean-", "Paul Sartre"), keepLineBreaks: false) == "Jean-Paul Sartre")
        // Anything other than a lowercase letter keeps the hyphen: a digit, a CJK character.
        #expect(TextAssembler.text(from: lines("COVID-", "19 cases"), keepLineBreaks: false) == "COVID-19 cases")
    }

    @Test func aDashAfterASpaceIsNotAHyphen() {
        #expect(TextAssembler.text(from: lines("costs -", "less"), keepLineBreaks: false) == "costs - less")
        // A line that is only a dash has no letter before it either.
        #expect(TextAssembler.text(from: lines("one", "-", "two"), keepLineBreaks: false) == "one - two")
    }

    @Test func chineseAndJapaneseLinesJoinWithoutSpaces() {
        #expect(TextAssembler.text(from: lines("日本語の", "テキスト"), keepLineBreaks: false) == "日本語のテキスト")
        #expect(TextAssembler.text(from: lines("中文。", "下一行"), keepLineBreaks: false) == "中文。下一行")
        #expect(TextAssembler.text(from: lines("カタカナ", "「引用」"), keepLineBreaks: false) == "カタカナ「引用」")
        // Full-width punctuation, the usual line end in Chinese, runs on too.
        #expect(TextAssembler.text(from: lines("中文，", "下一行"), keepLineBreaks: false) == "中文，下一行")
        #expect(TextAssembler.text(from: lines("ﾊﾝｶｸ", "カナ"), keepLineBreaks: false) == "ﾊﾝｶｸカナ")
    }

    @Test func koreanLinesKeepASpace() {
        // Korean separates words with spaces, so a wrap between Hangul lines is one; Hanja beside Hangul too.
        #expect(TextAssembler.text(from: lines("한국어", "텍스트"), keepLineBreaks: false) == "한국어 텍스트")
        #expect(TextAssembler.text(from: lines("大韓民國", "헌법"), keepLineBreaks: false) == "大韓民國 헌법")
        #expect(TextAssembler.text(from: lines("한국어", "Text"), keepLineBreaks: false) == "한국어 Text")
    }

    @Test func cjkNextToLatinGetsASpace() {
        #expect(TextAssembler.text(from: lines("日本語", "English"), keepLineBreaks: false) == "日本語 English")
        #expect(TextAssembler.text(from: lines("Hello", "世界"), keepLineBreaks: false) == "Hello 世界")
        #expect(TextAssembler.text(from: lines("価格 100", "円"), keepLineBreaks: false) == "価格 100 円")
    }

    @Test func emptyAndWhitespaceLinesAreSkipped() {
        let input = lines("", "First", "   ", "\t", "Second", " ")
        #expect(TextAssembler.text(from: input, keepLineBreaks: true) == "First\nSecond")
        #expect(TextAssembler.text(from: input, keepLineBreaks: false) == "First Second")
        #expect(TextAssembler.text(from: lines("", " "), keepLineBreaks: false).isEmpty)
        #expect(TextAssembler.text(from: [], keepLineBreaks: true).isEmpty)
    }
}
