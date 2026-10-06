import CoreGraphics

/// The image operations as one affine map from base pixels to output pixels. Both spaces have y pointing down.
public struct DocumentTransform: Equatable, Sendable {
    public let outputSize: CGSize
    public let transform: CGAffineTransform

    public init(baseSize: CGSize, ops: [ImageOp]) {
        var size = baseSize
        var result = CGAffineTransform.identity
        for op in ops {
            let step: CGAffineTransform
            switch op {
            case .rotateRight:
                // Clockwise: (x, y) → (h − y, x).
                step = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
                size = CGSize(width: size.height, height: size.width)
            case .rotateLeft:
                // Counterclockwise: (x, y) → (y, w − x).
                step = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
                size = CGSize(width: size.height, height: size.width)
            case .flipHorizontal:
                step = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0)
            case .flipVertical:
                step = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
            case .resize(let width, let height):
                // A source or target size below one pixel can't be scaled to or from; skip the step.
                guard size.width > 0, size.height > 0, width >= 1, height >= 1 else { continue }
                step = CGAffineTransform(scaleX: Double(width) / size.width, y: Double(height) / size.height)
                size = CGSize(width: width, height: height)
            }
            result = result.concatenating(step)
        }
        outputSize = size
        transform = result
    }

    public var inverse: CGAffineTransform { transform.inverted() }

    /// How many output pixels one base pixel spans: the geometric mean of the two axes' scales.
    public var scale: Double {
        sqrt(abs(transform.a * transform.d - transform.b * transform.c))
    }

    public func toOutput(_ point: CGPoint) -> CGPoint { point.applying(transform) }
    public func toBase(_ point: CGPoint) -> CGPoint { point.applying(inverse) }
}
