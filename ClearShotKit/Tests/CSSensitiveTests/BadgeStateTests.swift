import CoreGraphics
import Testing
@testable import CSSensitive

/// The badge on a thumbnail, as a state machine: what it shows after a scan, after Mask All, after Undo Mask and after
/// Dismiss, and that anything else leaves it alone.
struct BadgeStateTests {
    private let two = FindingCounts([.contact: 2])
    private let mixed = FindingCounts([.contact: 2, .keyOrToken: 1, .card: 1])

    private func state(_ phase: BadgeState.Phase) -> BadgeState { BadgeState(phase: phase) }

    // MARK: Counts

    @Test func countsAreMadeFromFindings() {
        let box = CGRect(x: 0, y: 0, width: 10, height: 10)
        let counts = FindingCounts([ImageFinding(kind: .contact, rect: box), ImageFinding(kind: .keyOrToken, rect: box),
                                    ImageFinding(kind: .contact, rect: box)])
        #expect(counts == FindingCounts([.contact: 2, .keyOrToken: 1]))
        #expect(counts[.contact] == 2 && counts[.keyOrToken] == 1 && counts[.card] == 0 && counts[.ipAddress] == 0)
        #expect(counts.total == 3)
        #expect(!counts.isEmpty)
    }

    @Test func noFindingsAreNoCounts() {
        #expect(FindingCounts([]).isEmpty)
        #expect(FindingCounts([]).total == 0)
        #expect(FindingCounts([:]) == FindingCounts([]))
        // A count of nothing, or less, isn't one.
        #expect(FindingCounts([.card: 0, .contact: -2]) == FindingCounts([]))
        #expect(FindingCounts([.card: 0, .contact: 1]) == FindingCounts([.contact: 1]))
    }

    @Test func theBreakdownListsTheKindsFoundInTheOrderOfTheSettings() {
        #expect(mixed.breakdown.map(\.kind) == [.contact, .keyOrToken, .card])
        #expect(mixed.breakdown.map(\.count) == [2, 1, 1])
        #expect(FindingCounts([.ipAddress: 3, .contact: 1]).breakdown.map(\.kind) == [.contact, .ipAddress])
        #expect(FindingCounts([]).breakdown.isEmpty)
    }

    // MARK: A scan finishes

    @Test func aBadgeStartsScanning() {
        let badge = BadgeState()
        #expect(badge.phase == .scanning)
        #expect(!badge.isVisible)
        #expect(badge.counts == nil)
    }

    @Test func aScanThatFindsSomethingShowsTheCounts() {
        var badge = BadgeState()
        badge.apply(.scanFinished(mixed))
        #expect(badge.phase == .found(mixed))
        #expect(badge.isVisible)
        #expect(badge.counts == mixed)
    }

    @Test func aScanThatFindsNothingShowsNothing() {
        var badge = BadgeState()
        badge.apply(.scanFinished(FindingCounts([])))
        #expect(badge.phase == BadgeState.Phase.none)
        #expect(!badge.isVisible)
        #expect(badge.counts == nil)
    }

    @Test func aScanThatFailsShowsNothing() {
        var badge = BadgeState()
        badge.apply(.scanFailed)
        #expect(badge.phase == BadgeState.Phase.none)
        #expect(!badge.isVisible)
    }

    // MARK: Mask All, Undo Mask, Dismiss

    @Test func maskAllMasksWhatWasFound() {
        var badge = state(.found(mixed))
        badge.apply(.maskAll)
        #expect(badge.phase == .masked(mixed))
        #expect(badge.isVisible)
        #expect(badge.counts == mixed)
    }

    @Test func undoMaskBringsTheFindingsBack() {
        var badge = state(.masked(mixed))
        badge.apply(.undoMask)
        #expect(badge.phase == .found(mixed))
    }

    @Test func maskingAndUndoingCanBeRepeated() {
        var badge = BadgeState()
        badge.apply(.scanFinished(two))
        for _ in 0..<3 {
            badge.apply(.maskAll)
            #expect(badge.phase == .masked(two))
            badge.apply(.undoMask)
            #expect(badge.phase == .found(two))
        }
    }

    @Test func dismissHidesTheBadgeWhetherOrNotItWasMasked() {
        for phase in [BadgeState.Phase.found(two), .masked(two)] {
            var badge = state(phase)
            badge.apply(.dismiss)
            #expect(badge.phase == .dismissed)
            #expect(!badge.isVisible)
            #expect(badge.counts == nil)
        }
    }

    // MARK: Every other pairing leaves the state alone

    @Test func eventsThatDoNotApplyChangeNothing() {
        let events: [BadgeState.Event] = [.scanFinished(two), .scanFinished(FindingCounts([])), .scanFailed, .maskAll, .undoMask, .dismiss]
        // (phase, the events that change it)
        let table: [(BadgeState.Phase, Set<Int>)] = [
            (.scanning, [0, 1, 2]),
            (.none, []),
            (.found(mixed), [3, 5]),
            (.masked(mixed), [4, 5]),
            (.dismissed, []),
        ]
        for (phase, changing) in table {
            for (index, event) in events.enumerated() {
                var badge = state(phase)
                badge.apply(event)
                if changing.contains(index) {
                    #expect(badge.phase != phase, "\(phase) after \(event) should change")
                } else {
                    #expect(badge.phase == phase, "\(phase) after \(event) should stay")
                }
            }
        }
    }

    @Test func aDismissedBadgeStaysDismissedWhateverComesLater() {
        var badge = state(.found(two))
        badge.apply(.dismiss)
        for event: BadgeState.Event in [.scanFinished(mixed), .maskAll, .undoMask, .scanFailed, .dismiss] {
            badge.apply(event)
            #expect(badge.phase == .dismissed)
        }
    }

    @Test func aScanResultThatArrivesTwiceCountsOnce() {
        var badge = BadgeState()
        badge.apply(.scanFinished(two))
        badge.apply(.scanFinished(mixed))
        #expect(badge.phase == .found(two))
    }

    @Test func aMaskedBadgeIsNotMaskedAgainAndKeepsItsCounts() {
        var badge = state(.masked(two))
        badge.apply(.maskAll)
        badge.apply(.scanFinished(mixed))
        #expect(badge.phase == .masked(two))
    }
}
