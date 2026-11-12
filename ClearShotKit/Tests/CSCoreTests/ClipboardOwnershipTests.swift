import Foundation
import Testing
@testable import CSCore

/// Whether a capture's copy is still what the clipboard holds: deleting the capture clears it only then, and Mask All
/// puts the masked picture there only then. One rule for both: ClearShot's copy of this capture, untouched since it was
/// written. Anything written to the clipboard since, by ClearShot or another app, moves the change count on.
struct ClipboardOwnershipTests {
    @Test(arguments: [
        // (the same capture, the count when it was copied, the count now, still its copy)
        (true, 41, 41, true),
        (true, 41, 42, false),
        (true, 41, 40, false),
        (false, 41, 41, false),
        (true, 7, 6, false), (true, 7, 7, true), (true, 7, 8, false),
    ])
    func onlyItsOwnUnchangedCopyIsStillThere(sameItem: Bool, copiedAt: Int, now: Int, holds: Bool) {
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: copiedAt)
        let asked = sameItem ? item : UUID()
        #expect(copy.stillHolds(asked, changeCount: now) == holds)
        #expect(copy.clears(deleting: asked, changeCount: now) == holds)
    }
}
