import AppKit
import CoreGraphics
import CSCore
import ImageIO

/// The background used behind window shots taken "With wallpaper".
@MainActor
public final class WallpaperProvider {
    private let capture: ScreenCaptureService
    /// Each display's desktop picture, kept with the desktop picture file it was read under, so a changed desktop
    /// picture is read again.
    private var desktopCache = DesktopPictureCache()
    /// Custom wallpaper paths already logged as unreadable, so each is logged once.
    private var unreadableCustomPaths: Set<String> = []

    public init(capture: ScreenCaptureService) {
        self.capture = capture
    }

    /// Forget cached desktop pictures: on a Space change when "Update wallpaper when switching Spaces" is on, and when
    /// macOS says the desktop picture changed.
    public func invalidate() {
        desktopCache.removeAll()
    }

    public func image(for display: DisplayInfo, layout: DisplayLayout, source: WallpaperSource, customPath: String,
                      plainColorHex: String) async -> CGImage? {
        switch source {
        case .plainColor:
            return Self.solidImage(hex: plainColorHex)
        case .customImage:
            return customImage(at: customPath)
        case .desktop:
            // Read with the picture: a capture is kept under the file that was the desktop's as it started.
            let url = desktopImageURL(for: display)
            if let cached = desktopCache.picture(for: display.id, url: url) { return cached }
            let captured = try? await capture.captureWallpaper(displayCGFrame: layout.cgRect(fromAppKit: display.frame))
            let image = captured ?? url.flatMap(Self.loadImage(at:))
            if let image { desktopCache.store(image, for: display.id, url: url) }
            return image
        }
    }

    /// The part of `wallpaper` behind `cgRect`, mapping the display's frame onto the image as the desktop shows a
    /// picture: aspect-filled, centred, the overflow cropped. A picture of the display's own aspect maps onto the whole
    /// image; a wider one loses its sides, a taller one its top and bottom, and neither is stretched.
    public nonisolated static func crop(_ wallpaper: CGImage, displayCGFrame: CGRect, to cgRect: CGRect) -> CGImage? {
        let size = CGSize(width: wallpaper.width, height: wallpaper.height)
        // Pixels per point: the smaller ratio, so the display's frame lies inside the picture.
        let scale = min(size.width / displayCGFrame.width, size.height / displayCGFrame.height)
        let shown = CGRect(x: (size.width - displayCGFrame.width * scale) / 2,
                           y: (size.height - displayCGFrame.height * scale) / 2,
                           width: displayCGFrame.width * scale, height: displayCGFrame.height * scale)
        let pixels = CGRect(x: shown.minX + (cgRect.minX - displayCGFrame.minX) * scale,
                            y: shown.minY + (cgRect.minY - displayCGFrame.minY) * scale,
                            width: cgRect.width * scale,
                            height: cgRect.height * scale)
        return PostProcessor.cropped(wallpaper, to: pixels)
    }

    /// The display's desktop picture file, as macOS reports it; nil for a display with none known.
    private func desktopImageURL(for display: DisplayInfo) -> URL? {
        let screen = NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
        return screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
    }

    /// The custom wallpaper; nil when none is chosen, or when it can't be read, which is logged once per path.
    private func customImage(at path: String) -> CGImage? {
        guard !path.isEmpty else { return nil }
        if let image = Self.loadImage(at: URL(filePath: path)) { return image }
        if unreadableCustomPaths.insert(path).inserted {
            Log.capture.warning("The custom wallpaper at \(path) can't be read")
        }
        return nil
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static func solidImage(hex: String) -> CGImage? {
        let color = HexColor.cgColor(from: hex) ?? CGColor(gray: 0.12, alpha: 1)
        guard let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        return context.makeImage()
    }
}
