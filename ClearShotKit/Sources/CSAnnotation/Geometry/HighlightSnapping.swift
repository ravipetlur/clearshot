import CoreGraphics
import Foundation

/// The Smart Highlighter: a stroke snaps to the words it crosses and takes their line height.
public enum HighlightSnapping {
    /// One rect per line of text the stroke crosses, covering the crossed words with a little padding; empty when it
    /// crosses no words (the stroke then stays freehand). `words` are word boxes in base pixels.
    ///
    /// A word counts when the stroke's centreline passes through it, give or take a small tolerance. The marker's own
    /// thickness plays no part: a default marker is taller than ordinary line spacing, so using it would pull in the
    /// lines above and below.
    public static func rects(along points: [CGPoint], width: Double, words: [CGRect]) -> [CGRect] {
        guard !points.isEmpty, !words.isEmpty else { return [] }
        let segments = segments(of: points)
        let reach = boundingBox(of: points).insetBy(dx: -width / 2, dy: -width / 2)
        let hit = words.filter { word in
            guard word.minX <= reach.maxX, word.maxX >= reach.minX, word.minY <= reach.maxY, word.maxY >= reach.minY else {
                return false
            }
            let tolerance = min(width / 2, word.height * 0.25)
            let target = word.insetBy(dx: -tolerance, dy: -tolerance)
            return segments.contains { segmentIntersects($0.0, $0.1, target) }
        }
        guard !hit.isEmpty else { return [] }
        // Group words into lines by their vertical centres.
        var lines: [[CGRect]] = []
        for word in hit.sorted(by: { $0.midY < $1.midY }) {
            if let last = lines.last?.last, abs(last.midY - word.midY) < min(last.height, word.height) / 2 {
                lines[lines.count - 1].append(word)
            } else {
                lines.append([word])
            }
        }
        return lines.map { line in
            let union = line.dropFirst().reduce(line[0]) { $0.union($1) }
            return union.insetBy(dx: -2, dy: -union.height * 0.15)
        }
        .sorted { $0.minY < $1.minY }
    }

    private static func segments(of points: [CGPoint]) -> [(CGPoint, CGPoint)] {
        guard points.count > 1 else { return [(points[0], points[0])] }
        return zip(points, points.dropFirst()).map { ($0, $1) }
    }

    private static func boundingBox(of points: [CGPoint]) -> CGRect {
        var minX = Double.infinity, maxX = -Double.infinity, minY = Double.infinity, maxY = -Double.infinity
        for point in points {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Whether the segment from `a` to `b` touches `rect` (edges included): Liang–Barsky clipping, exact.
    private static func segmentIntersects(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let dx = b.x - a.x
        let dy = b.y - a.y
        var enter = 0.0
        var leave = 1.0
        // Each edge gives `p * t <= q`; a segment parallel to an edge (p == 0) is either wholly inside it or outside.
        func clip(_ p: Double, _ q: Double) -> Bool {
            if p == 0 { return q >= 0 }
            let t = q / p
            if p < 0 {
                enter = max(enter, t)
            } else {
                leave = min(leave, t)
            }
            return enter <= leave
        }
        return clip(-dx, a.x - rect.minX) && clip(dx, rect.maxX - a.x)
            && clip(-dy, a.y - rect.minY) && clip(dy, rect.maxY - a.y)
    }
}
