import CoreGraphics
import CSOCR
import CSTestSupport
import Foundation
import Testing
@testable import CSSensitive

/// How the scanner turns OCR's lines, with the boxes Vision gave for the stretches worth looking at, into findings in image
/// pixels. The lines here are written by hand, as `TextRecognizer` returns them, so these run on any Mac, Vision or not
/// (the scanner on rendered images is in `SensitiveScannerTests`).
struct SensitiveScannerAssemblyTests {
    private let imageSize = CGSize(width: 3000, height: 2000)
    /// Each character of every line here is 10 px wide and 30 px tall.
    private let charWidth: CGFloat = 10

    /// A line of `text` from (`x`, `y`), with a mark for each stretch in `marked`: the stretch's box, laid out at 10 px a
    /// character as the line is, and the tag of its kind (as the scanner asks Vision to give them).
    private func line(_ text: String, x: CGFloat = 40, y: CGFloat = 100, marking marked: [(String, SensitiveKind)] = [],
                      offset: CGFloat = 0) -> OCRLine {
        let box = CGRect(x: x, y: y, width: charWidth * CGFloat(text.count), height: 30)
        let marks = marked.map { span, kind in
            let range = text.range(of: span)!
            let start = CGFloat(text.distance(from: text.startIndex, to: range.lowerBound))
            return OCRMark(text: span, box: CGRect(x: x + start * charWidth + offset, y: y, width: charWidth * CGFloat(span.count), height: 30),
                           tag: SensitiveScanner.tag(of: kind))
        }
        return OCRLine(text: text, box: box, marks: marks)
    }

    private func scan(_ lines: [OCRLine], _ kinds: SensitiveKinds = .all,
                      locate: (OCRLine, String, CGRect) async throws -> CGRect? = { _, _, _ in nil }) async throws -> [ImageFinding] {
        try await SensitiveScanner.findings(from: lines, kinds: kinds, imageSize: imageSize, locate: locate)
    }

    /// The one finding in `found`: a failure if there are none, or more.
    private func only(_ found: [ImageFinding], sourceLocation: SourceLocation = #_sourceLocation) throws -> ImageFinding {
        try #require(found.count == 1 ? found.first : nil, "\(found)", sourceLocation: sourceLocation)
    }

    private let email = "jane@example.com"
    private var token: String { Fake.github() }
    private let card = "4242 4242 4242 4242"

    // MARK: Boxes

    @Test func aFindingTakesTheBoxVisionGaveForItsText() async throws {
        let read = line("mail me at \(email) today", marking: [(email, .contact)])
        let found = try await scan([read])
        #expect(found == [ImageFinding(kind: .contact, rect: read.marks[0].box)])
    }

    @Test func everyKindIsFoundWithItsOwnBox() async throws {
        let lines = [line("mail \(email)", y: 100, marking: [(email, .contact)]),
                     line("key \(token) end", y: 200, marking: [(token, .keyOrToken)]),
                     line("card \(card)", y: 300, marking: [(card, .card)]),
                     line("host 10.0.0.5 up", y: 400, marking: [("10.0.0.5", .ipAddress)])]
        let found = try await scan(lines)
        #expect(found.map(\.kind) == [.contact, .keyOrToken, .card, .ipAddress])
        #expect(found.map(\.rect) == lines.map { $0.marks[0].box })
    }

    @Test func theKindsAskedForAreTheOnlyOnesFound() async throws {
        let lines = [line("mail \(email)", y: 100, marking: [(email, .contact)]),
                     line("key \(token) end", y: 200, marking: [(token, .keyOrToken)]),
                     line("card \(card)", y: 300, marking: [(card, .card)])]
        #expect(try await scan(lines, .contact).map(\.kind) == [.contact])
        #expect(try await scan(lines, [.cards, .keysAndTokens]).map(\.kind) == [.keyOrToken, .card])
        #expect(try await scan(lines, []).isEmpty)
    }

    @Test func aLineWithNothingSensitiveGivesNothing() async throws {
        #expect(try await scan([line("just some words in a line"), line("and 12 more of them here")]).isEmpty)
        #expect(try await scan([]).isEmpty)
    }

    @Test func twoFindingsOfTheSameTextTakeTheirOwnBoxes() async throws {
        let text = "\(email) and \(email)"
        let first = OCRMark(text: email, box: CGRect(x: 40, y: 100, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let second = OCRMark(text: email, box: CGRect(x: 240, y: 100, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 360, height: 30), marks: [second, first])
        let found = try await scan([read])
        #expect(found.map(\.rect) == [first.box, second.box])
    }

    @Test func aBoxForOneOfTwoFindingsOfTheSameTextIsNotTakenForTheOther() async throws {
        // Vision boxed only the second address. The first is located on its own, not given the second's box.
        let text = "\(email) and \(email)"
        let second = OCRMark(text: email, box: CGRect(x: 240, y: 100, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 360, height: 30), marks: [second])
        let firstBox = CGRect(x: 41, y: 101, width: 158, height: 28)
        var asked: [String] = []
        let found = try await scan([read]) { _, text, estimate in
            asked.append(text)
            return estimate.midX < 200 ? firstBox : nil
        }
        #expect(asked == [email])
        #expect(found.map(\.rect) == [firstBox, second.box])
    }

    @Test func twoReadingsOfOneFindingAreNotTakenForTwoFindings() async throws {
        // Two tiles boxed the second address, a few pixels apart, and none the first. Two boxes are one place, not two: the first
        // is located on its own.
        let text = "\(email) and \(email)"
        let tag = SensitiveScanner.tag(of: .contact)
        let a = OCRMark(text: email, box: CGRect(x: 240, y: 100, width: 160, height: 30), tag: tag)
        let b = OCRMark(text: email, box: CGRect(x: 241.5, y: 99, width: 160, height: 30), tag: tag)
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 360, height: 30), marks: [a, b])
        let firstBox = CGRect(x: 41, y: 101, width: 158, height: 28)
        var asked: [String] = []
        let found = try await scan([read]) { _, text, estimate in
            asked.append(text)
            return estimate.midX < 200 ? firstBox : nil
        }
        #expect(asked == [email])
        #expect(found.map(\.rect) == [firstBox, a.box.union(b.box)])
    }

