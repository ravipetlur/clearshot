import AppKit
import CSCore
import CSHistory
import Quartz

/// One thumbnail on screen: its panel and view, the history item it shows, and its auto-close countdown.
final class QuickAccessItemController {
    private(set) var item: HistoryItem
    /// The history folder, where a video's badge reads its size and its preview finds its file.
    private let historyRoot: URL
    let panel = QuickAccessPanel()
    let view = QuickAccessView(frame: NSRect(x: 0, y: 0, width: 216, height: 135))
    /// Waiting for a file name.
    private(set) var isNaming: Bool
    /// Shown only to ask for a name, so it closes once the capture is named or discarded.
    let closesAfterNaming: Bool
    /// Runs only while `QuickAccessRules.clockRuns` says so; `QuickAccessManager.updateClock` keeps it in step.
    var clock: AutoCloseClock?
    var isHovering = false
    /// Quick Look is showing this thumbnail's file.
    var isPreviewing = false
    /// How many things hold the countdown: a Save panel, the print dialog, an alert or the Resize dialog for this
    /// thumbnail. It stays paused while any is open, even when the pointer leaves the thumbnail.
    var holds = 0
    /// A save or image change is running; commands that would race it are ignored.
    var isBusy = false
    private var thumbnail: CGImage?
    private var isNewest = false

    init(item: HistoryItem, historyRoot: URL, thumbnail: CGImage?, naming: Bool, closesAfterNaming: Bool) {
        self.item = item
        self.historyRoot = historyRoot
        self.thumbnail = thumbnail
        self.isNaming = naming
        self.closesAfterNaming = closesAfterNaming
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        refresh()
    }

    var id: UUID { item.id }
    var isSaved: Bool { item.savedPath != nil }

    func contentSize(for size: QuickAccessSize) -> CGSize {
        var result = QuickAccessLayout.thumbnailSize(imagePixels: item.pixelSize, size: size)
        if isNaming { result.height += QuickAccessLayout.nameStripHeight }
        return result
    }

    /// Shows a changed item. Pass `thumbnail` when the image itself changed.
    func update(_ item: HistoryItem, thumbnail: CGImage? = nil) {
        self.item = item
        if let thumbnail { self.thumbnail = thumbnail }
        refresh()
    }

    func finishNaming(with item: HistoryItem) {
        isNaming = false
        update(item)
    }

    func setNewest(_ newest: Bool) {
        guard newest != isNewest else { return }
        isNewest = newest
        refresh()
    }

    /// Slides in from the screen edge and fades in.
    func present(at frame: CGRect, from position: QuickAccessPosition) {
        let shift = (position == .left ? -1 : 1) * min(frame.width, 60)
        panel.setFrame(frame.offsetBy(dx: shift, dy: 0), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func move(to frame: CGRect, animated: Bool) {
        if !panel.isVisible {
            panel.setFrame(frame, display: true)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else if panel.frame != frame {
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.2
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
        }
        panel.invalidateShadow()
    }

    /// Ordered out, it never plays its preview.
    func hide() {
        view.stopPreview()
        panel.orderOut(nil)
    }

    /// Slides off toward the screen edge, fading out, for a swipe.
    func slideAway(toward position: QuickAccessPosition) async {
        let shift = (position == .left ? -1 : 1) * (panel.frame.width + 40)
        let target = panel.frame.offsetBy(dx: shift, dy: 0)
        await NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 0
        }
    }

    /// Ends a Quick Look session this panel controls first: Quick Look keeps an unretained reference to the panel as its
    /// data source.
    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
           (preview.currentController as AnyObject?) === panel {
            preview.orderOut(nil)
        }
        panel.previewURL = nil
        view.stopPreview()
        panel.orderOut(nil)
    }

    /// Opens or closes Quick Look for `url` (Space). Returns whether it opened.
    @discardableResult
    func showQuickLook(_ url: URL) -> Bool {
        panel.previewURL = url
        NSApp.activate()
        panel.makeKey()
        guard let preview = QLPreviewPanel.shared() else { return false }
        if preview.isVisible {
            preview.orderOut(nil)
            return false
        }
        preview.makeKeyAndOrderFront(nil)
        return true
    }

    /// Shows the item as it is now: a video's or GIF's badge reads the working copy's size again, so Mute and Replace
    /// show at once.
    private func refresh() {
        view.configure(thumbnail: thumbnail, isSaved: isSaved, isNewest: isNewest, naming: isNaming ? item.displayName : nil,
                       media: QuickAccessMedia(item: item, root: historyRoot))
    }
}
