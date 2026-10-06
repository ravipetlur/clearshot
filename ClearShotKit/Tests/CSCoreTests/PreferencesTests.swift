import CSTestSupport
import Foundation
import Observation
import Testing
@testable import CSCore

private struct Sample: JSONPrefValue, Equatable {
    var count: Int
    var label: String
}

private final class Flag: @unchecked Sendable {
    var value = false
}

@MainActor
final class PreferencesTests {
    let throwaway = ThrowawayDefaults("preferences")
    let defaults: UserDefaults
    let prefs: Preferences

    init() {
        defaults = throwaway.defaults
        prefs = Preferences(defaults: defaults)
    }

    @Test func returnsDefaultsWhenNothingIsStored() {
        #expect(prefs[Prefs.showMenuBarIcon] == true)
        #expect(prefs[Prefs.playSounds] == false)
        #expect(prefs[Prefs.fileNameNextAutoIncrement] == 1)
        #expect(prefs.hasValue(Prefs.playSounds) == false)
    }

    @Test func theDefaultSaveFolderComesFromTheBuildOrIsTheDesktop() {
        let home = URL(filePath: "/tmp/home/", directoryHint: .isDirectory)
        func folder(_ value: String?) -> String {
            Prefs.defaultExportLocation(folder: value, home: home).path(percentEncoded: false)
        }
        #expect(folder(nil) == "/tmp/home/Desktop/")
        #expect(folder("") == "/tmp/home/Desktop/")
        #expect(folder("  ") == "/tmp/home/Desktop/")
        #expect(folder("Downloads/screenshot") == "/tmp/home/Downloads/screenshot/")
        #expect(folder("Pictures/Screenshots/") == "/tmp/home/Pictures/Screenshots/")
        #expect(folder("/etc") == "/tmp/home/Desktop/")
        #expect(folder("~/Documents") == "/tmp/home/Desktop/")
        #expect(folder("../outside") == "/tmp/home/Desktop/")
        #expect(folder("Pictures/../../outside") == "/tmp/home/Desktop/")
    }

    @Test func defaultsAreTheDecidedOnes() {
        #expect(prefs[Prefs.afterScreenshotActions] == [.showQuickAccess, .copy, .save])
        #expect(prefs[Prefs.afterRecordingActions] == [.showQuickAccess, .copy, .save])
        #expect(prefs[Prefs.exportLocation].path(percentEncoded: false).hasSuffix("/Desktop/"))
        #expect(prefs[Prefs.exportLocation].path(percentEncoded: false)
            .hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)))
        #expect(prefs[Prefs.fileNameTemplate].stringValue == "Screenshot %y-%m-%d at %H.%M.%S")
        #expect(prefs[Prefs.hideDesktopIconsWhileCapturing] == true)
        #expect(prefs[Prefs.clipboardMode] == .fileAndImage)
    }

    @Test func pinDefaultsAreAllOn() {
        #expect(prefs[Prefs.pinShadow])
        #expect(prefs[Prefs.pinRoundedCorners])
        #expect(prefs[Prefs.pinBorder])
        #expect(PinStyle.defaults(in: prefs) == PinStyle(shadow: true, roundedCorners: true, border: true))
        prefs[Prefs.pinShadow] = false
        prefs[Prefs.pinBorder] = false
        #expect(PinStyle.defaults(in: prefs) == PinStyle(shadow: false, roundedCorners: true, border: false))
        prefs[Prefs.pinRoundedCorners] = false
        #expect(PinStyle.defaults(in: prefs) == PinStyle(shadow: false, roundedCorners: false, border: false))
    }

    @Test func desktopIconsStartShown() {
        #expect(!prefs[Prefs.desktopIconsHidden])
        prefs[Prefs.desktopIconsHidden] = true
        #expect(Preferences(defaults: defaults)[Prefs.desktopIconsHidden])
    }

    @Test func roundTripsEveryValueKind() {
        prefs[Prefs.playSounds] = true
        prefs[Prefs.fileNameNextAutoIncrement] = 42
        prefs[Prefs.exportLocation] = URL(filePath: "/tmp/shots", directoryHint: .isDirectory)
        prefs[Prefs.clipboardMode] = .imageOnly
        prefs[Prefs.afterScreenshotActions] = [.pin]
        prefs[Prefs.fileNameTemplate] = FileNameTemplate(parsing: "Shot %i")

        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded[Prefs.playSounds] == true)
        #expect(reloaded[Prefs.fileNameNextAutoIncrement] == 42)
        #expect(reloaded[Prefs.exportLocation].path(percentEncoded: false) == "/tmp/shots/")
        #expect(reloaded[Prefs.clipboardMode] == .imageOnly)
        #expect(reloaded[Prefs.afterScreenshotActions] == [.pin])
        #expect(reloaded[Prefs.fileNameTemplate].stringValue == "Shot %i")
    }

    @Test func wrongTypeFallsBackToDefault() {
        defaults.set("not a bool", forKey: Prefs.showMenuBarIcon.name)
        defaults.set(["bogus"], forKey: Prefs.clipboardMode.name)
        defaults.set(["nope", "copy"], forKey: Prefs.afterScreenshotActions.name)
        #expect(prefs[Prefs.showMenuBarIcon] == true)
        #expect(prefs[Prefs.clipboardMode] == .fileAndImage)
        #expect(prefs[Prefs.afterScreenshotActions] == [.copy])
    }

    @Test func resetRemovesTheStoredValue() {
        prefs[Prefs.playSounds] = true
        prefs.reset(Prefs.playSounds)
        #expect(prefs[Prefs.playSounds] == false)
        #expect(prefs.hasValue(Prefs.playSounds) == false)
    }

    @Test func jsonValuesRoundTrip() {
        let key = PrefKey("sample", default: Sample(count: 0, label: ""))
        prefs[key] = Sample(count: 3, label: "three")
        #expect(Preferences(defaults: defaults)[key] == Sample(count: 3, label: "three"))
    }

    @Test func changesNotifyObservers() {
        let changed = Flag()
        withObservationTracking {
            _ = prefs[Prefs.playSounds]
        } onChange: {
            changed.value = true
        }
        prefs[Prefs.playSounds] = true
        #expect(changed.value)
    }

    @Test func afterCaptureTogglingNeverLeavesTheSetEmpty() {
        #expect(AfterCaptureAction.toggling(.copy, in: [.copy], on: false) == nil)
        #expect(AfterCaptureAction.toggling(.copy, in: [.copy, .save], on: false) == [.save])
        #expect(AfterCaptureAction.toggling(.pin, in: [.copy], on: true) == [.copy, .pin])
    }
}
