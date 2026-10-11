import Foundation

/// The masks of the secrets check, added to an open document.
extension AnnotationEditor {
    /// Adds `masks` (the Pixelate redactions of `AnnotationObject.pixelateMask`) to the document as **one** undo step named
    /// `actionName`, and selects them, so the person sees what was added and can delete a false alarm. Returns whether they
    /// were added.
    ///
    /// Nothing is added, and nothing recorded, when:
    /// - there are no masks;
    /// - a crop is pending, which owns the canvas;
    /// - a live change is open (a drag, a slider, text being typed): masks added under it would be undone with it, or it with
    ///   them. The caller says so, and the person tries again.
    ///
    /// It is a canvas change (`changeCanvas`): it never grows the canvas. A mask covers pixels of the picture it was found in,
    /// so it lies inside the canvas, give or take the fraction of a pixel by which a part-pixel canvas is rounded out to whole
    /// pixels when it is rendered; auto-expand would answer that with a margin's worth of fill.
    @discardableResult
    public func addMasks(_ masks: [AnnotationObject], actionName: String) -> Bool {
        guard !masks.isEmpty, crop == nil, !isInLiveChange else { return false }
        changeCanvas(actionName) { $0.objects.append(contentsOf: masks) }
        selection = Set(masks.map(\.id))
        return true
    }

    /// Takes every mask the secrets check made out of the document (`AnnotationDocument.removingSecretsMasks`) as **one** undo
    /// step named `actionName`, and drops them from the selection. Returns how many were removed, or nil when it refused:
    /// - a crop is pending, which owns the canvas;
    /// - a live change is open (a drag, a slider, text being typed), which the removal would be undone with, or it with the
    ///   removal.
    ///
    /// With no marked mask in the document it removes nothing and records nothing, and returns 0. The person's own redactions
    /// are never touched. Like `addMasks` it is a canvas change: it never grows the canvas.
    @discardableResult
    public func removeSecretsMasks(actionName: String) -> Int? {
        guard crop == nil, !isInLiveChange else { return nil }
        let marked = Set(document.objects.filter(\.isSecretsMask).map(\.id))
        guard !marked.isEmpty else { return 0 }
        changeCanvas(actionName) { $0 = $0.removingSecretsMasks() }
        selection.subtract(marked)
        return marked.count
    }
}
