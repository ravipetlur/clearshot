import CoreGraphics
import Testing
@testable import CSCore

struct PinGeometryTests {
    @Test func pinStyleForATransparentImageKeepsOnlyTheShadow() {
        let allOn = PinStyle(shadow: true, roundedCorners: true, border: true)
        #expect(allOn.effective(isTransparent: true) == PinStyle(shadow: true, roundedCorners: false, border: false))
        #expect(allOn.effective(isTransparent: false) == allOn)
        let noShadow = PinStyle(shadow: false, roundedCorners: true, border: true)
        #expect(noShadow.effective(isTransparent: true) == PinStyle(shadow: false, roundedCorners: false, border: false))
    }

    @Test func aRetinaImageIsMeasuredInPoints() {
        let pixels = CGSize(width: 800, height: 600)
        #expect(PinGeometry.imagePoints(pixelSize: pixels, scale: 2) == CGSize(width: 400, height: 300))
        #expect(PinGeometry.imagePoints(pixelSize: pixels, scale: 0) == pixels)
        #expect(PinGeometry.imagePoints(pixelSize: pixels, scale: .nan) == pixels)
        #expect(PinGeometry.imagePoints(pixelSize: pixels, scale: -2) == pixels)
        #expect(PinGeometry.imagePoints(pixelSize: pixels, scale: .infinity) == pixels)
    }

    @Test func aTwelvePixelIconGetsA48PointWindowWithTheIconAtItsOwnSize() {
        let icon = CGSize(width: 12, height: 12)
        #expect(PinGeometry.windowSize(imagePoints: icon, zoom: 1) == CGSize(width: 48, height: 48))
        #expect(PinGeometry.imageRect(imagePoints: icon, zoom: 1) == CGRect(x: 18, y: 18, width: 12, height: 12))
    }

    @Test func aThinStripGetsTheMinimumOnItsShortSideOnly() {
        let strip = CGSize(width: 600, height: 10)
        #expect(PinGeometry.windowSize(imagePoints: strip, zoom: 1) == CGSize(width: 600, height: 48))
        #expect(PinGeometry.imageRect(imagePoints: strip, zoom: 1) == CGRect(x: 0, y: 19, width: 600, height: 10))
    }

    @Test func halfZoomHalvesTheWindow() {
        let image = CGSize(width: 400, height: 300)
        #expect(PinGeometry.windowSize(imagePoints: image, zoom: 0.5) == CGSize(width: 200, height: 150))
        #expect(PinGeometry.imageRect(imagePoints: image, zoom: 0.5) == CGRect(x: 0, y: 0, width: 200, height: 150))
    }

    @Test func zoomIsClampedTo10To800Percent() {
        let image = CGSize(width: 100, height: 100)
        #expect(PinGeometry.maximumZoom(imagePoints: image) == 8)
        #expect(PinGeometry.clampedZoom(0.01, imagePoints: image) == 0.1)
        #expect(PinGeometry.clampedZoom(20, imagePoints: image) == 8)
        #expect(PinGeometry.clampedZoom(.nan, imagePoints: image) == 1)
        #expect(PinGeometry.clampedZoom(1.3, imagePoints: image) == 1.3)
    }

    @Test func zoomNeverMakesTheWindowLongerThan8000Points() {
        let display = CGSize(width: 3360, height: 1890)
        let ceiling = PinGeometry.maximumZoom(imagePoints: display)
        #expect(abs(ceiling - 8000.0 / 3360.0) < 1e-9)
        #expect(PinGeometry.clampedZoom(4, imagePoints: display) == ceiling)
        #expect(PinGeometry.nextZoom(after: 2, imagePoints: display) == nil)
        #expect(PinGeometry.nextZoom(after: 1.5, imagePoints: display) == 2)
        // However long the image, the ceiling never drops below the 10% floor.
        #expect(PinGeometry.maximumZoom(imagePoints: CGSize(width: 200_000, height: 10)) == 0.1)
    }

    @Test func opacityIsClampedTo10To100Percent() {
        #expect(PinGeometry.clampedOpacity(0) == 0.1)
        #expect(PinGeometry.clampedOpacity(1.5) == 1)
        #expect(PinGeometry.clampedOpacity(.nan) == 1)
        #expect(PinGeometry.clampedOpacity(0.4) == 0.4)
        #expect(PinGeometry.opacityPresets == [0.25, 0.5, 0.75, 1])
    }

    @Test func pinchZoomKeepsThePointUnderThePointer() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        #expect(PinGeometry.zoomed(frame, to: CGSize(width: 800, height: 600), anchor: CGPoint(x: 200, y: 175))
            == CGRect(x: 0, y: 25, width: 800, height: 600))
    }

    @Test func keyboardZoomKeepsTheCentre() {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let size = CGSize(width: 800, height: 600)
        let aboutTheCentre = CGRect(x: -100, y: -50, width: 800, height: 600)
        #expect(PinGeometry.zoomed(frame, to: size, anchor: nil) == aboutTheCentre)
        #expect(PinGeometry.zoomed(frame, to: size, anchor: CGPoint(x: 900, y: 175)) == aboutTheCentre)
    }

    @Test func presetStepsUpAndDown() {
        let image = CGSize(width: 100, height: 100)
        #expect(PinGeometry.zoomPresets == [0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4])
        #expect(PinGeometry.nextZoom(after: 1, imagePoints: image) == 1.5)
        #expect(PinGeometry.previousZoom(before: 1) == 0.75)
        #expect(PinGeometry.nextZoom(after: 1.2, imagePoints: image) == 1.5)
        #expect(PinGeometry.previousZoom(before: 1.2) == 1)
        #expect(PinGeometry.previousZoom(before: 0.25) == nil)
        #expect(PinGeometry.nextZoom(after: 4, imagePoints: image) == nil)
        // A zoom a hair off a preset counts as on it, so a step never lands on the same preset.
        #expect(PinGeometry.nextZoom(after: 0.9995, imagePoints: image) == 1.5)
        #expect(PinGeometry.previousZoom(before: 1.0005) == 0.75)
    }

    @Test func theCurrentPresetIsTheNearestWithinHalfAPercent() {
        #expect(PinGeometry.isCurrent(0.5, 0.503))
        #expect(!PinGeometry.isCurrent(0.5, 0.51))
    }

    @Test func scrollingUpRaisesAndDownLowersOpacity() {
        #expect(abs(PinGeometry.opacity(0.5, scrolledUp: 20, precise: true) - 0.6) < 1e-9)
        #expect(abs(PinGeometry.opacity(0.5, scrolledUp: 1, precise: false) - 0.55) < 1e-9)
        #expect(PinGeometry.opacity(0.95, scrolledUp: 40, precise: true) == 1)
        #expect(PinGeometry.opacity(0.15, scrolledUp: -20, precise: true) == 0.1)
    }

    @Test func arrowsMoveOneOrTenPoints() {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 300)
        #expect(PinGeometry.nudged(frame, .right, large: false) == CGRect(x: 101, y: 200, width: 400, height: 300))
        #expect(PinGeometry.nudged(frame, .up, large: true) == CGRect(x: 100, y: 210, width: 400, height: 300))
        #expect(PinGeometry.nudged(frame, .left, large: true) == CGRect(x: 90, y: 200, width: 400, height: 300))
        #expect(PinGeometry.nudged(frame, .down, large: false) == CGRect(x: 100, y: 199, width: 400, height: 300))
    }
}
