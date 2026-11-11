import CoreGraphics
import CSCore
import Foundation

/// The contrast readout beside a pixel selection (`selectionContrast`): the selection's two main colors and how readable one is
/// on the other. Found off the main actor from the picture's pixels (`picturePixels`) after a short quiet, so dragging the
/// selection reads once it settles.
extension AnnotationEditor {
    /// How long the selection must hold still before its colors are read.
    static let contrastDelay = Duration.milliseconds(120)

    /// Whether the readout is APCA's ("Lc 62") rather than WCAG 2's ("4.5:1"); remembered between editors.
    public var contrastUsesAPCA: Bool {
        get { preferences[Prefs.annotateContrastAPCA] }
        set { preferences[Prefs.annotateContrastAPCA] = newValue }
    }

    /// Brings `selectionContrast` up to date with the pixel selection and the picture: the canvas calls it whenever either
    /// may have changed. It asks for the picture's pixels (`loadPicturePixels()`) while there is a selection, and does nothing
    /// when what the readout is of hasn't changed. The old readout stays until the new one is found, so it doesn't flicker
    /// while the selection is dragged.
    public func updateSelectionContrast() {
        guard let selected = pixelSelection, crop == nil else {
            contrastTask?.cancel()
            contrastTask = nil
            contrastRequest = nil
            if selectionContrast != nil { selectionContrast = nil }
            return
        }
        loadPicturePixels()
        // The pixels are still being built: their arrival changes `picturePixels`, which the canvas watches.
        guard let pixels = picturePixels else { return }
        if let request = contrastRequest, request.rect == selected, request.picture == pixels.identity { return }
        contrastRequest = (selected, pixels.identity)
        contrastTask?.cancel()
        contrastTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.contrastDelay) } catch { return }
            let area = pixels.pixelRect(fromBase: selected)
            let sampler = pixels.sampler
            let contrast = await Task.detached(priority: .userInitiated) { SelectionContrast(in: area, of: sampler) }.value
            guard let self, !Task.isCancelled else { return }
            contrastTask = nil
            selectionContrast = contrast
        }
    }
}
