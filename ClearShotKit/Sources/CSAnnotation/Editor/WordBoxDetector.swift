import CoreGraphics
import CSCore
import Foundation
import Vision

/// Word rectangles for the Smart Highlighter, found once per document with on-device text recognition.
enum WordBoxDetector {
    /// Word boxes in the image's pixels, top-left origin.
    static func wordBoxes(in image: CGImage) async -> [CGRect] {
        await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            do {
                try VNImageRequestHandler(cgImage: image).perform([request])
            } catch {
                // No boxes: the highlighter stays freehand.
                Log.annotate.error("Word detection for the Smart Highlighter failed: \(error)")
                return []
            }
            let width = Double(image.width)
            let height = Double(image.height)
            var boxes: [CGRect] = []
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first else { continue }
                let text = candidate.string
                var searchStart = text.startIndex
                for word in text.split(separator: " ") {
                    guard let range = text.range(of: word, range: searchStart..<text.endIndex) else { continue }
                    searchStart = range.upperBound
                    guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { continue }
                    // Vision boxes are normalized with the origin at the bottom left.
                    boxes.append(CGRect(x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width,
                                        height: box.height * height))
                }
            }
            return boxes
        }.value
    }
}
