import CoreGraphics
import CoreVideo
import CSCore
import Testing
@testable import CSCapture

struct RegionStreamGeometryTests {
    // Two displays in AppKit global points: the main display, and a portrait display left of and below it.
    static let main = DisplayInfo(id: 3, name: "Main Display", frame: CGRect(x: 0, y: 0, width: 3360, height: 1890),
                                  scale: 2, isBuiltIn: false, safeAreaTop: 0)
    static let portrait = DisplayInfo(id: 2, name: "Portrait Display",
                                      frame: CGRect(x: -1800, y: -819, width: 1800, height: 3200),
                                      scale: 2, isBuiltIn: false, safeAreaTop: 0)
    let layout = DisplayLayout(displays: [Self.main, Self.portrait])

    @Test func aRegionOnThePortraitDisplayMapsToDisplayLocalPoints() {
        // 100 pt in from the portrait display's left edge; its top is 2 381 − 680 = 1 701 pt below the display's top
        // edge.
        let region = CGRect(x: -1700, y: 200, width: 640, height: 480)
        let geometry = RegionStreamGeometry.make(region: region, display: Self.portrait, layout: layout)
        #expect(geometry.sourceRect == CGRect(x: 100, y: 1701, width: 640, height: 480))
        #expect(geometry.pixelWidth == 1280)
        #expect(geometry.pixelHeight == 960)
        #expect(geometry.globalRect == region)
    }

    @Test func aFractionalRegionIsSnappedOutwardToWholePixels() {
        // On the main display (top at 1 890 pt) the region is local (10.25, 1 819.15, 100.3, 50.1): in pixels
        // x 20.5…221.1 and y 3 638.3…3 738.5, snapped outward to 20…222 and 3 638…3 739.
        let region = CGRect(x: 10.25, y: 20.75, width: 100.3, height: 50.1)
        let geometry = RegionStreamGeometry.make(region: region, display: Self.main, layout: layout)
        #expect(geometry.sourceRect == CGRect(x: 10, y: 1819, width: 101, height: 50.5))
        for edge in [geometry.sourceRect.minX, geometry.sourceRect.minY, geometry.sourceRect.maxX, geometry.sourceRect.maxY] {
            let pixels = edge * Self.main.scale
            #expect(pixels == pixels.rounded(), "edge \(edge) pt is \(pixels) px")
        }
        #expect(geometry.pixelWidth == 202)
        #expect(geometry.pixelHeight == 101)
        #expect(CGFloat(geometry.pixelWidth) == geometry.sourceRect.width * Self.main.scale)
        #expect(CGFloat(geometry.pixelHeight) == geometry.sourceRect.height * Self.main.scale)
        #expect(geometry.globalRect == CGRect(x: 10, y: 20.5, width: 101, height: 50.5))
    }

    @Test func theSnappedGlobalRectContainsTheRegion() {
        let region = CGRect(x: -1234.6, y: 345.3, width: 321.7, height: 211.1)
        let geometry = RegionStreamGeometry.make(region: region, display: Self.portrait, layout: layout)
        #expect(geometry.globalRect.contains(region))
        // Outward by less than a pixel (half a point at 2×) on every side.
        #expect(region.minX - geometry.globalRect.minX < 0.5)
        #expect(region.minY - geometry.globalRect.minY < 0.5)
        #expect(geometry.globalRect.maxX - region.maxX < 0.5)
        #expect(geometry.globalRect.maxY - region.maxY < 0.5)
        // The global rect is the source rect, back in AppKit points.
        #expect(layout.localRect(geometry.globalRect, in: Self.portrait) == geometry.sourceRect)
        #expect(CGFloat(geometry.pixelWidth) == geometry.globalRect.width * Self.portrait.scale)
        #expect(CGFloat(geometry.pixelHeight) == geometry.globalRect.height * Self.portrait.scale)
    }
}

struct RegionFrameCopyTests {
    @Test func aPaddedPixelBufferIsCopiedIntoTightRows() throws {
        // 101-pixel rows are 404 bytes; Core Video pads them to its alignment, as it does most region widths.
        var created: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 101, 3, kCVPixelFormatType_32BGRA, attributes, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        let paddedBytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        #expect(paddedBytesPerRow > 404)
        func byte(row: Int, at offset: Int) -> UInt8 { UInt8((row * 7 + offset) % 251) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        for row in 0..<3 {
            for offset in 0..<paddedBytesPerRow {
                base[row * paddedBytesPerRow + offset] = offset < 404 ? byte(row: row, at: offset) : 0xEE
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let frame = try #require(RegionStream.frame(from: buffer))
        #expect(frame.width == 101 && frame.height == 3 && frame.bytesPerRow == 404)
        #expect(frame.pixels == (0..<3).flatMap { row in (0..<404).map { byte(row: row, at: $0) } })
        // No colour attachments: sRGB.
        #expect(frame.colorSpace.name == CGColorSpace.sRGB)
    }
}

/// A stream's run-once rule, kept under its runner's lock. (A live stream is never started from a test.)
struct StreamLifecycleTests {
    @Test func aStreamStartsAtMostOnce() {
        var lifecycle = StreamLifecycle()
        let first = lifecycle.claimStart()
        let second = lifecycle.claimStart()
        #expect(first)
        #expect(!second)
        #expect(!lifecycle.hasStopped)
    }

    @Test func aStoppedStreamNeverStarts() {
        var neverStarted = StreamLifecycle()
        neverStarted.stop()
        let startAfterStop = neverStarted.claimStart()
        #expect(!startAfterStop)
        #expect(neverStarted.hasStopped)

        var stoppedAfterStarting = StreamLifecycle()
        let start = stoppedAfterStarting.claimStart()
        stoppedAfterStarting.stop()
        let restart = stoppedAfterStarting.claimStart()
        #expect(start)
        #expect(!restart)
        #expect(stoppedAfterStarting.hasStopped)
    }
}
