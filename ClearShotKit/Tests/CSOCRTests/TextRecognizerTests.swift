import CoreGraphics
import Foundation
import Testing
@testable import CSOCR

/// Vision on rendered pages. Vision's output changes with the OS, and even with the executable (a rebuilt test binary
/// can read a few lines of a tile differently, or drop them), so these only catch what is badly broken: most lines
/// read, none twice, in order. Exact text across cuts is held by `TileReadingReplayTests`, on captured readings. The
/// first recognition after the test target is rebuilt takes about half a minute while Vision loads its models: slow,
/// not hung.
@Suite(.serialized, .timeLimit(.minutes(3)))
struct TextRecognizerTests {
    private let options = TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US")

    @Test func aPageWithColumnsHyphensALinkAndAQRCodeIsRead() async throws {
        let page = OCRPage(width: 2400, height: 1400)
        let left = ["Text recognition reads every line", "of a page in the order it is laid", "out, and puts back words that",
                    "were split by a hyphen. The", "Infor-", "mation here is joined again."]
        let right = ["The right column comes second.", "Read the documentation at", "https://example.com/docs",
                     "or scan the code below."]
        for (index, line) in left.enumerated() { page.text(line, x: 100, top: 120 + 60 * index) }
        for (index, line) in right.enumerated() { page.text(line, x: 1300, top: 120 + 60 * index) }
        page.qrCode("https://clearshot.test/qr", x: 1300, top: 520)

        let result = try await TextRecognizer.recognize(page.image(), options: options)

        #expect(result.qrPayloads == ["https://clearshot.test/qr"])
        let texts = result.lines.map(\.text)
        #expect(texts.contains("https://example.com/docs"))
        // Every left-column line comes before every right-column line.
        let sides = result.lines.map { $0.box.midX < 1200 }
        #expect(sides.contains(true) && sides.contains(false))
        #expect(sides == sides.sorted { $0 && !$1 })
        let assembled = TextAssembler.text(from: result.lines, keepLineBreaks: false)
        #expect(assembled.contains("Information"))
        // Boxes are in image pixels from the top left.
        let link = try #require(result.lines.first { $0.text == "https://example.com/docs" })
        #expect(abs(link.box.minX - 1300) < 12 && abs(link.box.minY - 240) < 12)
    }

    @Test func aFullScreenSizedCaptureIsTiledAndReadCompletely() async throws {
        let page = OCRPage(width: 6720, height: 3780)
        var count = 0
        for column in 0..<6 {
            for row in 0..<31 {
                count += 1
                page.text("Entry \(count) sample words", x: 60 + 1100 * column, top: 80 + 120 * row)
            }
        }
        #expect(count == 186)

        let result = try await TextRecognizer.recognize(page.image(), options: options)

        let numbers = OCRPage.numbers(in: result.lines.map(\.text)).filter { (1...count).contains($0) }
        #expect(Set(numbers).count >= count * 95 / 100, "read \(Set(numbers).count) of \(count)")
        #expect(numbers.count == Set(numbers).count, "read twice: \(numbers.duplicates())")
        // A tile ending just inside a column sees a sliver of each of its lines; Vision reads those as "E" and the
        // like, and they are dropped rather than copied, alone or in front of the line's real text.
        let slivers = result.lines.map(\.text).filter { $0.firstMatch(of: /\d+/) == nil }
        #expect(slivers.count <= 2, "slivers: \(slivers)")
        let strayStarts = result.lines.map(\.text).filter { $0.contains("Entry") && !$0.hasPrefix("Entry") }
        #expect(strayStarts.count <= 2, "lines with a stray start: \(strayStarts)")
    }

    @Test func aTallScrollingCaptureIsReadOnceAndInOrder() async throws {
        let page = OCRPage(width: 3200, height: 12_000)
        let count = 250
        for number in 1...count {
            page.text("Line \(number) of the tall scrolling page", x: 120, top: 100 + 46 * (number - 1))
        }

        let result = try await TextRecognizer.recognize(page.image(), options: options)

        let numbers = OCRPage.numbers(in: result.lines.map(\.text)).filter { (1...count).contains($0) }
        #expect(Set(numbers).count >= count * 95 / 100, "read \(Set(numbers).count) of \(count)")
        #expect(numbers.count == Set(numbers).count, "read twice: \(numbers.duplicates())")
        #expect(numbers == numbers.sorted(), "out of order: \(numbers)")
    }

