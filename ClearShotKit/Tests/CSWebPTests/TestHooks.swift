@testable import CSWebP

// Conveniences the tests use on the encoder's types. The encoder itself has no use for them, so they live here and
// not in the module.

extension BackwardReferences {
    /// `codedWithBestCache` as the symbols it makes, kept, without the counts and the cost.
    static func findWithBestCache(
        pixels: [UInt32], width: Int
    ) -> (symbols: [EntropyImageWriter.Symbol], cacheBits: Int) {
        let coded = codedWithBestCache(pixels: pixels, width: width)
        return (symbols(pixels: pixels, width: width, matches: coded.matches, cacheBits: coded.cacheBits),
                coded.cacheBits)
    }

    /// The colour-cache size that `chooseCoding` picks.
    static func chooseCacheBits(pixels: [UInt32], width: Int) -> Int {
        chooseCoding(pixels: pixels, width: width).cacheBits
    }
}

extension PredictorTransform {
    /// The residual image as a new array, leaving `pixels` as they are (the encoder turns them into residuals in place).
    static func residuals(pixels: [UInt32], width: Int, height: Int, sizeBits: Int, modes: [UInt8]) -> [UInt32] {
        var residuals = pixels
        replaceWithResiduals(&residuals, width: width, height: height, sizeBits: sizeBits, modes: modes)
        return residuals
    }
}
