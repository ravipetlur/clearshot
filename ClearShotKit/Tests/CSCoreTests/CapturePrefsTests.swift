import CoreGraphics
import CSTestSupport
import Foundation
import Testing
@testable import CSCore

@MainActor
final class CapturePrefsTests {
    let throwaway = ThrowawayDefaults("capture")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func defaultsAreTheDecidedOnes() {
        #expect(prefs[Prefs.imageFormat] == .jpeg)
        #expect(prefs[Prefs.addBorderToScreenshots] == true)
        #expect(prefs[Prefs.windowBackground] == .transparent)
        #expect(prefs[Prefs.captureWindowShadow] == true)
        #expect(prefs[Prefs.wallpaperSource] == .desktop)
        #expect(prefs[Prefs.selfTimerSeconds] == 5)
        #expect(prefs[Prefs.lastCaptureArea].isEmpty)
        #expect(prefs[Prefs.captureAreaShortcutsIgnoreAfterCapture] == true)
    }

    @Test func savedAreaRoundTrips() {
        let area = SavedArea(rect: CGRect(x: -1700, y: 200, width: 640, height: 480), displayID: 2)
        prefs[Prefs.lastCaptureArea] = area
        #expect(Preferences(defaults: defaults)[Prefs.lastCaptureArea] == area)
        #expect(!area.isEmpty)
    }

    @Test func allInOneDefaults() {
        #expect(prefs[Prefs.allInOneRememberSelection] == true)
        #expect(prefs[Prefs.allInOneLastArea] == .none)
        #expect(prefs[Prefs.allInOneLastArea].isEmpty)
        let area = SavedArea(rect: CGRect(x: 100, y: 200, width: 300, height: 400), displayID: 3)
        prefs[Prefs.allInOneLastArea] = area
        prefs[Prefs.allInOneRememberSelection] = false
        let reopened = Preferences(defaults: defaults)
        #expect(reopened[Prefs.allInOneLastArea] == area)
        #expect(reopened[Prefs.allInOneRememberSelection] == false)
    }

    @Test func scrollingTipsOpenUntilTheyHaveBeenShown() {
        #expect(prefs[Prefs.scrollingTipsShown] == false)
        prefs[Prefs.scrollingTipsShown] = true
        #expect(Preferences(defaults: defaults)[Prefs.scrollingTipsShown] == true)
    }

    @Test func savedAreasResolveOnlyOnAPresentDisplay() throws {
        let layout = DisplayLayout.twoDisplaysWithPortraitSecondary
        let portrait = try #require(layout.display(id: 2))
        let onPortrait = CGRect(x: -1700, y: 200, width: 640, height: 480)
        let resolved = try #require(SavedArea(rect: onPortrait, displayID: 2).resolved(in: layout))
        #expect(resolved.rect == onPortrait)
        #expect(resolved.display == portrait)

        #expect(SavedArea(rect: CGRect(x: 10, y: 10, width: 100, height: 100), displayID: 99).resolved(in: layout) == nil)

        // Half off the portrait display (onto where the main display is): clamped to the portrait display.
        let half = try #require(SavedArea(rect: CGRect(x: -100, y: 200, width: 200, height: 300), displayID: 2).resolved(in: layout))
        #expect(half.rect == CGRect(x: -100, y: 200, width: 100, height: 300))
        #expect(half.display == portrait)

        // Only a 3-pt sliver is on the portrait display.
        #expect(SavedArea(rect: CGRect(x: -3, y: 200, width: 200, height: 300), displayID: 2).resolved(in: layout) == nil)
        // Unless a smaller minimum is asked for.
        #expect(SavedArea(rect: CGRect(x: -3, y: 200, width: 200, height: 300), displayID: 2)
            .resolved(in: layout, minimumSide: 2)?.rect == CGRect(x: -3, y: 200, width: 3, height: 300))
        #expect(SavedArea.none.resolved(in: layout) == nil)
    }

    @Test func formatsKnowTheirExtensionTypeAndTransparency() {
        #expect(ImageFormat.jpeg.fileExtension == "jpg")
        #expect(ImageFormat.webp.utType == "org.webmproject.webp")
        #expect(!ImageFormat.jpeg.supportsTransparency)
        #expect(ImageFormat.png.supportsTransparency)
        #expect(!ImageFormat.png.supportsQuality)
    }

    /// PNG and WebP are always lossless, so only JPEG and HEIC have a quality to set (Settings hides the slider otherwise).
    @Test func onlyTheLossyFormatsOfferQuality() {
        #expect(ImageFormat.jpeg.supportsQuality)
        #expect(ImageFormat.heic.supportsQuality)
        #expect(!ImageFormat.png.supportsQuality)
        #expect(!ImageFormat.webp.supportsQuality)
        #expect(ImageFormat.allCases.filter(\.supportsQuality) == [.jpeg, .heic])
    }

    @Test func shutterSoundsPointAtSystemFiles() {
        for sound in ShutterSound.allCases {
            #expect(FileManager.default.fileExists(atPath: sound.fileURL.path(percentEncoded: false)), "\(sound)")
        }
    }
}
