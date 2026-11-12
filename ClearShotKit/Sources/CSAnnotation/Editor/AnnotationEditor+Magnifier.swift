import CoreGraphics
import Foundation

/// The magnifier: making one from a dragged-out source, and its shape, border and zoom.
extension AnnotationEditor {
    /// The canvas in base pixels: where a new callout is placed, if it fits.
    var canvasInBase: CGRect {
        document.canvasBounds.applying(document.transform.inverse)
    }

    /// A new magnifier of `source` (base pixels), with the remembered shape and border and the current color and size, its
    /// callout at the default zoom beside the source, inside the canvas where it fits (`MagnifierGeometry.make`). `id` is
    /// for the preview while dragging.
    public func newMagnifier(source: CGRect, id: UUID = UUID()) -> AnnotationObject {
        let magnifier = MagnifierGeometry.make(source: source, within: canvasInBase, gap: document.pixels(fromPoints: 16),
                                               shape: settings.magnifierShape, border: settings.magnifierBorder)
        var style = newStyle(lineWidthPoints: ToolSizes.lineWidth(settings.sizeLevel))
        style.shadow = false
        return AnnotationObject(id: id, kind: .magnifier(magnifier), style: style)
    }

    /// The one selected magnifier, or nil: what the property bar's zoom shows.
    public var selectedMagnifier: MagnifierObject? {
        guard selection.count == 1, let object = selectedObjects.first, case .magnifier(let magnifier) = object.kind else { return nil }
        return magnifier
    }

    public func setMagnifierShape(_ shape: MagnifierShape) {
        settings.magnifierShape = shape
        restyleMagnifiers("Change Magnifier") { $0.shape = shape }
    }

    public func setMagnifierBorder(_ on: Bool) {
        settings.magnifierBorder = on
        restyleMagnifiers(on ? "Add Border" : "Remove Border") { $0.border = on }
    }

    /// Sets the selected magnifiers' zoom (clamped to `MagnifierObject.zoomRange`), each callout resized about its middle.
    public func setMagnifierZoom(_ zoom: Double) {
        restyleMagnifiers("Change Zoom") { $0 = MagnifierGeometry.withZoom($0, zoom) }
    }

    /// Applies `body` to the selected magnifiers as one undo step (or, during a live change, as part of it).
    private func restyleMagnifiers(_ actionName: String, _ body: (inout MagnifierObject) -> Void) {
        let ids = selection
        guard !ids.isEmpty else { return }
        func edit(_ document: inout AnnotationDocument) {
            for index in document.objects.indices where ids.contains(document.objects[index].id) {
                guard case .magnifier(var magnifier) = document.objects[index].kind else { continue }
                body(&magnifier)
                document.objects[index].kind = .magnifier(magnifier)
            }
        }
        if isInLiveChange {
            updateLive(edit)
        } else {
            change(actionName, edit)
        }
    }
}
