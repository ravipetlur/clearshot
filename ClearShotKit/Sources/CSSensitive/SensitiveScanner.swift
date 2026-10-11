import CoreGraphics
import CSOCR
import Foundation

/// A finding in an image: what kind it is and where it is.
public struct ImageFinding: Equatable, Sendable {
    public let kind: SensitiveKind
    /// Where the finding's text is, in image pixels with a top-left origin.
    public let rect: CGRect
    /// Whether the finding is over several lines (a private key's block), so that the shape of `rect` says nothing about which
    /// way its text runs: a block is tall by nature. A finding on one line is a strip along its text.
    public let spansLines: Bool

    public init(kind: SensitiveKind, rect: CGRect, spansLines: Bool = false) {
        self.kind = kind
        self.rect = rect
        self.spansLines = spansLines
    }
}

/// Finds sensitive text in an image: reads it with Vision, runs the detector on every line, and boxes each finding.
///
/// The image is read as `TextRecognizer` reads it (large images in overlapping tiles, lines kept by the tile they belong
/// to and put together in reading order), with accurate recognition, the language detected, and **language correction
/// off**, because correction can rewrite the characters of a token or a key. Vision is asked, in the same pass, for the box of
/// exactly the range of each tile's line the detector flagged (`OCRMark`), so a finding is boxed on the characters it covers
/// and not on the whole line.
///
/// Nothing is logged here and no text is kept: the caller logs counts by kind (`FindingCounts`) and how long the scan took.
public enum SensitiveScanner {
    /// The findings in `image` for the kinds asked, in reading order, each in image pixels with a top-left origin. Throws
    /// `CancellationError` if the task is cancelled (checked between tiles, and between lines), and what Vision throws if
    /// it can't read the image. An image with no text, or no kinds asked for, gives none.
    ///
    /// - A private key's header is taken over the key's body, through its END line, as one finding: a single rectangle over all
    ///   its lines, so it may cover more than the key, marked `spansLines`. A body with no header above it is nothing
    ///   (`PrivateKeyBlocks`).
    /// - Findings of one kind that lie over each other (a secret read by two tiles) are one.
    @concurrent
    public static func scan(_ image: CGImage, kinds: SensitiveKinds) async throws -> [ImageFinding] {
        guard !kinds.isEmpty else { return [] }
        try Task.checkCancellation()
        let marking = marking(for: kinds)
        let lines = try await TextRecognizer.recognize(image, options: options, marking: marking).lines
        var rereads = 0
        return try await findings(from: lines, kinds: kinds, imageSize: CGSize(width: image.width, height: image.height)) { line, text, estimate in
            // A scan that needs many of these is a page of secrets cut by tile edges: the rest keep their estimate.
            guard rereads < maximumRereads else { return nil }
            rereads += 1
            return try await reread(text, near: estimate, in: line, of: image, marking: marking)
        }
    }

