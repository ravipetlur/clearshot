import CoreGraphics

public enum CaptureKind: String, Sendable, Codable {
    case selection, window, display
}

public struct PostProcessOptions: Sendable, Equatable {
    public var scaleTo1x: Bool
    public var convertToSRGB: Bool
    public var addBorder: Bool
    public var cropTopPixels: Int

    public init(scaleTo1x: Bool = false, convertToSRGB: Bool = false, addBorder: Bool = false, cropTopPixels: Int = 0) {
        self.scaleTo1x = scaleTo1x
        self.convertToSRGB = convertToSRGB
        self.addBorder = addBorder
        self.cropTopPixels = cropTopPixels
    }
}

/// Image operations applied after a capture, in the order `apply` runs them: crop the top, scale to 1×, convert to
/// sRGB, add a border. Pixel rects use a top-left origin.
public enum PostProcessor {
    public static func apply(_ image: CGImage, scale: CGFloat, options: PostProcessOptions) -> CGImage {
        var result = image
        if options.cropTopPixels > 0 { result = croppingTop(result, pixels: options.cropTopPixels) }
        if options.scaleTo1x, scale > 1 { result = scaled(result, by: 1 / scale) }
        if options.convertToSRGB { result = convertedToSRGB(result) }
        if options.addBorder { result = addingBorder(result) }
        return result
    }

    /// The part of `image` inside a top-left-origin pixel rect, or nil if the rect misses the image.
    public static func cropped(_ image: CGImage, to pixelRect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = pixelRect.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return image.cropping(to: rect)
    }

    public static func croppingTop(_ image: CGImage, pixels: Int) -> CGImage {
        cropped(image, to: CGRect(x: 0, y: pixels, width: image.width, height: image.height - pixels)) ?? image
    }

    public static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let context = makeContext(width: width, height: height, colorSpace: image.colorSpace) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Converts (not just re-tags) the pixels to sRGB.
    public static func convertedToSRGB(_ image: CGImage) -> CGImage {
        guard image.colorSpace?.name != CGColorSpace.sRGB,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let context = makeContext(width: image.width, height: image.height, colorSpace: srgb) else { return image }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Draws a 1 px border over the outermost pixels, so the size doesn't change.
    public static func addingBorder(_ image: CGImage, color: CGColor = CGColor(gray: 0, alpha: 0.15)) -> CGImage {
        guard let context = makeContext(width: image.width, height: image.height, colorSpace: image.colorSpace) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.draw(image, in: rect)
        context.setStrokeColor(color)
        context.setLineWidth(1)
        context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        return context.makeImage() ?? image
    }

    /// A window image centered on a background (aspect-filled) with `padding` pixels on every side.
    /// A nil background leaves the padding transparent.
    public static func compositingWindow(_ window: CGImage, background: CGImage?, padding: Int) -> CGImage {
        let width = window.width + padding * 2
        let height = window.height + padding * 2
        guard let context = makeContext(width: width, height: height, colorSpace: window.colorSpace) else { return window }
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        if let background {
            context.interpolationQuality = .high
            context.draw(background, in: aspectFill(CGSize(width: background.width, height: background.height), in: canvas))
        }
        context.draw(window, in: CGRect(x: padding, y: padding, width: window.width, height: window.height))
        return context.makeImage() ?? window
    }

    static func aspectFill(_ size: CGSize, in target: CGRect) -> CGRect {
        let factor = max(target.width / size.width, target.height / size.height)
        let fitted = CGSize(width: size.width * factor, height: size.height * factor)
        return CGRect(x: target.midX - fitted.width / 2, y: target.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace?) -> CGContext? {
        let space = colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
