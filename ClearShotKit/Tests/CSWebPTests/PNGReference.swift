import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the system's own PNG writer makes of the same pixels: the size the encoder's files are measured against.
enum PNGReference {
    enum Failure: Error { case noImage, noDestination, notFinished }

    /// `image` as a PNG by ImageIO (`CGImageDestination`, `public.png`) at its default settings. An opaque image is
    /// written without an alpha channel, as a PNG of a screenshot would be.
    static func data(for image: RGBAImage) throws -> Data {
        let opaque = stride(from: 3, to: image.rgba.count, by: 4).allSatisfy { image.rgba[$0] == 255 }
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .last
        guard let provider = CGDataProvider(data: Data(image.rgba) as CFData),
              let cgImage = CGImage(
                  width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue), provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw Failure.noImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.noDestination
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notFinished }
        return output as Data
    }
}
