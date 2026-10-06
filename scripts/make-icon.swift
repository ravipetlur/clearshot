// Renders ClearShot's app icon into Assets.xcassets/AppIcon.appiconset.
// Workspace icon style: full-bleed macOS rounded square, a two-stop vertical gradient in the app's hue,
// one white custom glyph (no SF Symbols in icons), a subtle top highlight.
// Usage: swift scripts/make-icon.swift ClearShot/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(filePath: CommandLine.arguments.dropFirst().first ?? "ClearShot/Resources/Assets.xcassets/AppIcon.appiconset",
                          directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let top = NSColor(srgbRed: 0x2B / 255, green: 0xB5 / 255, blue: 0xC9 / 255, alpha: 1)   // teal
let bottom = NSColor(srgbRed: 0x25 / 255, green: 0x63 / 255, blue: 0xEB / 255, alpha: 1) // blue

/// A continuous-corner rounded square (superellipse, n = 5) approximating the macOS icon shape.
func squirclePath(in rect: CGRect) -> NSBezierPath {
    let path = NSBezierPath()
    let n = 5.0
    let a = rect.width / 2, b = rect.height / 2
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let steps = 720
    for step in 0...steps {
        let t = Double(step) / Double(steps) * 2 * .pi
        let cosT = cos(t), sinT = sin(t)
        let x = center.x + a * (cosT < 0 ? -1 : 1) * pow(abs(cosT), 2 / n)
        let y = center.y + b * (sinT < 0 ? -1 : 1) * pow(abs(sinT), 2 / n)
        if step == 0 {
            path.move(to: CGPoint(x: x, y: y))
        } else {
            path.line(to: CGPoint(x: x, y: y))
        }
    }
    path.close()
    return path
}

func renderIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform()
    transform.scale(by: size / 1024)
    transform.concat()

    // Standard macOS icon grid: 824×824 body inside a 1024 canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: body)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: top, ending: bottom)!.draw(in: shape, angle: -90)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Glyph: viewfinder corners around an aperture dot.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    let frame = CGRect(x: 292, y: 292, width: 440, height: 440)
    let arm: CGFloat = 130
    let corners = NSBezierPath()
    corners.lineWidth = 44
    corners.lineCapStyle = .round
    corners.lineJoinStyle = .round
    // bottom-left
    corners.move(to: CGPoint(x: frame.minX, y: frame.minY + arm))
    corners.line(to: CGPoint(x: frame.minX, y: frame.minY))
    corners.line(to: CGPoint(x: frame.minX + arm, y: frame.minY))
    // bottom-right
    corners.move(to: CGPoint(x: frame.maxX - arm, y: frame.minY))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.minY))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.minY + arm))
    // top-right
    corners.move(to: CGPoint(x: frame.maxX, y: frame.maxY - arm))
    corners.line(to: CGPoint(x: frame.maxX, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.maxX - arm, y: frame.maxY))
    // top-left
    corners.move(to: CGPoint(x: frame.minX + arm, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.minX, y: frame.maxY))
    corners.line(to: CGPoint(x: frame.minX, y: frame.maxY - arm))
    corners.stroke()
    NSBezierPath(ovalIn: CGRect(x: 512 - 70, y: 512 - 70, width: 140, height: 140)).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

struct Variant {
    let points: Int
    let scale: Int
}

let variants = [16, 32, 128, 256, 512].flatMap { [Variant(points: $0, scale: 1), Variant(points: $0, scale: 2)] }
var images: [[String: String]] = []
for variant in variants {
    let suffix = variant.scale == 2 ? "@2x" : ""
    let name = "icon_\(variant.points)x\(variant.points)\(suffix).png"
    try renderIcon(pixels: variant.points * variant.scale).write(to: outputDirectory.appending(path: name))
    images.append(["idiom": "mac", "size": "\(variant.points)x\(variant.points)", "scale": "\(variant.scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: outputDirectory.appending(path: "Contents.json"))
print("Wrote \(variants.count) icons to \(outputDirectory.path(percentEncoded: false))")
