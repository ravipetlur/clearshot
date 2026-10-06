import CoreGraphics
import Foundation

/// Objects resized as a whole, for pasting between documents at different scales.
public enum ObjectScaling {
    /// `object` with every length multiplied by `factor`, about the base image's origin: its geometry, line width, text
    /// width and font size, counter diameter, highlight width and image rect. Its id stays. A factor that isn't a positive
    /// number changes nothing.
    public static func scaled(_ object: AnnotationObject, by factor: Double) -> AnnotationObject {
        guard factor.isFinite, factor > 0, factor != 1 else { return object }
        func point(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * factor, y: point.y * factor) }
        func rect(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.origin.x * factor, y: rect.origin.y * factor, width: rect.size.width * factor, height: rect.size.height * factor)
        }
        var copy = object
        copy.style.lineWidth *= factor
        switch object.kind {
        case .rectangle(let shape): copy.kind = .rectangle(rect(shape))
        case .filledRectangle(let shape): copy.kind = .filledRectangle(rect(shape))
        case .ellipse(let shape): copy.kind = .ellipse(rect(shape))
        case .line(let start, let end): copy.kind = .line(start: point(start), end: point(end))
        case .arrow(var arrow):
            arrow.start = point(arrow.start)
            arrow.end = point(arrow.end)
            arrow.control = arrow.control.map(point)
            copy.kind = .arrow(arrow)
        case .text(var text):
            text.origin = point(text.origin)
            text.width = text.width.map { $0 * factor }
            text.fontSize *= factor
            copy.kind = .text(text)
        case .redact(var redact):
            redact.rect = rect(redact.rect)
            copy.kind = .redact(redact)
        case .spotlight(var spotlight):
            spotlight.rect = rect(spotlight.rect)
            copy.kind = .spotlight(spotlight)
        case .counter(var counter):
            counter.center = point(counter.center)
            counter.diameter *= factor
            copy.kind = .counter(counter)
        case .stroke(var stroke):
            stroke.points = stroke.points.map(point)
            copy.kind = .stroke(stroke)
        case .highlight(var highlight):
            highlight.points = highlight.points.map(point)
            highlight.rects = highlight.rects.map(rect)
            highlight.width *= factor
            copy.kind = .highlight(highlight)
        case .image(var image):
            image.rect = rect(image.rect)
            copy.kind = .image(image)
        }
        return copy
    }
}
