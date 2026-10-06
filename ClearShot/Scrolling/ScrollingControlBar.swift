import AppKit
import CSCore
import CSScrolling

/// The scrolling capture's control bar: Done and Cancel on a selection toolbar, child of the frame window and placed by
/// `ToolbarPlacement` around the region, then a message: "Please slow down…" while no move can be verified (with
/// "Scroll back up a little to continue" under it, left for a horizontal capture: slowing down alone doesn't bring the
/// stitch back), "Screenshot is very large" near the cap, otherwise the size the file will have. A notice ("Auto-Scroll
/// stopped; scroll by hand") replaces the message for a while. The bar is key once shown, so Return is Done and Esc
/// Cancel, until the person clicks into another app; the keys that scroll a page (Space, the arrows, Page Up and Down,
/// Home, End) do nothing there, quietly: scrolling by keyboard needs a click into the page first.
final class ScrollingControlBar {
    private enum ID {
        static let done = "done"
        static let cancel = "cancel"
    }

    private let onDone: () -> Void
    private let onCancel: () -> Void
    private lazy var toolbar = SelectionToolbar { [weak self] action in self?.toolbarAction(action) }
    /// The output size, warnings and axis of the latest update.
    private var size: CGSize
    private var warnings: Set<StitchWarning> = []
    private var axis: ScrollAxis?
    private var notice: String?
    private var noticeTask: Task<Void, Never>?

    /// `size` is the file's size before the first frame (the region in output pixels).
    init(size: CGSize, onDone: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.size = size
        self.onDone = onDone
        self.onCancel = onCancel
        toolbar.onKeyDown = { [weak self] event in self?.keyDown(event) ?? false }
        showItems()
    }

    /// Shows the bar for `region` on `window` (the frame window) within `visibleFrame`, and makes it key.
    func show(attachedTo window: NSWindow, region: CGRect, visibleFrame: CGRect) {
        toolbar.show(attachedTo: window, anchoredTo: region, visibleFrame: visibleFrame)
        toolbar.makeKey()
    }

    func hide() {
        noticeTask?.cancel()
        toolbar.hide()
    }

    /// The size the file will have so far, the warnings and the axis (for which way to scroll back), from the latest
    /// update.
    func show(size: CGSize, warnings: Set<StitchWarning>, axis: ScrollAxis?) {
        self.size = size
        self.warnings = warnings
        self.axis = axis
        showItems()
    }

    /// Shows `text` as a warning in place of the message for `duration`.
    func showNotice(_ text: String, for duration: Duration) {
        noticeTask?.cancel()
        notice = text
        showItems()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            self.notice = nil
            self.showItems()
        }
    }

    // MARK: Private

    private func showItems() {
        toolbar.update([
            .button(SelectionToolbarButton(id: ID.done, symbol: "checkmark", title: "Done", hoverLabel: "Done (Return)",
                                           isProminent: true)),
            .button(SelectionToolbarButton(id: ID.cancel, symbol: "xmark", hoverLabel: "Cancel (Esc)")),
            message,
        ])
    }

    private var message: SelectionToolbarItem {
        if let notice { return .message(notice, isWarning: true) }
        if warnings.contains(.slowDown) {
            return .message(StitchWarning.slowDownText, isWarning: true, detail: StitchWarning.slowDownHint(along: axis))
        }
        if warnings.contains(.veryLarge) { return .message("Screenshot is very large", isWarning: true) }
        return .message("\(Int(size.width)) × \(Int(size.height))", isWarning: false)
    }

    private func toolbarAction(_ action: SelectionToolbarAction) {
        guard case .pressed(let id) = action else { return }
        switch id {
        case ID.done: onDone()
        case ID.cancel: onCancel()
        default: break
        }
    }

    private func keyDown(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 36, 76: // Return, keypad Enter
            if !event.isARepeat { onDone() }
        case 53: // Esc
            if !event.isARepeat { onCancel() }
        case 49, 123, 124, 125, 126, 116, 121, 115, 119: // Space, the arrows, Page Up, Page Down, Home, End: no beep
            break
        default:
            return false
        }
        return true
    }
}
