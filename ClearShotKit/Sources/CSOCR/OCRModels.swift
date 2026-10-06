import CoreGraphics

/// One line of recognized text.
public struct OCRLine: Equatable, Sendable {
    public var text: String
    /// Where the line is, in image pixels with a top-left origin.
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
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
