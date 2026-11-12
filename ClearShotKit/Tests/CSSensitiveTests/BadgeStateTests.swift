import CoreGraphics
import Testing
@testable import CSSensitive

private let two = FindingCounts([.contact: 2])
private let mixed = FindingCounts([.contact: 2, .keyOrToken: 1, .card: 1])

/// The badge on a thumbnail, as a state machine: what it shows after a scan, after Mask All, after Undo Mask and after
/// Dismiss, and that anything else leaves it alone.
struct BadgeStateTests {
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

    @Test func aBadgeStartsScanning() {
        let badge = BadgeState()
        #expect(badge.phase == .scanning)
        #expect(!badge.isVisible)
        #expect(badge.counts == nil)
    }

    // MARK: A scan finishes; Mask All, Undo Mask, Dismiss

    @Test(arguments: [
        // A scan that finds something shows the counts; one that finds nothing, or fails, shows nothing.
        (BadgeState.Phase.scanning, BadgeState.Event.scanFinished(mixed), BadgeState.Phase.found(mixed)),
        (.scanning, .scanFinished(FindingCounts([])), BadgeState.Phase.none),
        (.scanning, .scanFailed, BadgeState.Phase.none),
        // Mask All masks what was found; Undo Mask brings the findings back.
        (.found(mixed), .maskAll, .masked(mixed)),
        (.masked(mixed), .undoMask, .found(mixed)),
        // Dismiss hides the badge whether or not it was masked.
        (.found(two), .dismiss, .dismissed),
        (.masked(two), .dismiss, .dismissed),
    ])
    func anEventMovesTheBadge(from: BadgeState.Phase, event: BadgeState.Event, to: BadgeState.Phase) {
        var badge = BadgeState(phase: from)
        badge.apply(event)
        #expect(badge.phase == to)
        switch to {
        case .found(let counts), .masked(let counts):
            #expect(badge.isVisible)
            #expect(badge.counts == counts)
        default:
            #expect(!badge.isVisible)
            #expect(badge.counts == nil)
        }
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
}
