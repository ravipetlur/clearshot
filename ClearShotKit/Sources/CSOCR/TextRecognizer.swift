import CoreGraphics
import Foundation
import Vision

/// Reads the text and QR codes in an image with Vision.
public enum TextRecognizer {
    /// Recognizes `image` tile by tile (`OCRTiling`), one tile at a time and in order, reading text and QR codes in one
    /// pass over each. Never runs on the caller's actor.
    @concurrent
    public static func recognize(_ image: CGImage, options: TextRecognitionOptions) async throws -> OCRResult {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var ink: ColumnInk?
        let tiles = OCRTiling.tiles(width: image.width, height: image.height) { rows in
            let columns = ink ?? ColumnInk(image)
            ink = columns
            return columns.counts(rows: rows)
        }
        let requests = Requests(options)
        var parts: [(tile: OCRTile, pieces: [OCRPiece], qrPayloads: [String])] = []
        for tile in tiles {
            try Task.checkCancellation()
            guard let piece = tile.rect == bounds ? image : image.cropping(to: tile.rect) else {
                throw TileUnavailable(rect: tile.rect)
            }
            let read = try await requests.read(piece, in: tile)
            parts.append((tile: tile, pieces: read.pieces, qrPayloads: read.qrPayloads))
        }
        return OCRTiling.merge(pieces: parts)
    }

    /// Recognizes a tiny blank image so Vision loads its models (about half a minute the first time a build runs)
    /// before the first real recognition. The result is ignored.
    @concurrent
    public static func warmUp() async {
        let context = CGContext(data: nil, width: 64, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.setFillColor(gray: 1, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        guard let blank = context?.makeImage() else { return }
        _ = try? await recognize(blank, options: TextRecognitionOptions(automaticallyDetectsLanguage: true, primaryLanguage: "en-US"))
    }

    /// The languages accurate recognition supports on this Mac, as Vision reports them.
    public static func supportedLanguages() -> [Locale.Language] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        return request.supportedRecognitionLanguages
    }

    /// The two requests every tile is read with.
    private struct Requests {
        var text = RecognizeTextRequest()
        var barcodes = DetectBarcodesRequest()

        init(_ options: TextRecognitionOptions) {
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = options.automaticallyDetectsLanguage
            if !options.automaticallyDetectsLanguage {
                text.recognitionLanguages = [Locale.Language(identifier: options.primaryLanguage)]
            }
            barcodes.symbologies = [.qr]
        }

        /// What Vision finds in `image`, the picture of `tile`: its text lines as the tile contributes them
        /// (`OCRTiling.ownedPart`, in the tile's pixels with a top-left origin) and its QR payloads.
        func read(_ image: CGImage, in tile: OCRTile) async throws -> (pieces: [OCRPiece], qrPayloads: [String]) {
            let (observations, codes) = try await ImageRequestHandler(image).perform(text, barcodes)
            let size = CGSize(width: image.width, height: image.height)
            let pieces = observations.compactMap { observation -> OCRPiece? in
                guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { return nil }
                let box = observation.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                return OCRTiling.ownedPart(of: candidate.string, box: box, in: tile) { range in
                    candidate.boundingBox(for: range)?.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                }
            }
            let payloads = codes.compactMap(\.payloadString).filter { !$0.isEmpty }
            return (pieces, payloads)
        }
    }

    private struct TileUnavailable: Error, CustomStringConvertible {
        let rect: CGRect
        var description: String { "Couldn't cut the tile \(rect) out of the image" }
    }
}

/// How much ink each column of an image has, row band by row band, so tile cuts can go through empty columns. Worked
/// out on a 4×-downsampled grayscale copy: a pixel is ink when it is more than 24 levels from the band's most common
/// value, so text counts on light and dark backgrounds alike.
struct ColumnInk {
    static let downsampling = 4
    static let threshold = 24

    private let width: Int
    private let smallWidth: Int
    private let smallHeight: Int
    /// The downsampled copy, rows from the top.
    private let pixels: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        let smallWidth = max(1, (image.width + Self.downsampling - 1) / Self.downsampling)
        let smallHeight = max(1, (image.height + Self.downsampling - 1) / Self.downsampling)
        // Starts white, so a transparent image reads as drawn on white.
        var pixels = [UInt8](repeating: 255, count: smallWidth * smallHeight)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: smallWidth, height: smallHeight, bitsPerComponent: 8,
                                    bytesPerRow: smallWidth, space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            context?.interpolationQuality = .high
            context?.draw(image, in: CGRect(x: 0, y: 0, width: smallWidth, height: smallHeight))
        }
        self.smallWidth = smallWidth
        self.smallHeight = smallHeight
        self.pixels = pixels
    }

    /// One count per image column: the ink pixels of the downsampled copy in that column, within `rows` (image rows).
    func counts(rows: Range<Int>) -> [Int] {
        let top = min(max(rows.lowerBound / Self.downsampling, 0), smallHeight)
        let bottom = min(max((rows.upperBound + Self.downsampling - 1) / Self.downsampling, top), smallHeight)
        var small = [Int](repeating: 0, count: smallWidth)
        pixels.withUnsafeBufferPointer { pixels in
            var histogram = [Int](repeating: 0, count: 256)
            for index in top * smallWidth..<bottom * smallWidth { histogram[Int(pixels[index])] += 1 }
            let background = histogram.indices.max { histogram[$0] < histogram[$1] } ?? 255
            for y in top..<bottom {
                let row = y * smallWidth
                for x in 0..<smallWidth where abs(Int(pixels[row + x]) - background) > Self.threshold {
                    small[x] += 1
                }
            }
        }
        return (0..<width).map { small[$0 / Self.downsampling] }
    }
}