    @Test func aLongLineAcrossAColumnCutIsReadWhole() async throws {
        // 2 600 px lines (a 1 300 pt column on a 6K display) cross the cuts near 2 688 and 4 032; each row starts a
        // little further right and with other words, so the cuts fall at every point of a word.
        let page = OCRPage(width: 6720, height: 3780)
        var expected: [Int: [String]] = [:]
        for number in 1...50 {
            let row = OCRPage.row(number, first: number * 3, width: 2600)
            page.text(row.line, x: 2000 + (number * 23) % 200, top: 30 + 70 * number)
            expected[number] = row.words
        }

        let rows = read(try await TextRecognizer.recognize(page.image(), options: options), expected: expected)

        #expect(rows.whole >= 40, "read whole: \(rows.whole) of 50; strays: \(rows.strays)")
        #expect(rows.split.isEmpty, "rows read as more than one line: \(rows.split)")
        #expect(rows.doubled.isEmpty, "a word read twice: \(rows.doubled)")
    }

    @Test func aFullWidthLineIsReadWhole() async throws {
        // The floor of 25 of 50 rows only guards against catastrophe (the bug it guards against read 0 of 50): Vision
        // intermittently drops whole lines inside a tile, and exact seam behaviour is covered by TileReadingReplayTests.
        let page = OCRPage(width: 6720, height: 3780)
        var expected: [Int: [String]] = [:]
        for number in 1...50 {
            let row = OCRPage.row(number, first: number * 5, width: 6560)
            page.text(row.line, x: 40 + (number * 11) % 80, top: 30 + 70 * number)
            expected[number] = row.words
        }

        let rows = read(try await TextRecognizer.recognize(page.image(), options: options), expected: expected)

        #expect(rows.whole >= 25, "read whole: \(rows.whole) of 50; strays: \(rows.strays)")
        #expect(rows.split.isEmpty, "rows read as more than one line: \(rows.split)")
        #expect(rows.doubled.isEmpty, "a word read twice: \(rows.doubled)")
    }

    @Test func noWordIsReadTwiceAcrossACut() async throws {
        // Full-width rows, each shifted 9 px further than the last: over 50 rows the four cuts pass through every
        // part of the words beside them, including words centred on a cut, which both tiles claim. The floor of 25 of
        // 50 rows is low because Vision intermittently drops whole lines inside a tile; exactness is covered by the
        // replay tests (TileReadingReplayTests).
        let page = OCRPage(width: 6720, height: 3780)
        var expected: [Int: [String]] = [:]
        for number in 1...50 {
            let row = OCRPage.row(number, first: number, width: 6200)
            page.text(row.line, x: 40 + 9 * number, top: 30 + 70 * number)
            expected[number] = row.words
        }

        let rows = read(try await TextRecognizer.recognize(page.image(), options: options), expected: expected)

        #expect(rows.doubled.isEmpty, "a word read twice: \(rows.doubled)")
        #expect(rows.tooLong.isEmpty, "more words than drawn: \(rows.tooLong)")
        #expect(rows.whole >= 25, "read whole: \(rows.whole) of 50")
    }

    /// The column cut of a one-row plan for `image`, as the recognizer makes it.
    private func cut(in image: CGImage) -> CGFloat {
        let ink = ColumnInk(image)
        let tiles = OCRTiling.tiles(width: image.width, height: image.height) { ink.counts(rows: $0) }
        return tiles[0].rect.maxX - CGFloat(OCRTiling.horizontalOverlap / 2)
    }

    @Test func aLongPathAcrossACutIsReadWhole() async throws {
        // Terminal lines with a 1 250 px path, each a little further right, so the band's one cut falls at a different
        // character of each path.
        let path = "/Volumes/Work/src/projects/clearshot/ClearShotKit/Sources/CSOCR/OCRTiling.swift:42:13:"
        let pathWidth = OCRPage.width(of: path, size: 24, font: "Menlo")
        let pathStart = OCRPage.width(of: "error: ", size: 24, font: "Menlo")
        #expect(pathWidth > 1200)
        // From x 300 the path reaches more than the overlap past the cut on both sides: neither tile sees it whole.
        // From x 40 it ends before the left tile does, which sees it whole, and Vision, correcting language in that
        // crop, reads its "." as a space in some rows (the right tile reads it, with a space of its own elsewhere).
        for (left, neitherWhole) in [(300, true), (40, false)] {
            let page = OCRPage(width: 2200, height: 400)
            for row in 0..<5 {
                page.text("error: \(path) cannot find it", x: left + 17 * row, top: 40 + 70 * row, size: 24, font: "Menlo")
            }
            let image = page.image()
            let cut = cut(in: image)
            let starts = (0..<5).map { CGFloat(left + 17 * $0) + pathStart }
            #expect(starts.allSatisfy { $0 < cut && cut < $0 + pathWidth }, "cut at \(cut)")
            if neitherWhole {
                #expect(starts.allSatisfy { $0 + 200 < cut && cut + 200 < $0 + pathWidth }, "cut at \(cut)")
            }

            let result = try await TextRecognizer.recognize(image, options: options)

            // Each path line read as one line, its path all there.
            let lines = result.lines.map(\.text).filter { $0.hasPrefix("error:") && $0.hasSuffix("cannot find it") }
            let whole = lines.filter { line in
                let read = line.dropFirst("error:".count).dropLast("cannot find it".count).filter { $0 != " " }
                return OCRPage.editDistance(String(read), path) <= 3
            }
            #expect(whole.count >= 4, "\(result.lines.map(\.text))")
        }
    }

