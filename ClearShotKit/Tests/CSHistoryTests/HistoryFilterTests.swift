import CoreGraphics
import CSCapture
import Foundation
import Testing
@testable import CSHistory

private func item(_ kind: MediaKind, origin: HistoryOrigin = .capture) -> HistoryItem {
    HistoryItem(id: UUID(), kind: kind, origin: origin, captureKind: .selection, createdAt: Date(timeIntervalSinceReferenceDate: 0),
                mediaFileName: "Shot.png", displayName: "Shot", savedPath: nil, pixelWidth: 4, pixelHeight: 4, scale: 1,
                appName: nil, isTransparent: false, globalRect: .zero)
}

struct HistoryFilterTests {
    @Test func screenshotsIncludeCapturesFilesAndClipboardImages() {
        for origin in [HistoryOrigin.capture, .file, .clipboard] {
            #expect(HistoryFilter.screenshots.includes(item(.screenshot, origin: origin)))
        }
    }

    @Test func eachFilterKeepsOnlyItsKind() {
        // No filter of its own for a Studio Mode project: only All shows one.
        let items = [item(.screenshot), item(.video), item(.gif), item(.studioProject)]
        func kept(_ filter: HistoryFilter) -> [MediaKind] { items.filter(filter.includes).map(\.kind) }
        #expect(kept(.all) == [.screenshot, .video, .gif, .studioProject])
        #expect(kept(.screenshots) == [.screenshot])
        #expect(kept(.videos) == [.video])
        #expect(kept(.gifs) == [.gif])
    }

    @Test func filterTitlesAreTheDecidedOnes() {
        #expect(HistoryFilter.allCases.map(\.title) == ["All", "Screenshots", "Videos", "GIFs"])
        #expect(HistoryFilter.allCases.map(\.id) == ["all", "screenshots", "videos", "gifs"])
    }
}
