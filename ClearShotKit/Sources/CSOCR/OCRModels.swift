import CoreGraphics

/// A stretch of a recognized line that the caller asked to have boxed (`TextRecognizer.recognize(_:options:marking:)`).
public struct OCRMark: Equatable, Sendable {
    /// The stretch's text as the tile that boxed it read it.
    public var text: String
    /// Vision's box for exactly that stretch, in image pixels with a top-left origin.
    public var box: CGRect
    /// What the caller said the stretch is: the tag it gave the range, handed back as it was.
    public var tag: Int
    /// Whether the box comes up to an inner left or right edge of the tile that read it: the line may go on past the edge, so
    /// the stretch may be longer than that tile saw, whatever its text (an edge cuts a line mid-word). Vision's boxes stop a
    /// few pixels short of the edge (`OCRTiling.touchesInnerSide`).
    public var isCut: Bool

    public init(text: String, box: CGRect, tag: Int, isCut: Bool = false) {
        self.text = text
        self.box = box
        self.tag = tag
        self.isCut = isCut
    }
}

/// One line of recognized text.
public struct OCRLine: Equatable, Sendable {
    public var text: String
    /// Where the line is, in image pixels with a top-left origin.
    public var box: CGRect
    /// The stretches of the line the caller asked to have boxed, if it asked (`TextRecognizer.recognize(_:options:
    /// marking:)`). Each was boxed in the tile that read it, so where two tiles read the same stretch of a line, a line put
    /// together from them lists it for each (and a stretch only one of them read, once).
    public var marks: [OCRMark]

    public init(text: String, box: CGRect, marks: [OCRMark] = []) {
        self.text = text
        self.box = box
        self.marks = marks
    }
}

/// Everything recognition found in an image: its text lines in reading order and the payloads of its QR codes.
public struct OCRResult: Equatable, Sendable {
    public var lines: [OCRLine]
    public var qrPayloads: [String]

    public init(lines: [OCRLine] = [], qrPayloads: [String] = []) {
        self.lines = lines
        self.qrPayloads = qrPayloads
    }

    public var isEmpty: Bool { lines.isEmpty && qrPayloads.isEmpty }
}

/// A piece of an image that Vision reads on its own (`OCRTiling`).
public struct OCRTile: Equatable, Sendable {
    public struct Edges: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let top = Edges(rawValue: 1 << 0)
        public static let bottom = Edges(rawValue: 1 << 1)
        public static let left = Edges(rawValue: 1 << 2)
        public static let right = Edges(rawValue: 1 << 3)
    }

    /// The tile, in image pixels with a top-left origin.
    public let rect: CGRect
    /// The edges that are cuts through the image rather than its border. A line touching one is cut off; the
    /// neighbouring tile overlaps far enough to hold it whole.
    public let innerEdges: Edges
}
