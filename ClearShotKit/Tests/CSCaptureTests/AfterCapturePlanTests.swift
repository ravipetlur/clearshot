import CSCore
import Testing
@testable import CSCapture

/// A capture is never lost. It ends up saved, shown (a thumbnail, the editor or a pin), or copied.
struct AfterCapturePlanTests {
    /// What a set of actions plans to do. A nil is not checked for that row.
    @Test func theActionsMakeThePlan() {
        struct Row {
            let actions: Set<AfterCaptureAction>
            var askForName = false
            var saves: Bool?
            var defersSave: Bool?
            var showsQuickAccess: Bool?
            var showsThumbnail: Bool?
            var showsCapture: Bool?
            var opensEditor: Bool?
            var pins: Bool?
        }
        let rows: [Row] = [
            // A shown thumbnail keeps the capture.
            Row(actions: [.showQuickAccess], saves: false, showsQuickAccess: true, showsThumbnail: true,
                showsCapture: true),
            // The editor keeps the capture like a thumbnail.
            Row(actions: [.openEditor], showsThumbnail: false, showsCapture: true, opensEditor: true),
            // So does a pin.
            Row(actions: [.pin], saves: false, showsQuickAccess: false, showsThumbnail: false, showsCapture: true,
                pins: true),
            Row(actions: [.showQuickAccess, .openEditor], pins: false),
            Row(actions: [.save], saves: true, showsThumbnail: false, showsCapture: false),
            Row(actions: [.copy], saves: false),
            Row(actions: [.copy, .save], saves: true, showsCapture: false),
            // With nothing that saves, shows or copies the capture, nothing keeps it.
            Row(actions: [], saves: false, showsThumbnail: false, showsCapture: false),
            // Ask for name moves the save into the thumbnail.
            Row(actions: [.save], askForName: true, showsCapture: true),
            Row(actions: [.save, .copy], askForName: true, saves: false, defersSave: true, showsQuickAccess: false,
                showsThumbnail: true),
            // Without a save it changes nothing.
            Row(actions: [.showQuickAccess, .copy], askForName: true, saves: false, defersSave: false,
                showsThumbnail: true),
        ]
        for row in rows {
            let plan = AfterCapturePlan(actions: row.actions, askForName: row.askForName)
            let name = "\(row.actions.map { "\($0)" }.sorted()), ask for name \(row.askForName)"
            if let saves = row.saves { #expect(plan.saves == saves, "\(name)") }
            if let defers = row.defersSave { #expect(plan.defersSave == defers, "\(name)") }
            if let quickAccess = row.showsQuickAccess { #expect(plan.showsQuickAccess == quickAccess, "\(name)") }
            if let thumbnail = row.showsThumbnail { #expect(plan.showsThumbnail == thumbnail, "\(name)") }
            if let capture = row.showsCapture { #expect(plan.showsCapture == capture, "\(name)") }
            if let editor = row.opensEditor { #expect(plan.opensEditor == editor, "\(name)") }
            if let pins = row.pins { #expect(plan.pins == pins, "\(name)") }
        }
    }

    /// Whether the capture is copied, given whether the save worked and whether the capture could be shown.
    @Test func theCaptureIsCopiedWhenAskedOrWhenNothingElseKeepsIt() {
        let rows: [(actions: Set<AfterCaptureAction>, saved: Bool, shown: Bool, copy: CopyDecision)] = [
            // A thumbnail, the editor or a pin that was shown keeps the capture, so nothing is copied.
            ([.showQuickAccess], false, true, .none),
            ([.openEditor], false, true, .none),
            ([.pin], false, true, .none),
            // One that couldn't be shown (for the editor and a pin, no history item) keeps nothing, so it is copied.
            ([.showQuickAccess], false, false, .fallback),
            ([.openEditor], false, false, .fallback),
            ([.pin], false, false, .fallback),
            // A save that worked needs no copy; one that failed with no thumbnail copies as a fallback.
            ([.save], true, false, .none),
            ([.save], false, false, .fallback),
            // Copy is requested, not a fallback, whether or not the save worked.
            ([.copy], false, false, .requested),
            ([.copy], false, true, .requested),
            ([.copy, .save], true, false, .requested),
            ([.copy, .save], false, false, .requested),
            // Nothing that keeps the capture: it is copied so it isn't lost.
            ([], false, false, .fallback),
        ]
        for row in rows {
            #expect(AfterCapturePlan(actions: row.actions).copy(saved: row.saved, shown: row.shown) == row.copy,
                    "\(row.actions.map { "\($0)" }.sorted()), saved \(row.saved), shown \(row.shown)")
        }
    }
}