    @Test func eachOfTwoFindingsOfTheSameTextTakesAPlaceWhenBothAreBoxedTwice() async throws {
        let text = "\(email) and \(email)"
        let tag = SensitiveScanner.tag(of: .contact)
        func mark(_ x: CGFloat, _ dx: CGFloat) -> OCRMark {
            OCRMark(text: email, box: CGRect(x: x + dx, y: 100, width: 160, height: 30), tag: tag)
        }
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 360, height: 30),
                           marks: [mark(240, 2), mark(40, 0), mark(240, 0), mark(40, 3)])
        var asked = 0
        let found = try await scan([read]) { _, _, _ in
            asked += 1
            return nil
        }
        #expect(asked == 0)
        #expect(found.map(\.rect) == [mark(40, 0).box.union(mark(40, 3).box), mark(240, 0).box.union(mark(240, 2).box)])
    }

    /// A line of `count` copies of the address, " and " between them, with a mark only for the copies at the places in `boxed`;
    /// `boxes` are where each copy is, at 10 px a character.
    private func repeatedAddresses(_ count: Int, boxed: [Int]) -> (line: OCRLine, boxes: [CGRect]) {
        let text = Array(repeating: email, count: count).joined(separator: " and ")
        let step = CGFloat(email.count + 5) * charWidth
        let boxes = (0..<count).map { CGRect(x: 40 + CGFloat($0) * step, y: 100, width: CGFloat(email.count) * charWidth, height: 30) }
        let marks = boxed.map { OCRMark(text: email, box: boxes[$0], tag: SensitiveScanner.tag(of: .contact)) }
        return (OCRLine(text: text, box: CGRect(x: 40, y: 100, width: charWidth * CGFloat(text.count), height: 30), marks: marks), boxes)
    }

    struct RepeatedCase: Sendable, CustomTestStringConvertible {
        let copies: Int
        let boxed: [Int]
        var testDescription: String { "\(copies) copies, boxed \(boxed)" }
    }

    /// Two to three copies on a line, each way of boxing some of them but not all: the copies with no box are the ones asked
    /// about, each copy ends up with its own box, and none takes the place of another.
    static let repeatedCases = [
        RepeatedCase(copies: 2, boxed: [0]), RepeatedCase(copies: 2, boxed: [1]),
        RepeatedCase(copies: 3, boxed: [0]), RepeatedCase(copies: 3, boxed: [1]), RepeatedCase(copies: 3, boxed: [2]),
        RepeatedCase(copies: 3, boxed: [0, 1]), RepeatedCase(copies: 3, boxed: [0, 2]), RepeatedCase(copies: 3, boxed: [1, 2]),
        RepeatedCase(copies: 3, boxed: [2, 0]),
    ]

    @Test(arguments: repeatedCases)
    func everyCopyOfARepeatedFindingGetsItsOwnBoxWhenOnlySomeWereBoxed(_ shape: RepeatedCase) async throws {
        let (read, boxes) = repeatedAddresses(shape.copies, boxed: shape.boxed)
        var asked = 0
        // What a re-read gives: the box of the copy nearest to the estimate.
        let found = try await scan([read]) { _, _, estimate in
            asked += 1
            return boxes.min { abs($0.midX - estimate.midX) < abs($1.midX - estimate.midX) }
        }
        #expect(found.map(\.rect) == boxes)
        #expect(asked == shape.copies - shape.boxed.count)
    }

    @Test(arguments: repeatedCases)
    func everyCopyOfARepeatedFindingIsCoveredWhenOnlySomeWereBoxedAndNoneCanBeLocated(_ shape: RepeatedCase) async throws {
        // The copies with no box are given the span of the copies (`spanning`): none is left bare under another's box, and the
        // boxes Vision gave are covered too.
        let (read, boxes) = repeatedAddresses(shape.copies, boxed: shape.boxed)
        let found = try await scan([read])
        for (index, box) in boxes.enumerated() {
            #expect(found.contains { $0.rect.contains(box) }, "copy \(index) at \(box) is under none of \(found.map(\.rect))")
        }
        // The span reaches from the first of the copies' estimates and boxes to the last, and no further than the line.
        let estimates = read.text.ranges(of: email).map { SensitiveScanner.estimatedBox(of: $0, in: read) }
        let span = (estimates + shape.boxed.map { boxes[$0] }).reduce(CGRect.null) { $0.union($1) }
        #expect(found.map(\.rect) == [span])
    }

    @Test func aPlaceGoesToTheFindingNearestItNotTheFirstOneWaiting() async throws {
        // Two copies, the place between them nearer the second: the second takes it, the first is located.
        let text = "\(email) and \(email)"
        let second = OCRMark(text: email, box: CGRect(x: 230, y: 100, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 360, height: 30), marks: [second])
        let firstBox = CGRect(x: 41, y: 101, width: 158, height: 28)
        var asked: [CGFloat] = []
        let found = try await scan([read]) { _, _, estimate in
            asked.append(estimate.midX)
            return firstBox
        }
        #expect(asked.count == 1 && asked[0] < 200)
        #expect(found.map(\.rect) == [firstBox, second.box])
    }

    /// What a re-read gets wrong when it can't see the copy it was asked for: the box of another copy. `answers` is, for each
    /// call in reading order, the copy whose box it returns (or nil for none); `boxed` are the copies Vision boxed whole.
    struct WrongRereadCase: Sendable, CustomTestStringConvertible {
        let copies: Int
        let boxed: [Int]
        let answers: [Int?]
        var testDescription: String { "\(copies) copies, boxed \(boxed), the re-reads give copies \(answers)" }
    }

    static let wrongRereadCases = [
        // The re-read for the second copy gives the first copy's box, with nothing boxed or with the first boxed.
        WrongRereadCase(copies: 2, boxed: [], answers: [0, 0]),
        WrongRereadCase(copies: 2, boxed: [0], answers: [0]),
        // The re-read for the first gives the second's box (the second's own is right): the second keeps it.
        WrongRereadCase(copies: 2, boxed: [], answers: [1, 1]),
        // Three copies: the unpaired ones all given the paired copy's box, or the middle copy's.
        WrongRereadCase(copies: 3, boxed: [0], answers: [0, 0]),
        WrongRereadCase(copies: 3, boxed: [2], answers: [2, 2]),
        WrongRereadCase(copies: 3, boxed: [], answers: [1, 1, 1]),
        WrongRereadCase(copies: 3, boxed: [], answers: [0, 0, 0]),
        WrongRereadCase(copies: 3, boxed: [1], answers: [1, 1]),
    ]

    @Test(arguments: wrongRereadCases)
    func aRereadThatGivesAnotherCopysBoxIsNotTakenForTheCopy(_ shape: WrongRereadCase) async throws {
        let (read, boxes) = repeatedAddresses(shape.copies, boxed: shape.boxed)
        var calls = 0
        let found = try await scan([read]) { _, _, _ in
            defer { calls += 1 }
            return shape.answers[calls].map { boxes[$0] }
        }
        #expect(calls == shape.answers.count)
        // The copy whose re-read was another's box has no box of its own, so it takes the span of the copies: every copy is under a
        // mask, not left bare under a box that is another's.
        for (index, box) in boxes.enumerated() {
            #expect(found.contains { $0.rect.contains(box) }, "copy \(index) at \(box) is under none of \(found.map(\.rect))")
        }
    }

    @Test func aFindingWhoseRereadWasDiscardedTakesTheSpanOfTheCopies() async throws {
        // The re-read for the second copy gives the first's box: the second has no box of its own, so it takes the span over
        // both copies' estimates and the box that stands.
        let (read, boxes) = repeatedAddresses(2, boxed: [])
        let estimates = read.text.ranges(of: email).map { SensitiveScanner.estimatedBox(of: $0, in: read) }
        let found = try await scan([read]) { _, _, _ in boxes[0] }
        #expect(found.map(\.rect) == [estimates[0].union(estimates[1]).union(boxes[0])])
        #expect(found.allSatisfy { $0.rect.contains(boxes[0]) && $0.rect.contains(boxes[1]) })
    }

    @Test func aRereadThatGivesTheOwnBoxIsStillTaken() async throws {
        // Nothing is boxed and each re-read finds its own copy: the guard doesn't touch it.
        let (read, boxes) = repeatedAddresses(3, boxed: [])
        let found = try await scan([read]) { _, _, estimate in
            boxes.min { abs($0.midX - estimate.midX) < abs($1.midX - estimate.midX) }
        }
        #expect(found.map(\.rect) == boxes)
    }

    // MARK: A copy of a repeated secret that nothing boxed

    /// A line of `count` cards, " and " between them, in equal-width text (10 px a character), with a mark only for the cards
    /// at the places in `boxed`; `boxes` are where each card is.
    private func repeatedCards(_ count: Int, boxed: [Int]) -> (line: OCRLine, boxes: [CGRect]) {
        let text = Array(repeating: card, count: count).joined(separator: " and ")
        let step = CGFloat(card.count + 5) * charWidth
        let boxes = (0..<count).map { CGRect(x: 40 + CGFloat($0) * step, y: 100, width: CGFloat(card.count) * charWidth, height: 30) }
        let marks = boxed.map { OCRMark(text: card, box: boxes[$0], tag: SensitiveScanner.tag(of: .card)) }
        return (OCRLine(text: text, box: CGRect(x: 40, y: 100, width: charWidth * CGFloat(text.count), height: 30), marks: marks), boxes)
    }

    /// "Owner:" and then, 300 px on, `count` cards (10 px a character, " and " between them). The characters are not spread evenly
    /// along such a line, so a card's estimate is where an even spread puts it, which is not where the card is.
    private func gappedCards(_ count: Int, boxed: [Int]) -> (line: OCRLine, boxes: [CGRect]) {
        let text = "Owner: " + Array(repeating: card, count: count).joined(separator: " and ")
        let width = CGFloat(card.count) * charWidth
        let boxes = (0..<count).map { CGRect(x: 40 + 7 * charWidth + 300 + CGFloat($0) * (width + 5 * charWidth), y: 100, width: width, height: 30) }
        let marks = boxed.map { OCRMark(text: card, box: boxes[$0], tag: SensitiveScanner.tag(of: .card)) }
        let box = CGRect(x: 40, y: 100, width: boxes[count - 1].maxX - 40, height: 30)
        return (OCRLine(text: text, box: box, marks: marks), boxes)
    }

    struct GappedCase: Sendable, CustomTestStringConvertible {
        let copies: Int
        let boxed: [Int]
        var testDescription: String { "\(copies) cards after a gap, boxed \(boxed)" }
    }

    static let gappedCases = [
        GappedCase(copies: 2, boxed: [0]), GappedCase(copies: 2, boxed: [1]),
        GappedCase(copies: 3, boxed: [0]), GappedCase(copies: 3, boxed: [1]), GappedCase(copies: 3, boxed: [2]),
        GappedCase(copies: 3, boxed: [0, 2]),
    ]

    /// The place Vision boxed goes to the card whose estimate is nearest it, and with a gap in the line that can be the
    /// other card. The card left with no place has an estimate that is nowhere near it, so it takes the span of the copies
    /// instead: every card is under some mask, the words between them too.
    @Test(arguments: gappedCases)
    func everyCardOfARepeatedCardIsMaskedWhenTheLinesCharactersAreNotSpreadEvenly(_ shape: GappedCase) async throws {
        let (read, boxes) = gappedCards(shape.copies, boxed: shape.boxed)
        let found = try await scan([read])
        for (index, box) in boxes.enumerated() {
            #expect(found.contains { $0.rect.contains(box) }, "card \(index) at \(box) is under none of \(found.map(\.rect))")
        }
        // Nothing is masked beyond the line.
        for finding in found { #expect(read.box.contains(finding.rect), "\(finding.rect)") }
    }

    /// The first card's re-read gives the second card's box, which stands because nothing contradicts it; the second card's
    /// re-read gives nothing. The first card is under no mask of its own, so the second takes the span over both.
    @Test func aRereadThatGaveAnotherCardsBoxLeavesNoCardUnmasked() async throws {
        let (read, boxes) = repeatedCards(2, boxed: [])
        var answers: [CGRect?] = [boxes[1], nil]
        let found = try await scan([read]) { _, _, _ in answers.removeFirst() }
        for (index, box) in boxes.enumerated() {
            #expect(found.contains { $0.rect.contains(box) }, "card \(index) at \(box) is under none of \(found.map(\.rect))")
        }
    }

    /// When every copy has a box (a place, or a re-read that stands), each keeps exactly that box: no span, no widening.
    @Test func copiesThatAllHaveABoxKeepExactlyIt() async throws {
        let (both, boxes) = repeatedCards(2, boxed: [0, 1])
        #expect(try await scan([both]).map(\.rect) == boxes)
        let (one, sameBoxes) = repeatedCards(2, boxed: [0])
        let found = try await scan([one]) { _, _, estimate in
            sameBoxes.min { abs($0.midX - estimate.midX) < abs($1.midX - estimate.midX) }
        }
        #expect(found.map(\.rect) == sameBoxes)
        let (none, threeBoxes) = repeatedCards(3, boxed: [])
        let located = try await scan([none]) { _, _, estimate in
            threeBoxes.min { abs($0.midX - estimate.midX) < abs($1.midX - estimate.midX) }
        }
        #expect(located.map(\.rect) == threeBoxes)
    }

    /// The span is for copies of one text. A finding of another text on the line keeps the box Vision gave it, and the span of
    /// the cards begins where the cards' estimates do.
    @Test func aFindingOfAnotherTextOnTheLineIsNotGivenTheSpan() async throws {
        let text = "\(email) and \(card) and \(card)"
        let read = line(text, marking: [(email, .contact)])
        let found = try await scan([read])
        let estimates = text.ranges(of: card).map { SensitiveScanner.estimatedBox(of: $0, in: read) }
        #expect(found.filter { $0.kind == .contact }.map(\.rect) == [read.marks[0].box])
        #expect(found.filter { $0.kind == .card }.map(\.rect) == [estimates[0].union(estimates[1])])
        #expect(!read.marks[0].box.intersects(estimates[0]))
    }

    @Test func aBoxWithNoAreaIsNeverTakenForAFindingsBox() async throws {
        // A box with no width (or none at all) would mask nothing, and a finding left with it would be dropped: the finding keeps its
        // estimate, whether the box came from Vision or from locating it again.
        let text = "write to \(email) for details"
        let flat = OCRMark(text: email, box: CGRect(x: 130, y: 100, width: 0, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let marked = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 370, height: 30), marks: [flat])
        let unmarked = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 370, height: 30))
        let range = try #require(text.range(of: email))
        let estimate = SensitiveScanner.estimatedBox(of: range, in: unmarked)
        #expect(try await scan([marked]).map(\.rect) == [estimate])
        for empty in [CGRect(x: 130, y: 100, width: 0, height: 30), CGRect(x: 130, y: 100, width: 160, height: 0), CGRect.null] {
            #expect(try await scan([unmarked]) { _, _, _ in empty }.map(\.rect) == [estimate], "\(empty)")
        }
    }

    @Test func findingsComeInReadingOrderAcrossLines() async throws {
        let lines = [line("a \(email) b", y: 100, marking: [(email, .contact)]),
                     line("c \(card) d \(email)", y: 200, marking: [(card, .card), (email, .contact)]),
                     line("e \(token)", y: 300, marking: [(token, .keyOrToken)])]
        #expect(try await scan(lines).map(\.kind) == [.contact, .card, .contact, .keyOrToken])
    }

    // MARK: A finding Vision gave no box for

    @Test func aFindingWithNoBoxIsEstimatedAcrossTheLine() async throws {
        // Ten pixels a character: the address lies at 41 characters in, 16 long, in a 70-character line.
        let text = "some words come before the address that follows: \(email) and some after"
        let read = line(text)
        let found = try await scan([read])
        let finding = try only(found)
        #expect(finding.kind == .contact)
        let start = read.box.minX + charWidth * CGFloat(text.distance(from: text.startIndex, to: text.range(of: email)!.lowerBound))
        let rect = finding.rect
        // It covers the address, a few characters more on each side at most, and is as tall as the line.
        #expect(rect.minX <= start && rect.maxX >= start + charWidth * 16)
        #expect(rect.minX >= start - 5 * charWidth && rect.maxX <= start + charWidth * 21)
        #expect(rect.minY == read.box.minY && rect.height == read.box.height)
    }

    @Test func theEstimateStaysInsideTheLine() async throws {
        let read = line(email)
        #expect(try await scan([read]).map(\.rect) == [read.box])
        let atTheEnd = line("write to \(email)")
        let rect = try #require(try await scan([atTheEnd]).first?.rect)
        #expect(rect.maxX == atTheEnd.box.maxX && rect.minX > atTheEnd.box.minX)
    }

    @Test func aFindingWithNoBoxIsLocatedAgainByTheCaller() async throws {
        let text = "write to \(email) for details"
        let read = line(text)
        let exact = CGRect(x: 131, y: 101, width: 158, height: 28)
        var asked: [(String, String, CGRect)] = []
        let found = try await scan([read]) { line, found, estimate in
            asked.append((line.text, found, estimate))
            return exact
        }
        #expect(found == [ImageFinding(kind: .contact, rect: exact)])
        let call = try #require(asked.first)
        #expect(asked.count == 1 && call.0 == text && call.1 == email)
        // The caller is given the estimate to search around.
        #expect(call.2.minX <= 130 && call.2.maxX >= 290 && call.2.minY == 100)
    }

    @Test func aFindingWithABoxIsNotLocatedAgain() async throws {
        let read = line("write to \(email) for details", marking: [(email, .contact)])
        var asked = 0
        _ = try await scan([read]) { _, _, _ in
            asked += 1
            return nil
        }
        #expect(asked == 0)
    }

    @Test func aCallerThatCannotLocateItLeavesTheEstimate() async throws {
        let read = line("write to \(email) for details")
        let located = try await scan([read]) { _, _, _ in nil }
        let estimated = try await scan([read])
        #expect(located == estimated && located.count == 1)
    }

    @Test func aMarkOfOtherTextIsNotTakenForTheFinding() async throws {
        // Vision boxed "jane@example.co" (cut off by a tile's edge): the finding in the whole line isn't that text.
        let text = "write to \(email) for details"
        let cut = OCRMark(text: "jane@example.co", box: CGRect(x: 130, y: 100, width: 150, height: 30),
                          tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 370, height: 30), marks: [cut])
        var asked = 0
        let found = try await scan([read]) { _, _, _ in
            asked += 1
            return nil
        }
        #expect(asked == 1)
        // The estimate covers the whole address, and the cut-off mark lies inside it: one finding.
        #expect(try only(found).rect.contains(cut.box))
    }

    // MARK: Two readings of one line

    @Test func theSameFindingReadByTwoTilesIsOne() async throws {
        let first = line("write to \(email) for details", marking: [(email, .contact)])
        var second = first
        second.marks = [OCRMark(text: email, box: first.marks[0].box.offsetBy(dx: 1.5, dy: -1), tag: SensitiveScanner.tag(of: .contact))]
        // The line put together from both readings lists both marks.
        let stitched = OCRLine(text: first.text, box: first.box, marks: first.marks + second.marks)
        let finding = try only(try await scan([stitched]))
        #expect(finding.rect.contains(first.marks[0].box) && finding.rect.contains(second.marks[0].box))
    }

    @Test func theSameLineReadByTwoRowsOfTilesIsOne() async throws {
        let a = line("write to \(email) for details", y: 1500, marking: [(email, .contact)])
        let b = line("write to \(email) for details", y: 1503, marking: [(email, .contact)])
        let finding = try only(try await scan([a, b]))
        #expect(finding.rect == a.marks[0].box.union(b.marks[0].box))
    }

    @Test func aSecretCutByATilesEdgeIsFoundWholeAndTheCutPartIsNotAnotherFinding() async throws {
        // The left tile read "ghp_…" only as far as its edge, the right tile only from the middle of it; the merged line has
        // it all, and no mark has all its text. The caller (the scanner) reads that stretch again and boxes it.
        let secret = token
        let text = "key \(secret) end"
        let half = secret.count / 2
        let kind = SensitiveScanner.tag(of: .keyOrToken)
        let leftPart = OCRMark(text: String(secret.prefix(half + 8)), box: CGRect(x: 80, y: 100, width: 10 * CGFloat(half + 8), height: 30), tag: kind)
        let rightPart = OCRMark(text: String(secret.suffix(half)), box: CGRect(x: 80 + 10 * CGFloat(half), y: 100, width: 10 * CGFloat(half), height: 30), tag: kind)
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 10 * CGFloat(text.count), height: 30), marks: [leftPart, rightPart])
        let exact = CGRect(x: 80, y: 100, width: 10 * CGFloat(secret.count), height: 30)
        let found = try await scan([read]) { _, _, _ in exact }
        #expect(found == [ImageFinding(kind: .keyOrToken, rect: exact)])
    }

    @Test func aMarkOfTheCutPieceWithNothingOverItIsStillAFinding() async throws {
        // Text a tile read that the merged line doesn't hold (stitching changed it): a mark with no finding in the line text.
        let read = OCRLine(text: "nothing to see here at all", box: CGRect(x: 40, y: 100, width: 260, height: 30),
                           marks: [OCRMark(text: email, box: CGRect(x: 100, y: 100, width: 160, height: 30),
                                           tag: SensitiveScanner.tag(of: .contact))])
        #expect(try await scan([read]) == [ImageFinding(kind: .contact, rect: CGRect(x: 100, y: 100, width: 160, height: 30))])
    }

    @Test func aCutPartOfAnotherKindOverAFindingIsNotAnotherFinding() async throws {
        // A tile read part of the token and the detector took it for a phone number: it lies over the token, which is the finding.
        let text = "key \(token) end"
        let whole = OCRMark(text: token, box: CGRect(x: 80, y: 100, width: 400, height: 30), tag: SensitiveScanner.tag(of: .keyOrToken))
        let part = OCRMark(text: "23456789", box: CGRect(x: 300, y: 100, width: 80, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 10 * CGFloat(text.count), height: 30), marks: [whole, part])
        #expect(try await scan([read]) == [ImageFinding(kind: .keyOrToken, rect: whole.box)])
    }

    @Test func aCutPartOfTheFindingThatSticksOutOfItsBoxIsCoveredToo() async throws {
        // Anything a tile boxed is covered: a tile's cut reading of the token, boxed a few pixels wider than the whole one, adds
        // its box to the finding's (the kinds the detector gave the two readings differ here, which doesn't matter).
        let text = "key \(token) end"
        let whole = OCRMark(text: token, box: CGRect(x: 80, y: 100, width: 400, height: 30), tag: SensitiveScanner.tag(of: .keyOrToken))
        let part = OCRMark(text: String(token.prefix(30)), box: CGRect(x: 70, y: 98, width: 300, height: 32),
                           tag: SensitiveScanner.tag(of: .keyOrToken))
        let other = OCRMark(text: "23456789", box: CGRect(x: 440, y: 100, width: 80, height: 30), tag: SensitiveScanner.tag(of: .contact))
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 10 * CGFloat(text.count), height: 30), marks: [whole, part, other])
        #expect(try await scan([read]) == [ImageFinding(kind: .keyOrToken, rect: whole.box.union(part.box).union(other.box))])
    }

    @Test func aMarkOfTheFullTextAtATilesInnerEdgeIsLocatedAgain() async throws {
        // Vision boxed the whole text, but its box ends at the tile's inner edge: the line may go on past the edge (isCut). It is
        // not taken as the finding's box; the finding is located again, and the mark's box is still covered.
        let text = "write to \(email) for details"
        let cut = OCRMark(text: email, box: CGRect(x: 130, y: 100, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact), isCut: true)
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 370, height: 30), marks: [cut])
        let exact = CGRect(x: 131, y: 101, width: 175, height: 28)
        var asked = 0
        let found = try await scan([read]) { _, _, _ in
            asked += 1
            return exact
        }
        #expect(asked == 1)
        #expect(found == [ImageFinding(kind: .contact, rect: exact.union(cut.box))])
    }

    @Test func aMarkOfTheFullTextThatIsNotCutIsPreferredToOneThatIs() async throws {
        let text = "write to \(email) for details"
        let tag = SensitiveScanner.tag(of: .contact)
        let cut = OCRMark(text: email, box: CGRect(x: 130, y: 100, width: 150, height: 30), tag: tag, isCut: true)
        let whole = OCRMark(text: email, box: CGRect(x: 131, y: 100, width: 160, height: 30), tag: tag)
        let read = OCRLine(text: text, box: CGRect(x: 40, y: 100, width: 370, height: 30), marks: [cut, whole])
        var asked = 0
        let found = try await scan([read]) { _, _, _ in
            asked += 1
            return nil
        }
        #expect(asked == 0)
        #expect(found == [ImageFinding(kind: .contact, rect: whole.box.union(cut.box))])
    }

    @Test func aMarkWithATagOfNoKindIsIgnored() async throws {
        let read = OCRLine(text: "nothing to see here at all", box: CGRect(x: 40, y: 100, width: 260, height: 30),
                           marks: [OCRMark(text: "see", box: CGRect(x: 100, y: 100, width: 30, height: 30), tag: 99)])
        #expect(try await scan([read]).isEmpty)
    }

    // MARK: The box a re-read gives

    @Test func aRereadTakesTheBoxOnTheFindingsOwnLineNotTheSameTextOnTheLinesAroundIt() {
        // The crop around a finding on line N takes in parts of lines N - 1 and N + 1, and with a repeated secret, aligned in a
        // column, the same text is on each at the same x. 40 px between lines, 30 tall.
        let text = email
        func mark(_ y: CGFloat) -> OCRMark {
            OCRMark(text: text, box: CGRect(x: 100, y: y, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        }
        let line = OCRLine(text: "write to \(text) for details", box: CGRect(x: 40, y: 140, width: 370, height: 30))
        // The crop starts at y 125 (15 px above the line) and x 0: the marks are in its pixels.
        let window = CGRect(x: 0, y: 125, width: 500, height: 60)
        let above = mark(100 - 125), here = mark(140 - 125), below = mark(180 - 125)
        let estimate = CGRect(x: 90, y: 140, width: 240, height: 30)
        for order in [[above, here, below], [below, here, above], [above, below, here]] {
            let box = SensitiveScanner.box(of: text, among: order, in: window, line: line, near: estimate)
            #expect(box == CGRect(x: 100, y: 140, width: 160, height: 30), "\(order.map(\.box.minY))")
        }
        // Only the neighbours' text in the crop: no box rather than a neighbour's.
        #expect(SensitiveScanner.box(of: text, among: [above, below], in: window, line: line, near: estimate) == nil)
    }

    @Test func aRereadTakesTheNearestBoxAlongTheLine() {
        let line = OCRLine(text: "\(email) and \(email)", box: CGRect(x: 40, y: 100, width: 360, height: 30))
        func mark(_ x: CGFloat) -> OCRMark {
            OCRMark(text: email, box: CGRect(x: x - 20, y: 100 - 85, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact))
        }
        let window = CGRect(x: 20, y: 85, width: 400, height: 60)
        // Marks in the crop's pixels: at x 40 and x 240 of the image, 20 px in from the crop's left edge.
        let box = SensitiveScanner.box(of: email, among: [mark(60), mark(260)], in: window, line: line,
                                       near: CGRect(x: 230, y: 100, width: 200, height: 30))
        #expect(box == CGRect(x: 260, y: 100, width: 160, height: 30))
    }

    @Test func aRereadWithNothingOfThatTextGivesNoBox() {
        let line = OCRLine(text: "x", box: CGRect(x: 40, y: 100, width: 100, height: 30))
        let other = OCRMark(text: "other", box: CGRect(x: 0, y: 0, width: 50, height: 30), tag: 0)
        #expect(SensitiveScanner.box(of: email, among: [other], in: CGRect(x: 0, y: 85, width: 200, height: 60), line: line,
                                     near: line.box) == nil)
        #expect(SensitiveScanner.box(of: email, among: [], in: CGRect(x: 0, y: 85, width: 200, height: 60), line: line, near: line.box) == nil)
    }

    // MARK: Overlaps

    @Test func overlappingFindingsOfOneKindAreMerged() async throws {
        // Same kind, boxes of two readings that agree to a few pixels.
        let a = line("x \(email)", y: 100, marking: [(email, .contact)])
        let b = line("x \(email)", y: 100, marking: [(email, .contact)], offset: 4)
        let finding = try only(try await scan([a, b]))
        #expect(finding.rect == a.marks[0].box.union(b.marks[0].box))
    }

    @Test func findingsOnNeighbouringLinesThatOnlyGrazeStayApart() async throws {
        // Two lines 28 px apart with boxes 30 tall: the boxes share two pixels.
        let upper = line("x \(email)", y: 100, marking: [(email, .contact)])
        let lower = line("y \(email)", y: 128, marking: [(email, .contact)])
        #expect(try await scan([upper, lower]).map(\.rect) == [upper.marks[0].box, lower.marks[0].box])
    }

    @Test func findingsOfOtherKindsAreNotMerged() async throws {
        // A card number and a phone-like digit run over the same place are told apart by the detector, not here.
        let tag = SensitiveScanner.tag(of: .card)
        let read = OCRLine(text: "ab", box: CGRect(x: 0, y: 0, width: 20, height: 30), marks: [
            OCRMark(text: "x", box: CGRect(x: 0, y: 0, width: 20, height: 30), tag: tag),
            OCRMark(text: "y", box: CGRect(x: 0, y: 0, width: 20, height: 30), tag: SensitiveScanner.tag(of: .contact)),
        ])
        #expect(try await scan([read]).map(\.kind) == [.card, .contact])
    }

    // MARK: Private keys

    private let escape = "\\n"

    /// A private key's lines as OCR gives them: a header line (after "key: ", the header boxed by Vision as a finding), body
    /// lines of 64 characters, and the END line, 40 px apart, all starting at x 90 (past the label).
    private func keyLines(body: Int = 4, header: Bool = true, end: Bool = true, startY: CGFloat = 200) -> [OCRLine] {
        var texts: [String] = []
        if header { texts.append(Fake.privateKeyBegin()) }
        texts += (1...body).map { Fake.privateKeyBody(64, line: $0) }
        if end { texts.append(Fake.privateKeyEnd()) }
        return texts.enumerated().map { index, text in
            let y = startY + CGFloat(index) * 40
            guard header, index == 0 else { return line(text, x: 90, y: y) }
            // "key: " in front, at 10 px a character: Vision's box for the header starts at x 90.
            var read = line("key: " + text, x: 40, y: y, marking: [(text, .keyOrToken)])
            read.box = CGRect(x: 40, y: y, width: 10 * CGFloat(read.text.count), height: 30)
            return read
        }
    }

    @Test func aPrivateKeyIsOneFindingOverAllItsLines() async throws {
        let key = keyLines()
        let lines = [line("Here is the key:", y: 100)] + key + [line("Thanks for reading all of this.", y: 500)]
        let finding = try only(try await scan(lines))
        #expect(finding.kind == .keyOrToken)
        // The union of the header's own box and every line below it: it starts where the header does, not at "key:".
        let below = key[1...].map(\.box).reduce(CGRect.null) { $0.union($1) }
        #expect(finding.rect == key[0].marks[0].box.union(below))
        #expect(finding.rect.minX == 90)
        // Six lines, from the header's top to the END line's bottom, and none of the lines around it.
        #expect(finding.rect.minY == 200 && finding.rect.maxY == key.last!.box.maxY)
    }

    @Test func aPrivateKeyIsMarkedAsOverSeveralLinesAndAnythingOnOneLineIsNot() async throws {
        // The mask is placed along the way the text runs, which a strip on one line says by its shape and a block of lines
        // doesn't: a key's block is flagged, however its lines were found.
        let key = keyLines()
        #expect(try only(try await scan(key)).spansLines)
        let first = line("-----BEGIN RSA PRIVATE", y: 200)
        let second = line("KEY-----" + escape + Fake.privateKeyBody(30, line: 1), y: 240)
        let rest = (2...3).map { line(Fake.privateKeyBody(64, line: $0), y: 200 + CGFloat($0) * 40) }
        #expect(try only(try await scan([first, second] + rest + [line(Fake.privateKeyEnd(), y: 360)])).spansLines)
        // On one line: an email, a token, a card.
        let mail = line("mail me at \(email) today", marking: [(email, .contact)])
        let pay = line("card \(card) on file", y: 200, marking: [(card, .card)])
        let secret = line("paste \(token) here", y: 300, marking: [(token, .keyOrToken)])
        let found = try await scan([mail, pay, secret])
        #expect(found.count == 3 && found.allSatisfy { !$0.spansLines }, "\(found)")
    }

    @Test func aKeyWrappedByTheScreenIsMarkedAsOverSeveralLines() async throws {
        let json = "\"private_key\": \"" + Fake.privateKeyBegin() + escape + (1...4).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: escape)
            + escape + Fake.privateKeyEnd() + escape + "\","
        let lines = TextWrapping.chunks(of: json, width: 38).enumerated().map { index, text in line(text, y: 200 + CGFloat(index) * 40) }
        #expect(try only(try await scan(lines)).spansLines)
    }

    @Test func bodyLinesWithoutAHeaderAreNotFindings() async throws {
        #expect(try await scan(keyLines(header: false)).isEmpty)
    }

    @Test func aKeyWithNoEndLineIsFoundThroughItsLastBodyLine() async throws {
        let key = keyLines(end: false)
        let finding = try only(try await scan(key + [line("A sentence of ordinary words follows the key here.", y: 500)]))
        #expect(finding.rect.maxY == key.last!.box.maxY)
    }

    @Test func proseUnderAKeyIsNotTakenIn() async throws {
        let key = keyLines()
        let finding = try only(try await scan(key + [line("A sentence of ordinary words follows the key here.", y: 500),
                                                     line(Fake.privateKeyBody(64, line: 9), y: 540)]))
        #expect(finding.rect.maxY == key.last!.box.maxY)
    }

    @Test func aPrivateKeyIsOnlyLookedForWhenKeysAndTokensAreOn() async throws {
        #expect(try await scan(keyLines(), .contact).isEmpty)
        #expect(try await scan(keyLines(), .cards).isEmpty)
        #expect(try await scan(keyLines(), .keysAndTokens).map(\.kind) == [.keyOrToken])
    }

    @Test func aHeaderSplitAcrossTwoLinesTakesBothLinesWhole() async throws {
        let first = line("-----BEGIN RSA PRIVATE", y: 200)
        let second = line("KEY-----" + escape + Fake.privateKeyBody(30, line: 1), y: 240)
        let rest = (2...3).map { line(Fake.privateKeyBody(64, line: $0), y: 200 + CGFloat($0) * 40) }
        let end = line(Fake.privateKeyEnd(), y: 360)
        let finding = try only(try await scan([first, second] + rest + [end]))
        #expect(finding.rect == ([first, second] + rest + [end]).map(\.box).reduce(CGRect.null) { $0.union($1) })
    }

    @Test func aKeyWrappedByTheScreenIsOneFindingOverEveryLine() async throws {
        let json = "\"private_key\": \"" + Fake.privateKeyBegin() + escape + (1...4).map { Fake.privateKeyBody(64, line: $0) }.joined(separator: escape)
            + escape + Fake.privateKeyEnd() + escape + "\","
        // The header is split across the first two lines, so neither is flagged by the detector, and both are taken whole.
        let pieces = TextWrapping.chunks(of: json, width: 38)
        let lines = pieces.enumerated().map { index, text in line(text, y: 200 + CGFloat(index) * 40) }
        let below = line("Some prose under the key follows right here.", y: 200 + CGFloat(lines.count) * 40)

        let finding = try only(try await scan(lines + [below]))

        #expect(finding.kind == .keyOrToken)
        // Through the line that completes the END marker; the `\n",` that closes the string after it holds nothing of the key.
        let last = try #require(pieces.lastIndex { $0.contains("KEY-----") })
        let keyBox = lines[0...last].map(\.box).reduce(CGRect.null) { $0.union($1) }
        #expect(finding.rect == keyBox)
        #expect(finding.rect.maxY < below.box.minY)
    }

    // MARK: The image's edge, and cancelling

    @Test func aBoxPastTheImageIsCutToIt() async throws {
        let read = OCRLine(text: "mail \(email)", box: CGRect(x: 2900, y: 1980, width: 200, height: 30), marks: [
            OCRMark(text: email, box: CGRect(x: 2950, y: 1985, width: 160, height: 30), tag: SensitiveScanner.tag(of: .contact)),
        ])
        #expect(try await scan([read]) == [ImageFinding(kind: .contact, rect: CGRect(x: 2950, y: 1985, width: 50, height: 15))])
    }

    @Test func scanningStopsWhenTheTaskIsCancelled() async throws {
        let lines = (0..<50).map { line("mail \(email)", y: CGFloat(40 * $0), marking: [(email, .contact)]) }
        let task = Task {
            // Wait until the cancellation is in before starting.
            while !Task.isCancelled { await Task.yield() }
            return try await SensitiveScanner.findings(from: lines, kinds: .all, imageSize: imageSize) { _, _, _ in nil }
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: Tags

    @Test func everyKindHasATagThatGivesItBack() {
        for kind in SensitiveKind.allCases {
            #expect(SensitiveScanner.kind(ofTag: SensitiveScanner.tag(of: kind)) == kind)
        }
        #expect(Set(SensitiveKind.allCases.map(SensitiveScanner.tag(of:))).count == SensitiveKind.allCases.count)
        #expect(SensitiveScanner.kind(ofTag: -1) == nil && SensitiveScanner.kind(ofTag: SensitiveKind.allCases.count) == nil)
    }
}
