import Foundation
import Testing
import CSUpdate

/// GitHub's release notes are Markdown, with headings, lists, emphasis, code and links. SwiftUI's `Text` draws inline
/// styles but not blocks, so the notes are cut into blocks here, each with its own inline styles, for the window to lay
/// out.
struct ReleaseNotesTests {
    typealias Block = ReleaseNotes.Block

    func plain(_ text: AttributedString) -> String { String(text.characters) }

    /// A block's text, whatever kind it is, to compare against.
    func text(of block: Block) -> String {
        switch block {
        case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, let text): plain(text)
        case .codeBlock(let code): code
        case .rule: ""
        }
    }

    func blocks(_ markdown: String) -> [Block] { ReleaseNotes.blocks(fromMarkdown: markdown) }

    // MARK: Nothing

    @Test func emptyNotesHaveNoBlocks() {
        #expect(blocks("").isEmpty)
        #expect(blocks("   \n\n  \r\n").isEmpty)
    }

    // MARK: Headings and paragraphs

    @Test func headingsKeepTheirLevel() throws {
        let result = blocks("# One\n\n## Two\n\n### Three\n\n#### Four")
        #expect(result.count == 4)
        for (index, block) in result.enumerated() {
            guard case .heading(let level, let text) = block else { Issue.record("not a heading: \(block)"); continue }
            #expect(level == index + 1)
            #expect(plain(text) == ["One", "Two", "Three", "Four"][index])
        }
    }

    @Test func paragraphsAreSeparateBlocks() {
        let result = blocks("First paragraph.\n\nSecond paragraph.")
        #expect(result.map(text(of:)) == ["First paragraph.", "Second paragraph."])
        for block in result { guard case .paragraph = block else { Issue.record("not a paragraph: \(block)"); continue } }
    }

    @Test func aWindowsNewlineSeparatesParagraphsToo() {
        let result = blocks("## Fixed\r\n\r\nA crash.\r\n\r\nAnother fix.")
        #expect(result.map(text(of:)) == ["Fixed", "A crash.", "Another fix."])
    }

    /// GitHub shows a single line break in a release's notes as a line break.
    @Test func aLineBreakInsideAParagraphStaysALineBreak() {
        let result = blocks("line one\nline two")
        #expect(result.map(text(of:)) == ["line one\nline two"])
    }

    // MARK: Inline styles

    @Test func boldItalicAndCodeKeepTheirStyle() throws {
        let result = blocks("Some **bold**, *italic* and `code` words.")
        let block = try #require(result.first)
        guard case .paragraph(let paragraph) = block else { Issue.record("not a paragraph"); return }
        #expect(plain(paragraph) == "Some bold, italic and code words.")
        func intent(of word: String) -> InlinePresentationIntent? {
            paragraph.runs.first { plain(AttributedString(paragraph[$0.range])) == word }?.inlinePresentationIntent
        }
        #expect(intent(of: "bold")?.contains(.stronglyEmphasized) == true)
        #expect(intent(of: "italic")?.contains(.emphasized) == true)
        #expect(intent(of: "code")?.contains(.code) == true)
    }

    @Test func blockStructureIsNotLeftOnTheText() {
        let markdown = "## Head\n\n- item\n\n1. one\n\n> quote\n\nPlain **text**."
        for block in blocks(markdown) {
            let carried: AttributedString? = switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, let text): text
            case .codeBlock, .rule: nil
            }
            if let carried {
                #expect(carried.runs.allSatisfy { $0.presentationIntent == nil }, "\(block)")
            }
        }
    }

    // MARK: Lists

    @Test func bulletsAreItemsWithABulletMarker() {
        let result = blocks("- one\n- two\n* three")
        #expect(result.count == 3)
        for (index, block) in result.enumerated() {
            guard case .listItem(let marker, let depth, let text) = block else { Issue.record("not an item: \(block)"); continue }
            #expect(marker == "\u{2022}")
            #expect(depth == 0)
            #expect(plain(text) == ["one", "two", "three"][index])
        }
    }

    @Test func numberedItemsCarryTheirNumbers() {
        let result = blocks("1. first\n2. second\n3. third")
        let markers: [String] = result.compactMap { if case .listItem(let marker, _, _) = $0 { marker } else { nil } }
        #expect(markers == ["1.", "2.", "3."])
    }

    @Test func aListThatStartsAboveOneKeepsItsNumbers() {
        let markers: [String] = blocks("3. third\n4. fourth").compactMap { if case .listItem(let marker, _, _) = $0 { marker } else { nil } }
        #expect(markers == ["3.", "4."])
    }

    @Test func nestedItemsAreDeeper() {
        let result = blocks("- top\n  - nested\n    - deepest\n- top again")
        let shape: [(Int, String)] = result.compactMap {
            if case .listItem(_, let depth, let text) = $0 { (depth, plain(text)) } else { nil }
        }
        #expect(shape.map(\.0) == [0, 1, 2, 0])
        #expect(shape.map(\.1) == ["top", "nested", "deepest", "top again"])
    }

    @Test func aNumberedListInsideABulletUsesItsOwnMarkers() {
        let result = blocks("- top\n  1. one\n  2. two")
        let markers: [String] = result.compactMap { if case .listItem(let marker, _, _) = $0 { marker } else { nil } }
        #expect(markers == ["\u{2022}", "1.", "2."])
    }

    @Test func listItemsKeepTheirInlineStyles() throws {
        let result = blocks("- **Updates** arrive in the app")
        guard case .listItem(_, _, let item)? = result.first else { Issue.record("not an item"); return }
        #expect(plain(item) == "Updates arrive in the app")
        let bold = item.runs.first { plain(AttributedString(item[$0.range])) == "Updates" }
        #expect(bold?.inlinePresentationIntent?.contains(.stronglyEmphasized) == true)
    }

    // MARK: Code, quotes and rules

    @Test func aCodeBlockKeepsItsLinesWithoutTheTrailingNewline() {
        let result = blocks("```\nlet x = 1\nlet y = 2\n```")
        #expect(result == [.codeBlock("let x = 1\nlet y = 2")])
    }

    @Test func aQuoteIsAQuote() {
        let result = blocks("> quoted text")
        guard case .quote(let quote)? = result.first else { Issue.record("not a quote: \(result)"); return }
        #expect(plain(quote) == "quoted text")
    }

    @Test func aThematicBreakIsARule() {
        #expect(blocks("above\n\n---\n\nbelow").map(text(of:)) == ["above", "", "below"])
        #expect(blocks("above\n\n---\n\nbelow")[1] == .rule)
    }

    // MARK: A whole release's notes

    @Test func aTypicalReleaseReadsInOrder() {
        let notes = """
        ## What's new

        - **Updates** now arrive in the app.
        - Check daily, or from the menu.

        ### Fixes

        1. A crash on launch
        2. A slow save

        **Full Changelog**: https://example.com/compare/v1.1.0...v1.2.0
        """
        let result = blocks(notes)
        #expect(result.map(text(of:)) == [
            "What's new", "Updates now arrive in the app.", "Check daily, or from the menu.", "Fixes",
            "A crash on launch", "A slow save",
            "Full Changelog: https://example.com/compare/v1.1.0...v1.2.0",
        ])
    }

    // MARK: Where the notes end

    /// A release's body ends with the manual install steps and the `shasum` commands, which are for someone downloading
    /// by hand and which the update window has no use for: it shows the notes only up to the first `## Install` heading.
    static let releaseBody = """
        ## What's new

        - **Updates** arrive in the app.

        ## Install

        ClearShot needs macOS 27 on Apple Silicon. Download `ClearShot-1.2.0.dmg` below, open it and drag ClearShot to Applications.

        ## Verify the download

        In the folder you downloaded both files to:

            shasum -a 256 -c ClearShot-1.2.0.dmg.sha256

        ## What's Changed
        * Something by @someone in #1
        """

    @Test func theWindowShowsTheNotesUpToTheInstallSection() {
        #expect(blocks(Self.releaseBody).map(text(of:)) == ["What's new", "Updates arrive in the app."])
    }

    @Test func noInstallHeadingShowsTheWholeBody() {
        let notes = "## What's new\n\nA fix.\n\n## Verify the download\n\nA check."
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
        #expect(blocks(notes).map(text(of:)) == ["What's new", "A fix.", "Verify the download", "A check."])
    }

    @Test func theCutIsTheTextBeforeTheHeading() {
        #expect(ReleaseNotes.whatsNew(in: "One.\n\n## Install\n\nTwo.") == "One.\n\n")
        #expect(ReleaseNotes.whatsNew(in: "One.\n## Install") == "One.\n")
    }

    @Test(arguments: ["## Install", "## INSTALL", "## install", "## iNsTaLl", "##   Install  ", "##\tInstall", "## Install ##",
                      "## Install ###  ", " ## Install", "   ## Install"])
    func theInstallHeadingIsFoundWhateverItsCaseAndSpacing(heading: String) {
        #expect(ReleaseNotes.whatsNew(in: "Notes.\n\n\(heading)\n\nSteps.") == "Notes.\n\n")
    }

    /// Only a level-2 heading that says just "Install" ends the notes: another heading, or a line that merely contains
    /// the word, is part of them.
    @Test(arguments: ["## Installation", "## Install notes", "## Installer fixes", "### Install", "# Install", "#### Install",
                      "##Install", "Install", "Run ## Install", "- ## Install", "> ## Install", "    ## Install", "## Not Install",
                      "**## Install**", "## Reinstall"])
    func otherHeadingsAndLinesDoNotEndTheNotes(line: String) {
        let notes = "Notes.\n\n\(line)\n\nMore."
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
    }

    /// A line inside a code block is code, whatever it looks like.
    @Test func anInstallHeadingInACodeBlockIsCode() {
        let notes = "Notes.\n\n```\n## Install\n```\n\nMore.\n\n~~~\n## Install\n~~~\n\nEven more."
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
        #expect(ReleaseNotes.whatsNew(in: notes + "\n\n## Install\n\nSteps.") == notes + "\n\n")
    }

    /// An unclosed code block runs to the end of the notes, as Markdown reads it: nothing in it is a heading.
    @Test func anUnclosedCodeBlockHidesAnInstallHeadingInsideIt() {
        let notes = "Notes.\n\n```\n## Install\n\nmore"
        #expect(ReleaseNotes.whatsNew(in: notes) == notes)
    }

    /// A fence is closed by the same kind of fence, at least as long.
    @Test func aCodeBlockIsClosedByItsOwnKindOfFence() {
        let notes = "```\n~~~\n## Install\n~~~\n```\n\n## Install\n\nSteps."
        #expect(ReleaseNotes.whatsNew(in: notes) == "```\n~~~\n## Install\n~~~\n```\n\n")
        let longer = "````\n```\n## Install\n```\n````\nafter\n## Install\nSteps."
        #expect(ReleaseNotes.whatsNew(in: longer) == "````\n```\n## Install\n```\n````\nafter\n")
    }

    @Test func notesThatStartWithTheInstallSectionHaveNothingToShow() {
        #expect(ReleaseNotes.whatsNew(in: "## Install\n\nSteps.") == "")
        #expect(blocks("## Install\n\nSteps.").isEmpty)
    }

    @Test func aWindowsNewlineDoesNotHideTheHeading() {
        #expect(ReleaseNotes.whatsNew(in: "## What's new\r\n\r\nA fix.\r\n\r\n## Install\r\n\r\nSteps.") == "## What's new\r\n\r\nA fix.\r\n\r\n")
        #expect(blocks("## What's new\r\n\r\nA fix.\r\n\r\n## Install\r\n\r\nSteps.").map(text(of:)) == ["What's new", "A fix."])
    }

    @Test func onlyTheFirstInstallHeadingMatters() {
        #expect(ReleaseNotes.whatsNew(in: "A\n## Install\nB\n## Install\nC") == "A\n")
    }

    @Test func emptyNotesStayEmpty() {
        #expect(ReleaseNotes.whatsNew(in: "") == "")
    }

    /// The size limit counts what is shown, not what was cut off after the Install heading.
    @Test func theSizeLimitAppliesToWhatIsShown() {
        let tail = String(repeating: "- A line of steps that goes on a little.\n", count: 2_000)
        let notes = "## What's new\n\nA fix.\n\n## Install\n\n" + tail
        #expect(notes.count > ReleaseNotes.characterLimit)
        #expect(blocks(notes).map(text(of:)) == ["What's new", "A fix."])
    }

    // MARK: Links

    func links(in markdown: String) -> [URL] {
        blocks(markdown).flatMap { block -> [URL] in
            switch block {
            case .heading(_, let text), .paragraph(let text), .quote(let text), .listItem(_, _, let text):
                text.runs.compactMap(\.link)
            case .codeBlock, .rule: []
            }
        }
    }

    @Test func webLinksStayLinks() {
        #expect(links(in: "See [the notes](https://example.com/notes) and [old](http://example.com/old).")
                == [URL(string: "https://example.com/notes")!, URL(string: "http://example.com/old")!])
    }

    @Test func aBareWebAddressStaysALink() {
        #expect(links(in: "Changelog: https://example.com/compare/a...b") == [URL(string: "https://example.com/compare/a...b")!])
    }

    /// Notes can't make a click open a file, run a script or reach into another app: only web links are links. The words
    /// stay.
    @Test func otherLinksLoseTheirTarget() {
        let markdown = "[a](file:///Applications/Calculator.app) [b](javascript:alert(1)) [c](x-apple.systempreferences:com.apple.preference) [d](mailto:a@example.com) [e](/relative/path) [f](ftp://example.com/x)"
        #expect(links(in: markdown).isEmpty)
        #expect(blocks(markdown).map(text(of:)) == ["a b c d e f"])
    }

    // MARK: Size

    @Test func veryLongNotesAreCutAndSaySo() throws {
        let line = "- A line of release notes that goes on a little.\n"
        let notes = String(repeating: line, count: 2_000)
        #expect(notes.count > ReleaseNotes.characterLimit)
        let result = blocks(notes)
        let characters = result.map { text(of: $0).count }.reduce(0, +)
        #expect(characters <= ReleaseNotes.characterLimit)
        let last = try #require(result.last)
        #expect(text(of: last) == "\u{2026}")
    }

    @Test func notesAtTheLimitAreNotCut() {
        let notes = String(repeating: "a", count: ReleaseNotes.characterLimit)
        let result = blocks(notes)
        #expect(result.count == 1)
        #expect(text(of: result[0]).count == ReleaseNotes.characterLimit)
    }

    // MARK: Odd input

    @Test func oddInputStillGivesBlocksAndNeverCrashes() {
        let inputs = ["\u{0}", "[unclosed link](", "**unclosed bold", "```\nunclosed fence", "<details><summary>x</summary>y</details>",
                      "| a | b |\n|---|---|\n| 1 | 2 |", "![image](https://example.com/i.png)", "\u{1F600} emoji \u{1F1FA}\u{1F1F8}"]
        for input in inputs {
            _ = blocks(input)
        }
        #expect(!blocks("<details><summary>x</summary>y</details>").isEmpty)
        #expect(!blocks("**unclosed bold").isEmpty)
    }
}
