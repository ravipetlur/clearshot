import Foundation
import Testing
@testable import CSAPI

/// Before a command that captures or selects on screen, the activation goes back to the app that had it when ClearShot
/// is active only because of the URL.
struct URLActivationTests {
    typealias KeyWindow = URLActivation.KeyWindow
    let receivedAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func handsBack(active: Bool, keyWindow: KeyWindow, since: TimeInterval?) -> Bool {
        URLActivation.handsBack(isActive: active, keyWindow: keyWindow,
                                activeSince: since.map(receivedAt.addingTimeInterval), receivedAt: receivedAt)
    }

    @Test func nothingIsHandedBackWhileClearShotIsntActive() {
        for keyWindow in [KeyWindow.none, .document, .panel] {
            for since in [nil, -60, 0, 0.1] as [TimeInterval?] {
                #expect(!handsBack(active: false, keyWindow: keyWindow, since: since))
            }
        }
    }

    /// Active with no key window of its own: nothing of ClearShot's is in use, so the URL activated it.
    @Test func activeWithoutAKeyWindowHandsBack() {
        for since in [nil, -3600, -0.5, 0, 0.2] as [TimeInterval?] {
            #expect(handsBack(active: true, keyWindow: .none, since: since))
        }
    }

    /// A document window (Annotate, the Video Editor, History, Settings) counts only when ClearShot was active before the
    /// URL arrived. One that became key because the URL activated the app (LaunchServices activates it about as it
    /// delivers the URL, a moment before or after) doesn't.
    @Test func aDocumentWindowKeepsTheActivationOnlyWhenClearShotWasActiveBefore() {
        #expect(handsBack(active: true, keyWindow: .document, since: 0.3))
        #expect(handsBack(active: true, keyWindow: .document, since: 0))
        #expect(handsBack(active: true, keyWindow: .document, since: -0.2))
        #expect(handsBack(active: true, keyWindow: .document, since: -URLActivation.leeway))
        #expect(!handsBack(active: true, keyWindow: .document, since: -URLActivation.leeway - 0.01))
        #expect(!handsBack(active: true, keyWindow: .document, since: -60))
        // Not knowing when it became active, the key window is the person's.
        #expect(!handsBack(active: true, keyWindow: .document, since: nil))
        #expect(URLActivation.leeway == 1)
    }

    /// A key panel that doesn't activate (the capture overlay, its toolbar, the countdown, a pin or a thumbnail) was
    /// key before the URL came, however recently ClearShot became active. A URL arriving during an overlay or a
    /// countdown leaves the keys there, so Esc still cancels.
    @Test func aKeyPanelKeepsTheActivation() {
        for since in [nil, -60, -0.2, 0, 0.3] as [TimeInterval?] {
            #expect(!handsBack(active: true, keyWindow: .panel, since: since))
        }
    }
}
