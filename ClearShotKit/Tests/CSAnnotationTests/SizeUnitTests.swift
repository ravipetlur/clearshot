import CoreGraphics
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSAnnotation

/// "Show sizes in": lengths on the picture in points or pixels.
struct SizeUnitTests {
    private func document(scale: Double, ops: [ImageOp] = []) -> AnnotationDocument {
        var document = AnnotationDocument(baseSize: CGSize(width: 200, height: 100), pixelScale: scale)
        document.imageOps = ops
        return document
    }

    @Test func pointsDivideByThePixelScale() {
        let retina = document(scale: 2)
        #expect(retina.displayedLength(outputPixels: 100, in: .pixels) == 100)
        #expect(retina.displayedLength(outputPixels: 100, in: .points) == 50)
        #expect(document(scale: 1).displayedLength(outputPixels: 100, in: .points) == 100)
    }

    @Test func aBaseRectIsMeasuredAsShown() {
        let rect = CGRect(x: 10, y: 10, width: 40, height: 10)
        #expect(document(scale: 2).displayedSize(ofBaseRect: rect, in: .pixels) == CGSize(width: 40, height: 10))
        #expect(document(scale: 2).displayedSize(ofBaseRect: rect, in: .points) == CGSize(width: 20, height: 5))
        // Turned, its width runs down the screen.
        #expect(document(scale: 2, ops: [.rotateRight]).displayedSize(ofBaseRect: rect, in: .points) == CGSize(width: 5, height: 20))
    }

    /// A Retina capture resized to half has half the pixels, and reads as 1x: its points are its pixels.
    @Test func aResizeChangesPixelsNotPoints() {
        let halved = document(scale: 2, ops: [.resize(width: 100, height: 50)])
        let rect = CGRect(x: 0, y: 0, width: 40, height: 10)
        #expect(halved.displayedSize(ofBaseRect: rect, in: .pixels) == CGSize(width: 20, height: 5))
        #expect(halved.displayedSize(ofBaseRect: rect, in: .points) == CGSize(width: 20, height: 5))
    }

    @Test func unitsHaveTitlesAndAbbreviations() {
        #expect(SizeUnit.allCases.map(\.title) == ["Points", "Pixels"])
        #expect(SizeUnit.allCases.map(\.abbreviation) == ["pt", "px"])
    }

    @MainActor
    @Test func preferencesDefaultAndPersist() {
        let throwaway = ThrowawayDefaults("size-unit")
        let preferences = Preferences(defaults: throwaway.defaults)
        #expect(preferences[Prefs.annotateSizeUnit] == .points)
        #expect(preferences[Prefs.annotateColorCopyFormat] == .hex)
        preferences[Prefs.annotateSizeUnit] = .pixels
        preferences[Prefs.annotateColorCopyFormat] = .oklch
        let reread = Preferences(defaults: throwaway.defaults)
        #expect(reread[Prefs.annotateSizeUnit] == .pixels)
        #expect(reread[Prefs.annotateColorCopyFormat] == .oklch)
    }
}