    /// What every reading uses: accurate recognition, the language detected, and no language correction.
    static let options = TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US",
                                                usesLanguageCorrection: false)

    /// What Vision is asked to box in each line a tile reads: the detector's findings, tagged by kind.
    private static func marking(for kinds: SensitiveKinds) -> TextRecognizer.Marking {
        { text in SensitiveDetector.findings(in: text, kinds: kinds).map { (range: $0.range, tag: tag(of: $0.kind)) } }
    }

    // MARK: Tags

    /// The tag a kind has on a mark: its place among the kinds.
    static func tag(of kind: SensitiveKind) -> Int {
        SensitiveKind.allCases.firstIndex(of: kind) ?? 0
    }

    static func kind(ofTag tag: Int) -> SensitiveKind? {
        SensitiveKind.allCases.indices.contains(tag) ? SensitiveKind.allCases[tag] : nil
    }

    private static func kinds(_ kind: SensitiveKind) -> SensitiveKinds {
        kind.option
    }

    // MARK: From lines to findings

    /// What is known of one finding while a line is worked through.
    private struct Located {
        let kind: SensitiveKind
        /// Where it is in the line's text; nil for a mark of a tile's reading that the line's text doesn't hold.
        let range: Range<String.Index>?
        var rect: CGRect
    }

    /// The marks of `line` among `slots` with `text` that aren't cut, grouped into the places they are at: marks that lie over
    /// each other, through any chain of them, are one place (the same stretch boxed by two tiles).
    private static func places(of text: String, among slots: [Int], in line: OCRLine) -> [[Int]] {
        var places = slots.filter { line.marks[$0].text == text && !line.marks[$0].isCut }.map { [$0] }
        var merged = true
        while merged {
            merged = false
            search: for first in places.indices {
                for second in places.indices where second > first {
                    let touching = places[first].contains { a in places[second].contains { overlap(line.marks[a].box, line.marks[$0].box) } }
                    guard touching else { continue }
                    places[first] += places[second]
                    places.remove(at: second)
                    merged = true
                    break search
                }
            }
        }
        return places
    }

    /// The box over all of the marks of a place.
    private static func box(of place: [Int], in line: OCRLine) -> CGRect {
        place.reduce(CGRect.null) { $0.union(line.marks[$1].box) }
    }

    /// Which place goes to which finding: `findings` and `places` are where each is along the line (the middle of its box), and a
    /// pair is a finding with the place nearest it, closest pairs first, each finding and each place in at most one pair.
    /// Whichever is left over has no pair: a finding with no place is one nothing boxed whole.
    private static func pairings(of findings: [CGFloat], with places: [CGFloat]) -> [(finding: Int, place: Int)] {
        let candidates = findings.indices.flatMap { finding in
            places.indices.map { (finding: finding, place: $0, distance: abs(findings[finding] - places[$0])) }
        }.sorted { ($0.distance, $0.finding, $0.place) < ($1.distance, $1.finding, $1.place) }
        var takenFindings = Set<Int>(), takenPlaces = Set<Int>()
        var pairs: [(finding: Int, place: Int)] = []
        for candidate in candidates where !takenFindings.contains(candidate.finding) && !takenPlaces.contains(candidate.place) {
            takenFindings.insert(candidate.finding)
            takenPlaces.insert(candidate.place)
            pairs.append((candidate.finding, candidate.place))
        }
        return pairs
    }

    /// The boxes in `found` (what locating a finding again gave, by finding) of the findings in `group`, all of one text, that
    /// can stand. A copy of a text is a place of its own: a box that lies over the box of another finding of the group, one it
    /// was paired with (`paired`) or one that stands, is that copy's, and not the finding's it was found for, which would
    /// leave the finding's own text unmasked under another's box. It goes, and the finding keeps its estimate (the caller's
    /// fallback). Where two found boxes lie over each other, the one nearest its own finding's estimate stands.
    private static func standing(_ found: [Int: CGRect], among group: [Int], beside paired: [Int: CGRect],
                                 estimates: [CGRect]) -> [Int: CGRect] {
        let candidates = group.compactMap { index in found[index].map { (index: index, box: $0) } }.sorted {
            (abs($0.box.midX - estimates[$0.index].midX), $0.index) < (abs($1.box.midX - estimates[$1.index].midX), $1.index)
        }
        var taken = group.compactMap { paired[$0] }
        var standing: [Int: CGRect] = [:]
        for candidate in candidates where !taken.contains(where: { overlap($0, candidate.box) }) {
            taken.append(candidate.box)
            standing[candidate.index] = candidate.box
        }
        return standing
    }

    /// The copies in `group`, all of one text found more than once on the line, that ended with no box (`rects` has none for
    /// them: no place was paired with them and no re-read of theirs stands) are given the span of the copies: from the
    /// earliest to the latest of every copy's estimate and every box the group has. Such a copy's own estimate is only where
    /// an even spread of the line's characters puts it, and on a line that isn't spread evenly (a gap, a wide letter) that can be
    /// nowhere near it, while the box a place gave another copy may be this copy's own. The span covers wherever any of the
    /// copies can be, so no whole copy is left readable; the words between the copies are covered too. A text found once keeps
    /// its estimate, and so does every copy of a group that all have a box.
    private static func spanning(_ group: [Int], in rects: inout [Int: CGRect], estimates: [CGRect]) {
        let unboxed = group.filter { rects[$0] == nil }
        guard group.count > 1, !unboxed.isEmpty else { return }
        let span = group.reduce(CGRect.null) { $0.union(estimates[$1]).union(rects[$1] ?? .null) }
        for index in unboxed { rects[index] = span }
    }

    /// A finding, and where it comes in reading order.
    private struct Entry {
        let line: Int
        var finding: ImageFinding
    }

    /// The findings in `lines` (as `TextRecognizer` returns them, each with the boxes Vision gave for what the detector flagged
    /// in the tiles' own readings), in image pixels, kept inside the image.
    ///
    /// The detector runs on each line's text. For each finding:
    /// - a mark of the line with the finding's text gives its box, exactly as Vision boxed the range. A text found more than
    ///   once on the line has its places (the stretches boxed whole) given out together, each to the finding nearest it, each
    ///   place and each finding at most once; the findings left over are the ones with no box;
    /// - else (the tile that read the line whole gave no box, or the line was put together from two readings and no tile
    ///   read the finding whole) `locate` is asked, given the line, the finding's text and an estimate of where it is, to find
    ///   it again; and failing that, the estimate is the box: the finding's characters spread evenly across the line, with
    ///   four characters of margin each side, so over-masking a little rather than leaving a part readable. What `locate` gives
    ///   that lies over the box of another finding of the same text (the box of that copy, not this one's) is not taken: this
    ///   finding keeps its estimate. A box with no area is no box for a finding, from Vision or from `locate`, which would
    ///   mask nothing: the estimate is used. One exception: when the text is found more than once on the line, a copy that
    ///   ends with neither a place nor a box of a re-read that stands takes, in place of its own estimate, the span over all
    ///   the copies' estimates and boxes (`spanning`), since its estimate may be nowhere near it on a line whose characters
    ///   aren't evenly spread, and the box another copy took may be its own. The words between the copies are covered then.
    ///
    /// A mark no finding took, that doesn't lie over a finding, is one too: what a tile read that the whole line doesn't hold.
    static func findings(from lines: [OCRLine], kinds: SensitiveKinds, imageSize: CGSize,
                         locate: (OCRLine, String, CGRect) async throws -> CGRect? = { _, _, _ in nil }) async throws -> [ImageFinding] {
        guard !kinds.isEmpty else { return [] }
        var located: [[Located]] = []
        var entries: [Entry] = []
        for (index, line) in lines.enumerated() {
            try Task.checkCancellation()
            var unused = Array(line.marks.indices)
            var here: [Located] = []
            let detected = SensitiveDetector.findings(in: line.text, kinds: kinds)
            let texts = detected.map { String(line.text[$0.range]) }
            let estimates = detected.map { estimatedBox(of: $0.range, in: line) }
            // The places each finding's text was boxed whole, given out to the findings of that text all at once, and not one at
            // a time: a text found twice on the line, with a place boxed for only one of the two, can't tell by counting which
            // the place is of, so each place goes to the finding it is nearest and the rest are located on their own.
            var boxed: [Int: CGRect] = [:]
            var distinct: [String] = []
            for text in texts where !distinct.contains(text) { distinct.append(text) }
            var groups: [[Int]] = []
            for text in distinct {
                let wanting = detected.indices.filter { texts[$0] == text }
                groups.append(wanting)
                // The boxes that lie over each other are one place, the same stretch read by two tiles. A box that comes up to a
                // tile's inner edge may be of a stretch cut by it, however full its text.
                let places = places(of: text, among: unused, in: line)
                let boxes = places.map { box(of: $0, in: line) }
                // A place whose box has no area would mask nothing: it is no place for a finding (which would be dropped with it).
                let usable = boxes.indices.filter { hasArea(boxes[$0]) }
                for pair in pairings(of: wanting.map { estimates[$0].midX }, with: usable.map { boxes[$0].midX }) {
                    let place = usable[pair.place]
                    unused.removeAll { places[place].contains($0) }
                    boxed[wanting[pair.finding]] = boxes[place]
                }
            }
            // The findings with no place are located on their own, and what that gives is kept only if it isn't the box of another
            // copy of the same text (`standing`): then the finding keeps its estimate, which covers its own text.
            var found: [Int: CGRect] = [:]
            for index in detected.indices where boxed[index] == nil {
                if let box = try await locate(line, texts[index], estimates[index]), hasArea(box) { found[index] = box }
            }
            var rects = boxed
            for group in groups {
                rects.merge(standing(found, among: group, beside: boxed, estimates: estimates)) { first, _ in first }
                spanning(group, in: &rects, estimates: estimates)
            }
            for (index, finding) in detected.enumerated() {
                here.append(Located(kind: finding.kind, range: finding.range, rect: rects[index] ?? estimates[index]))
            }
            // What a tile read that the line's text, put together from several readings, doesn't hold, or only as a stretch cut by
            // its edge. A mark lying over a finding is that finding, cut: its box is covered too. Any other is a finding.
            let detectedCount = here.count
            for slot in unused {
                let mark = line.marks[slot]
                if let index = here[..<detectedCount].firstIndex(where: { overlap($0.rect, mark.box) }) {
                    here[index].rect = here[index].rect.union(mark.box)
                } else if let kind = kind(ofTag: mark.tag), kinds.contains(Self.kinds(kind)) {
                    here.append(Located(kind: kind, range: nil, rect: mark.box))
                }
            }
            located.append(here)
            entries += here.map { Entry(line: index, finding: ImageFinding(kind: $0.kind, rect: $0.rect)) }
        }

        if kinds.contains(.keysAndTokens) {
            for block in PrivateKeyBlocks.blocks(in: lines.map(\.text)) {
                var rect = CGRect.null
                for index in block.lines {
                    for box in boxes(of: index, in: block, lines: lines, located: located) { rect = rect.union(box) }
                }
                entries.append(Entry(line: block.header.lowerBound, finding: ImageFinding(kind: .keyOrToken, rect: rect, spansLines: true)))
            }
        }

        let bounds = CGRect(origin: .zero, size: imageSize)
        let ordered = entries.enumerated().sorted { first, second in
            (first.element.line, first.element.finding.rect.minX, first.offset) < (second.element.line, second.element.finding.rect.minX, second.offset)
        }.map(\.element)
        return merged(ordered).compactMap { entry in
            let rect = entry.finding.rect.intersection(bounds)
            return rect.isNull || rect.isEmpty ? nil : ImageFinding(kind: entry.finding.kind, rect: rect, spansLines: entry.finding.spansLines)
        }
    }

    /// The boxes of line `index` that a private-key block takes in: the header's own box on the line that has the header, and
    /// the whole line anywhere else, and for a header split across lines, whose pieces the detector doesn't flag.
    ///
    /// The block's finding is one rectangle over the union of all of these, so the words before the header on its line are
    /// outside the header's own box but not necessarily outside the rectangle: they are in it whenever a line below the header
    /// starts further left than the header does. A key's mask may cover more than the key.
    private static func boxes(of index: Int, in block: PrivateKeyBlocks.Block, lines: [OCRLine], located: [[Located]]) -> [CGRect] {
        guard block.header == index...index else { return [lines[index].box] }
        let starts = PrivateKeyBlockPatterns.headerRanges(in: lines[index].text).map(\.lowerBound)
        let headers = located[index].filter { found in
            found.kind == .keyOrToken && found.range.map { range in starts.contains { range.contains($0) } } == true
        }
        return headers.isEmpty ? [lines[index].box] : headers.map(\.rect)
    }

    /// Where the characters of `range` are on `line` if they are spread evenly across it, with four characters more on each
    /// side, within the line: what a finding's box is when Vision gave none.
    static func estimatedBox(of range: Range<String.Index>, in line: OCRLine) -> CGRect {
        let count = line.text.count
        guard count > 0 else { return line.box }
        let width = line.box.width / CGFloat(count)
        let margin = estimateMargin * width
        let start = CGFloat(line.text.distance(from: line.text.startIndex, to: range.lowerBound))
        let end = CGFloat(line.text.distance(from: line.text.startIndex, to: range.upperBound))
        let minX = max(line.box.minX, line.box.minX + start * width - margin)
        let maxX = min(line.box.maxX, line.box.minX + end * width + margin)
        return CGRect(x: minX, y: line.box.minY, width: max(maxX - minX, 0), height: line.box.height)
    }

    /// How many characters an estimated box reaches past the finding's, each side.
    private static let estimateMargin: CGFloat = 4

    // MARK: Overlaps

    /// Whether `box` covers any pixels at all: not null, and neither side empty.
    private static func hasArea(_ box: CGRect) -> Bool {
        !box.isNull && !box.isEmpty
    }

    /// Whether two boxes lie over each other: the area they share is at least half of the smaller one's. Boxes of neighbouring
    /// lines that graze by a pixel or two aren't, and two readings of one secret are.
    private static func overlap(_ first: CGRect, _ second: CGRect) -> Bool {
        let shared = first.intersection(second)
        guard !shared.isNull, !shared.isEmpty else { return false }
        let smaller = min(first.width * first.height, second.width * second.height)
        return smaller > 0 && shared.width * shared.height >= smaller / 2
    }

    /// `entries` with the findings of one kind that lie over each other made one, over the union of the boxes, each at the place
    /// of the first of them. One pass can leave a box that grew by a merge over another, so passes go on until none merges.
    private static func merged(_ entries: [Entry]) -> [Entry] {
        var result = entries
        var changed = true
        while changed {
            changed = false
            var next: [Entry] = []
            for entry in result {
                if let index = next.firstIndex(where: { $0.finding.kind == entry.finding.kind && overlap($0.finding.rect, entry.finding.rect) }) {
                    next[index].finding = ImageFinding(kind: entry.finding.kind, rect: next[index].finding.rect.union(entry.finding.rect),
                                                       spansLines: next[index].finding.spansLines || entry.finding.spansLines)
                    changed = true
                } else {
                    next.append(entry)
                }
            }
            result = next
        }
        return result
    }

    // MARK: Reading a stretch again

    /// How many findings of one scan are read again when no tile boxed them.
    private static let maximumRereads = 24
    /// How much of the line is read again either side of the estimate, in pixels, so that a stretch in the middle of it is
    /// read whole: the first that leaves the piece within one tile (`OCRTiling`, which would cut it again).
    private static let rereadMargins: [CGFloat] = [300, 150, 60]

    /// The box of `text` on `line` found by reading the part of the image around `estimate` on its own, where the stretch
    /// isn't cut by a tile's edge, or nil if that reading doesn't hold it (or the part is too wide to be read in one tile).
    /// The nearest box to the estimate, if it holds the text more than once.
    private static func reread(_ text: String, near estimate: CGRect, in line: OCRLine, of image: CGImage,
                               marking: TextRecognizer.Marking) async throws -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let vertical = max(12, line.box.height / 2)
        for margin in rereadMargins {
            let wanted = CGRect(x: estimate.minX - margin, y: line.box.minY - vertical,
                                width: estimate.width + 2 * margin, height: line.box.height + 2 * vertical)
            let window = wanted.intersection(bounds).integral.intersection(bounds)
            guard !window.isNull, window.width >= 1, window.height >= 1,
                  OCRTiling.tileCount(width: Int(window.width), height: Int(window.height)) == 1 else { continue }
            guard let crop = image.cropping(to: window) else { return nil }
            let read = try await TextRecognizer.recognize(crop, options: options, marking: marking)
            return box(of: text, among: read.lines.flatMap(\.marks), in: window, line: line, near: estimate)
        }
        return nil
    }

    /// The box, in image pixels, of the mark of `text` among `marks` (in the pixels of the crop at `window`) that is on `line`,
    /// and the nearest across to `estimate` if there are several; nil if no mark of that text is. The crop takes in parts of the
    /// lines above and below, and a secret repeated in a column is the same text at the same x on each, so a mark counts only
    /// if its centre lies within the line's own box.
    static func box(of text: String, among marks: [OCRMark], in window: CGRect, line: OCRLine, near estimate: CGRect) -> CGRect? {
        marks.filter { $0.text == text }
            .map { $0.box.offsetBy(dx: window.minX, dy: window.minY) }
            .filter { $0.midY >= line.box.minY && $0.midY <= line.box.maxY }
            .min { abs($0.midX - estimate.midX) < abs($1.midX - estimate.midX) }
    }
}
