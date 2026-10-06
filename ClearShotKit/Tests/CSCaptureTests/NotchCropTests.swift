import CoreGraphics
import CSCore
import Testing
@testable import CSCapture

struct NotchCropTests {
    let builtIn = DisplayInfo(id: 1, name: "Built-in", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                              scale: 2, isBuiltIn: true, safeAreaTop: 32)
    let cgFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test func cropsTheNotchBandWhenAFullScreenAppAvoidsIt() {
        let belowNotch = CGRect(x: 0, y: 32, width: 1512, height: 950)
        #expect(NotchCrop.pixels(for: builtIn, kind: .display, frontmostAppWindowFrames: [belowNotch], displayCGFrame: cgFrame) == 64)
    }

    @Test func doesNothingForNormalWindowsSelectionsOrExternalDisplays() {
        let normal = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(NotchCrop.pixels(for: builtIn, kind: .display, frontmostAppWindowFrames: [normal], displayCGFrame: cgFrame) == 0)
        #expect(NotchCrop.pixels(for: builtIn, kind: .selection, frontmostAppWindowFrames: [cgFrame], displayCGFrame: cgFrame) == 0)
        let external = DisplayInfo(id: 2, name: "Ext", frame: cgFrame, scale: 2, isBuiltIn: false, safeAreaTop: 0)
        #expect(NotchCrop.pixels(for: external, kind: .display, frontmostAppWindowFrames: [cgFrame], displayCGFrame: cgFrame) == 0)
    }
}
