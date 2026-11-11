import CoreGraphics
import CSCore
import Foundation

/// The two main colors of an area of the picture and how readable one is on the other: what the contrast readout beside a
/// pixel selection's size shows.
///
/// **Finding the colors.** The area's pixels (every pixel, or a regular sample of a very large area) are grouped by their color
/// at 4 bits per channel, which merges the shades of one flat color (a gradient's neighbours, a compression's noise). The most
/// common group is the main color. The second is the most common group that differs meaningfully from it (at least two steps
/// apart in a channel, so about 32 levels) and covers at least half a percent of the area; a group close to the main color is
/// part of its edge, not another color. Each color is the average of its group's pixels. With no such second group the area is
/// uniform and there is no contrast to show (`init?` returns nil).
///
/// **Which is the background.** The one covering more of the area; the lighter one when they cover the same. A line of text is
/// the smaller part of its area, so the page behind it is the background, and a light text on a dark panel reads as it is.
public struct SelectionContrast: Equatable, Sendable {
    /// The color behind (the larger part of the area, or the lighter one on a tie).
    public let background: RGBAColor
    /// The other color: the "text".
    public let foreground: RGBAColor
    /// WCAG 2's contrast ratio, 1...21.
    public let ratio: Double
    /// APCA's lightness contrast of `foreground` on `background`: positive for dark on light, negative for light on dark.
    public let apca: Double

    /// How a WCAG 2 ratio stands against the thresholds.
    public enum Level: Equatable, Sendable {
        /// 7 or more.
        case aaa
        /// 4.5 or more.
        case aa
        /// 3 or more: enough for large text only.
        case aaLarge
        case fail

        public init(ratio: Double) {
            self = if ratio >= 7 { .aaa } else if ratio >= 4.5 { .aa } else if ratio >= 3 { .aaLarge } else { .fail }
        }

        /// What the readout shows after the ratio.
        public var title: String {
            switch self {
            case .aaa: "AAA"
            case .aa: "AA"
            case .aaLarge: "AA large"
            case .fail: "Fail"
            }
        }

        public var passes: Bool { self != .fail }
    }

    public var level: Level { Level(ratio: ratio) }

    /// The ratio as "4.5:1" or "21:1". Cut to one decimal rather than rounded, so a ratio shown as 4.5 does pass AA.
    public var ratioText: String {
        let tenths = Int((ratio * 10 + 1e-9).rounded(.down))
        let whole = tenths / 10, fraction = tenths % 10
        return fraction == 0 ? "\(whole):1" : "\(whole).\(fraction):1"
    }

    /// APCA's value as "Lc 62" (its size; which is darker is in the sign of `apca`).
    public var apcaText: String { "Lc \(Int(abs(apca).rounded()))" }

    /// The most pixels read; a larger area is read on a regular grid.
    static let sampleLimit = 1_000_000
    /// How far apart two groups must be, in steps of 16 levels in some channel, to be two colors.
    static let minimumStepDistance = 2
    /// The share of the area a second color must cover.
    static let minimumShare = 0.005

    /// The contrast of `rect` (the sampler's own pixels) in `sampler`, or nil when it is uniform, empty or transparent.
    /// Pixels that are more than half transparent are left out: their color is mostly what is behind them.
    public init?(in rect: CGRect, of sampler: PixelSampler) {
        guard let range = sampler.pixelRange(of: rect) else { return nil }
        let step = max(1, Int((Double(range.x.count * range.y.count) / Double(Self.sampleLimit)).squareRoot().rounded(.up)))
        var groups: [Int: Group] = [:]
        var total = 0
        for y in stride(from: range.y.lowerBound, to: range.y.upperBound, by: step) {
            for x in stride(from: range.x.lowerBound, to: range.x.upperBound, by: step) {
                guard let pixel = sampler.pixel(x: x, y: y), pixel.alpha >= 128 else { continue }
                let color = pixel.color
                let r = Int((color.red * 255).rounded()), g = Int((color.green * 255).rounded()), b = Int((color.blue * 255).rounded())
                let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
                groups[key, default: Group()].add(r, g, b)
                total += 1
            }
        }
        // Ties are broken by the key, so the result doesn't depend on the dictionary's order.
        let ranked = groups.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        guard let main = ranked.first else { return nil }
        let minimumCount = max(1, Int((Double(total) * Self.minimumShare).rounded(.up)))
        guard let other = ranked.dropFirst().first(where: {
            $0.value.count >= minimumCount && Self.stepDistance($0.key, main.key) >= Self.minimumStepDistance
        }) else { return nil }
        let first = main.value.color, second = other.value.color
        let secondIsLighter = ColorContrast.relativeLuminance(of: second) > ColorContrast.relativeLuminance(of: first)
        // `main` has at least as many pixels as `other`, so it is the background unless they tie and the other is lighter.
        let otherIsBackground = main.value.count == other.value.count && secondIsLighter
        background = otherIsBackground ? second : first
        foreground = otherIsBackground ? first : second
        ratio = ColorContrast.wcagRatio(background, foreground)
        apca = ColorContrast.apcaContrast(text: foreground, background: background)
    }

    /// The largest difference between two groups' keys in any channel.
    private static func stepDistance(_ a: Int, _ b: Int) -> Int {
        max(abs((a >> 8) - (b >> 8)), abs((a >> 4 & 15) - (b >> 4 & 15)), abs((a & 15) - (b & 15)))
    }

    /// The pixels of one group of colors: how many, and their sum, for the average.
    private struct Group {
        var count = 0
        var red = 0, green = 0, blue = 0

        mutating func add(_ r: Int, _ g: Int, _ b: Int) {
            count += 1
            red += r
            green += g
            blue += b
        }

        var color: RGBAColor {
            let n = Double(count) * 255
            return RGBAColor(red: Double(red) / n, green: Double(green) / n, blue: Double(blue) / n)
        }
    }
}
