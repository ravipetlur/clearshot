/// What "Quality" and "Optimize GIFs" mean to the encoder.
///
/// Optimize off keeps every change: threshold 0, 255 colours, dithering on. Optimize on absorbs the intermediate's
/// decode noise and trades quality for size: the stabiliser's threshold is 6 at quality 100, rising to 12 at quality 0
/// (measured at ±2 noise: 6 shrank 15 MB to 0.57 MB at 44 dB); the palette has round(255 × (0.25 + 0.75 × quality ÷
/// 100)) colours; dithering from quality 70.
public struct GIFQualityPlan: Sendable, Equatable {
    /// How far (per channel) a pixel may move from what the viewer shows before it counts as changed.
    public let threshold: Int
    public let paletteColors: Int
    public let dithers: Bool

    /// `quality` is clamped to 0…100.
    public init(quality: Int, optimize: Bool) {
        let quality = Double(min(max(quality, 0), 100))
        if optimize {
            threshold = 6 + Int((6 * (100 - quality) / 100).rounded())
            paletteColors = Int((255 * (0.25 + 0.75 * quality / 100)).rounded())
            dithers = quality >= 70
        } else {
            threshold = 0
            paletteColors = 255
            dithers = true
        }
    }

    /// A plan the settings can't make (threshold 0 without dithering, say), for measuring the encoder.
    init(threshold: Int, paletteColors: Int, dithers: Bool) {
        self.threshold = threshold
        self.paletteColors = paletteColors
        self.dithers = dithers
    }
}
