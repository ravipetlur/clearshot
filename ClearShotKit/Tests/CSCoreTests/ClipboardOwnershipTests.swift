import Foundation
import Testing
@testable import CSCore

struct ClipboardOwnershipTests {
    @Test func clearsOnlyItsOwnUnchangedCopy() {
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: 41)
        #expect(copy.clears(deleting: item, changeCount: 41))
    }

    @Test func aLaterCopyIsNeverCleared() {
        // Anything written to the clipboard since, by ClearShot or another app, moves the change count on.
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: 41)
        #expect(!copy.clears(deleting: item, changeCount: 42))
    }

    @Test func anotherItemsCopyIsNeverCleared() {
        let copy = ClipboardOwnership(itemID: UUID(), changeCount: 41)
        #expect(!copy.clears(deleting: UUID(), changeCount: 41))
    }
}

/// Whether a capture's copy is still what the clipboard holds, which decides if Mask All puts the masked picture there.
struct ClipboardStillHoldsTests {
    @Test func itsOwnUnchangedCopyIsStillThere() {
        let item = UUID()
        #expect(ClipboardOwnership(itemID: item, changeCount: 41).stillHolds(item, changeCount: 41))
    }

    @Test func anythingCopiedSinceMeansItIsNot() {
        let item = UUID()
        #expect(!ClipboardOwnership(itemID: item, changeCount: 41).stillHolds(item, changeCount: 42))
        #expect(!ClipboardOwnership(itemID: item, changeCount: 41).stillHolds(item, changeCount: 40))
    }

    @Test func anotherCapturesCopyIsNotThisOnes() {
        #expect(!ClipboardOwnership(itemID: UUID(), changeCount: 41).stillHolds(UUID(), changeCount: 41))
    }

    @Test func itAgreesWithWhatDeletingClears() {
        // One rule for both: ClearShot's copy of a capture, untouched since it was written.
        let item = UUID()
        let copy = ClipboardOwnership(itemID: item, changeCount: 7)
        for current in [6, 7, 8] {
            #expect(copy.stillHolds(item, changeCount: current) == copy.clears(deleting: item, changeCount: current))
        }
    }
}
