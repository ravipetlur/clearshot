import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// The Blurred screenshot fill: the content, small and soft. Downscaling first keeps the blur cheap at any capture
/// size, and a heavy blur shows no detail a smaller picture would lose.
public enum BackgroundBlur {
    /// The longest side of the blurred picture, in pixels.
    public static let maximumSide = 512
    /// The Gaussian blur's radius, in the blurred picture's pixels.
    public static let radius = 12.0

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// `image` scaled down (never up) so its longest side is at most `maximumSide`, then blurred with its edges clamped, so
    /// they don't fade to transparent. sRGB, 8 bits per channel. Nil if a bitmap can't be made.
    public static func blurred(_ image: CGImage) -> CGImage? {
        guard let small = downscaled(image), let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let input = CIImage(cgImage: small)
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = Float(radius)
        guard let output = blur.outputImage?.cropped(to: input.extent) else { return nil }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: space)
    }

    /// `image` at most `maximumSide` on its longest side, scaled with high-quality interpolation; itself if it already is.
    private static func downscaled(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximumSide else { return image }
        let factor = Double(maximumSide) / Double(longest)
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