    @Test func largeHeadingsAcrossACutReadExactly() async throws {
        // At 64–72 px the 400 px both tiles read holds only a dozen characters or so.
        let headings = ["Quarterly results exceeded every expectation we set for this year",
                        "Install the update before restarting your computer tonight please"]
        for size in [64, 72] as [CGFloat] {
            for (index, heading) in headings.enumerated() {
                let width = OCRPage.width(of: heading, size: size)
                for x in [60, Int((2600 - width) / 2), Int(2540 - width)] {
                    let page = OCRPage(width: 2600, height: 200)
                    page.text(heading, x: x, top: 40, size: size)

                    let read = try await TextRecognizer.recognize(page.image(), options: options).lines.map(\.text)

                    // One line, no word lost or doubled at the cut (exact text: the replay tests).
                    #expect(read.count == 1 && OCRPage.editDistance(read.first ?? "", heading) <= 4,
                            "heading \(index + 1) at \(Int(size)) px from x \(x): \(read)")
                }
            }
        }
    }

    @Test func aURLAcrossACutKeepsItsLine() async throws {
        let url = "https://github.com/the-author/mac-apps/blob/main/ClearShot/README.md"
        let lines = ["A paragraph of ordinary text runs across the width of the page here,",
                     "Ordinary words come first here \(url) and then more words",
                     "and then the paragraph carries on below it with plain words."]
        let page = OCRPage(width: 2600, height: 340)
        for (index, line) in lines.enumerated() { page.text(line, x: 60, top: 40 + 90 * index, size: 40) }
        let image = page.image()
        let cut = cut(in: image)
        let urlStart = 60 + OCRPage.width(of: "Ordinary words come first here ", size: 40)
        #expect(urlStart + 200 < cut && cut + 200 < urlStart + OCRPage.width(of: url, size: 40), "cut at \(cut)")

        let result = try await TextRecognizer.recognize(image, options: options)

        // The URL's line read as one line, the URL all there.
        let read = result.lines.map(\.text)
        let urlLine = try #require(read.first { $0.hasPrefix("Ordinary words come first here") }, "\(read)")
        #expect(urlLine.hasSuffix("and then more words"), "\(urlLine)")
        let readURL = urlLine.dropFirst("Ordinary words come first here".count).dropLast("and then more words".count).filter { $0 != " " }
        #expect(OCRPage.editDistance(String(readURL), url) <= 3, "URL read as \(readURL)")
    }

    /// The (label, number) of each line reading "<label> <number> …", in the order read.
    private func labelled(_ result: OCRResult) -> [(label: String, number: Int)] {
        result.lines.compactMap { line in
            let words = line.text.split(separator: " ")
            guard words.count >= 2, let number = Int(words[1]) else { return nil }
            return (String(words[0]), number)
        }
    }

    @Test func aTallTwoColumnPageReadsColumnByColumn() async throws {
        // Two columns over three rows of tiles: read band by band, they would interleave.
        let page = OCRPage(width: 3000, height: 4000)
        for number in 1...60 {
            page.text("Left \(number) of the first column", x: 100, top: 60 + 64 * (number - 1))
            page.text("Right \(number) of the second column", x: 1600, top: 60 + 64 * (number - 1))
        }

        let read = labelled(try await TextRecognizer.recognize(page.image(), options: options))

        let left = read.filter { $0.label == "Left" }.map(\.number)
        let right = read.filter { $0.label == "Right" }.map(\.number)
        #expect(left.count >= 48 && right.count >= 48, "left \(left.count), right \(right.count)")
        #expect(read.map(\.label) == read.map(\.label).sorted(), "columns interleave: \(read.map { "\($0.label)\($0.number)" })")
        #expect(left == left.sorted() && right == right.sorted())
    }

    @Test func aSidebarAndContentReadSeparately() async throws {
        // A sidebar of short items beside content lines at another spacing, on a 6K page cut into 3 × 5 tiles.
        let page = OCRPage(width: 6720, height: 3780)
        for number in 1...40 { page.text("Sidebar \(number)", x: 60, top: 60 + 90 * (number - 1)) }
        for number in 1...60 {
            page.text("Content \(number) reads across the main area of the window here", x: 900, top: 60 + 60 * (number - 1))
        }

        let read = labelled(try await TextRecognizer.recognize(page.image(), options: options))

        let sidebar = read.filter { $0.label == "Sidebar" }.map(\.number)
        let content = read.filter { $0.label == "Content" }.map(\.number)
        #expect(sidebar.count >= 32 && content.count >= 48, "sidebar \(sidebar.count), content \(content.count)")
        #expect(read.map(\.label) == read.map(\.label).sorted { $0 == "Sidebar" && $1 != "Sidebar" },
                "sidebar and content interleave: \(read.map { "\($0.label)\($0.number)" })")
        #expect(sidebar == sidebar.sorted() && content == content.sorted())
        #expect(Set(content).count == content.count, "content lines read in pieces or twice")
    }

    @Test func aPageWithoutGuttersKeepsRowOrder() async throws {
        // A form: labels and values in two columns, with a heading reaching across both every fourth row, so no gutter
        // runs the height of the page. It is read row by row.
        let page = OCRPage(width: 3000, height: 4000)
        var drawn: [String] = []
        for number in 1...40 {
            let top = 60 + 90 * (number - 1)
            if number % 4 == 1 {
                page.text("Section \(number) heading runs from the labels across to the values", x: 100, top: top)
                drawn.append("Section\(number)")
            } else {
                page.text("Name \(number)", x: 100, top: top)
                page.text("Value \(number)", x: 600, top: top)
                drawn += ["Name\(number)", "Value\(number)"]
            }
        }

        let read = labelled(try await TextRecognizer.recognize(page.image(), options: options)).map { "\($0.label)\($0.number)" }

        #expect(read.count >= drawn.count * 80 / 100, "read \(read.count) of \(drawn.count)")
        let order = read.compactMap { drawn.firstIndex(of: $0) }
        #expect(order == order.sorted(), "out of row order: \(read)")
    }

    /// What became of rows drawn as "Row <n> <words>": how many came out as exactly one line with their words in
    /// order (at most one misread), the lines with a word twice or more words than drawn, the lines that aren't a
    /// row's start (left-over pieces), and the rows that start more than one line.
    private func read(_ result: OCRResult, expected: [Int: [String]])
        -> (whole: Int, doubled: [String], tooLong: [String], strays: [String], split: [Int]) {
        var lines: [Int: [[String]]] = [:]
        var doubled: [String] = [], tooLong: [String] = [], strays: [String] = []
        for line in result.lines {
            let tokens = line.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2, tokens[0] == "row", let number = Int(tokens[1]), let drawn = expected[number] else {
                strays.append(line.text)
                continue
            }
            let words = Array(tokens.dropFirst(2))
            lines[number, default: []].append(words)
            if Set(words).count < words.count { doubled.append(line.text) }
            if words.count > drawn.count { tooLong.append(line.text) }
        }
        let whole = expected.filter { number, drawn in
            guard let read = lines[number], read.count == 1 else { return false }
            return read[0].count <= drawn.count && commonSubsequence(read[0], drawn) >= drawn.count - 1
        }.count
        return (whole, doubled, tooLong, strays, lines.filter { $0.value.count > 1 }.map(\.key).sorted())
    }

    private func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [0]
            for (index, y) in b.enumerated() {
                current.append(x == y ? previous[index] + 1 : max(previous[index + 1], current[index]))
            }
            previous = current
        }
        return previous[b.count]
    }

    @Test func aBlankImageGivesNothing() async throws {
        let result = try await TextRecognizer.recognize(OCRPage(width: 1200, height: 800).image(), options: options)
        #expect(result.isEmpty)
        #expect(TextOutput.text(for: result, keepLineBreaks: true).isEmpty)
    }

    @Test func languagesComeFromVision() {
        let languages = TextRecognizer.supportedLanguages()
        #expect(languages.count >= 28)
        #expect(languages.contains(Locale.Language(identifier: "en-US")))
    }

    @Test func columnInkCountsTextOnLightAndDarkBackgrounds() {
        for (background, ink) in [(OCRPage.white, OCRPage.black), (OCRPage.black, OCRPage.white)] {
            let page = OCRPage(width: 3000, height: 400, background: background)
            page.text("Some words on the left", x: 100, top: 100, color: ink)
            page.text("And more on the right", x: 2200, top: 300, color: ink)
            let columns = ColumnInk(page.image())

            let all = columns.counts(rows: 0..<400)
            #expect(all.count == 3000)
            #expect(all[1000..<2000].allSatisfy { $0 == 0 })
            #expect(all[150..<250].contains { $0 > 0 })
            #expect(all[2250..<2350].contains { $0 > 0 })
            // Only the rows asked about count: the right-hand line is below these.
            let top = columns.counts(rows: 0..<200)
            #expect(top[2200..<2600].allSatisfy { $0 == 0 })
            #expect(top[150..<250].contains { $0 > 0 })
        }
    }
}

private extension Array where Element: Hashable {
    func duplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { !seen.insert($0).inserted }
    }
}
