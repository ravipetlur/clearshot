import CoreGraphics
import CSCore
import CSTestSupport
import Foundation
import Testing
@testable import CSCapture

struct SelectionRatioTests {
    @Test func presetsAreTheDecidedOnesInOrder() {
        #expect(SelectionRatio.presets.map(\.title) == ["1:1", "4:3", "3:2", "16:10", "16:9", "5:4", "9:16", "3:4", "2:3", "4:5"])
        #expect(SelectionRatio.presets.first == .preset(width: 1, height: 1))
        #expect(SelectionRatio.presets.allSatisfy { if case .preset = $0 { true } else { false } })
    }

    @Test func swapTurnsAPresetIntoItsPartnerOrACustomRatio() {
        #expect(SelectionRatio.preset(width: 16, height: 9).swapped() == .preset(width: 9, height: 16))
        #expect(SelectionRatio.preset(width: 9, height: 16).swapped() == .preset(width: 16, height: 9))
        #expect(SelectionRatio.preset(width: 1, height: 1).swapped() == .preset(width: 1, height: 1))
        #expect(SelectionRatio.preset(width: 16, height: 10).swapped() == .custom(width: 10, height: 16))
        #expect(SelectionRatio.custom(width: 7, height: 3).swapped() == .custom(width: 3, height: 7))
        #expect(SelectionRatio.freeform.swapped() == .freeform)
    }

    @Test func freeformHasNoAspect() {
        #expect(SelectionRatio.freeform.aspect == nil)
        #expect(SelectionRatio.freeform.title == "Freeform")
        // Typed constants: compared with a bare `16.0 / 9.0` literal inside `#expect`, an equal CGFloat fails.
        let sixteenNine: CGFloat = 16.0 / 9.0
        let sevenThree: CGFloat = 7.0 / 3.0
        #expect(SelectionRatio.preset(width: 16, height: 9).aspect == sixteenNine)
        #expect(SelectionRatio.custom(width: 7, height: 3).aspect == sevenThree)
        #expect(SelectionRatio.custom(width: 7, height: 3).title == "7:3")
        // A side of zero (only reachable through a damaged stored value) is no lock either.
        #expect(SelectionRatio.custom(width: 7, height: 0).aspect == nil)
    }

    @MainActor @Test func ratiosRoundTripThroughPreferences() {
        withThrowawayDefaults("ratio") { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs[Prefs.allInOneRatio] == .freeform)
            prefs[Prefs.allInOneRatio] = .custom(width: 7, height: 3)
            #expect(Preferences(defaults: defaults)[Prefs.allInOneRatio] == .custom(width: 7, height: 3))
            prefs[Prefs.allInOneRatio] = .preset(width: 16, height: 9)
            #expect(Preferences(defaults: defaults)[Prefs.allInOneRatio] == .preset(width: 16, height: 9))
            // A stored value that doesn't decode falls back to the default.
            defaults.set(Data("not a ratio".utf8), forKey: Prefs.allInOneRatio.name)
            #expect(Preferences(defaults: defaults)[Prefs.allInOneRatio] == .freeform)
        }
    }
}
