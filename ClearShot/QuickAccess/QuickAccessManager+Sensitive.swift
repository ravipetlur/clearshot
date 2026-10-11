import AppKit
import CSHistory
import CSSensitive

/// The possible-secrets badge's menu and what its commands do. The scan and the capture changes are
/// `SensitiveScanCoordinator`'s; this is the thumbnail's side: who may run, who waits, what opens.
extension QuickAccessManager {
    /// Mask All (or, once masked, Undo Mask), Review in Annotate…, and Dismiss. Nil while the badge shows nothing. The
    /// first two are off while the thumbnail has a save or an image change running.
    func sensitiveMenu(for controller: QuickAccessItemController) -> NSMenu? {
        guard let phase = scans.badge(for: controller.id)?.phase else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let idle = !controller.isBusy
        func add(_ title: String, enabled: Bool = true, _ handler: @escaping () -> Void) {
            let entry = NSMenuItem.action(title, handler: handler)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }
        switch phase {
        case .found:
            add("Mask All", enabled: idle) { [weak self] in self?.maskAll(controller) }
        case .masked:
            add("Undo Mask", enabled: idle) { [weak self] in self?.undoMask(controller) }
        case .scanning, .none, .dismissed:
            return nil
        }
        add("Review in Annotate…", enabled: idle) { [weak self] in self?.reviewMasks(controller) }
        menu.addItem(.separator())
        add("Dismiss") { [weak self] in self?.scans.dismiss(controller.id) }
        return menu
    }

    /// Mask All. The thumbnail is busy while the masks are written, so nothing races it; the store's `.updated` shows the
    /// masked picture on the thumbnail, and it is shown here if that didn't. Refused while Annotate has the capture open,
    /// as a rotate or a resize is: the editor's own copy of the document would overwrite the masks on Done.
    func maskAll(_ controller: QuickAccessItemController) {
        changeCapture(of: controller) { [scans] item in await scans.maskAll(item) }
    }

    /// Undo Mask: takes out the masks Mask All added, and nothing else.
    func undoMask(_ controller: QuickAccessItemController) {
        changeCapture(of: controller) { [scans] item in await scans.undoMask(item) }
    }

    /// Review in Annotate…: opens Annotate on the capture as it is, and changes nothing. With the masks applied (a badge that says
    /// "Masked") it opens with them as ordinary redactions, each one selectable and deletable, so a false alarm can be removed;
    /// after Undo Mask it opens unmasked, and Annotate's own sensitive-info button shows the count and masks in one click. The
    /// badge stays as it is while Annotate is open. A capture that is open in Annotate already is what the person is asking to see:
    /// its editor comes forward, and nothing is written under it (Mask All and Undo Mask refuse while it is open, as a rotate does).
    func reviewMasks(_ controller: QuickAccessItemController) {
        guard isEditing(controller.item.id) || !controller.isBusy else { return }
        onAnnotate?(controller.item)
    }

    private func changeCapture(of controller: QuickAccessItemController, _ change: @escaping (HistoryItem) async -> HistoryItem?) {
        guard !refuseWhileAnnotating(controller), !controller.isBusy else { return }
        controller.isBusy = true
        Task {
            defer { controller.isBusy = false }
            guard let updated = await change(controller.item) else { return }
            if controller.item != updated { refresh(updated) }
        }
    }
}
