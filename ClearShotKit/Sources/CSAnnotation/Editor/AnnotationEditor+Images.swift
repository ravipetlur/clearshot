import CoreGraphics
import Foundation

/// Where `AnnotationEditor.insertImage` puts a new image object.
public enum ImageInsertion: Equatable, Sendable {
    /// Centred in the visible part of the canvas, `visible` in output pixels: Add Image and ⌘V.
    case centered(visible: CGRect)
    /// Centred on a drop point, in output pixels.
    case at(CGPoint)
    /// Beside the canvas on one side, growing it to hold both (a drop zone, "combine screenshots").
    case beside(RectEdge)
}

extension AnnotationEditor {
    /// Adds `image` as a new image object and selects it, as one undo step:
    /// - it is sized from its own `scale` (pixels per point) to the document's, then scaled down to fit 80% of the canvas,
    ///   except beside the canvas, where the canvas grows instead (within 16 383 pixels);
    /// - its bitmap goes into the document's images under a new name, limited to 16 383 pixels a side and turned to the
    ///   base's orientation, so it shows upright after Rotate or Flip;
    /// - its shadow follows "Draw shadow on objects", except beside the canvas, where nothing should fall across the seam;
    /// - put in the canvas (centred or at a point) it is kept inside it, so it never grows the canvas.
    ///
    /// Returns false, adding nothing, when the bitmap can't be prepared, that side of the canvas has no room left (or only
    /// a sliver: the caller falls back to the drop point), a crop is being edited (the crop owns the canvas, as it does for
    /// every object command) or a live change is open (a drag, a slider, a text being typed).
    @discardableResult
    public func insertImage(_ image: CGImage, scale: Double, _ insertion: ImageInsertion) -> Bool {
        guard crop == nil, !isInLiveChange else { return false }
        guard let limited = ImagePlacement.limited(image),
              let oriented = ImagePlacement.orientedForBase(limited, transform: document.transform) else { return false }
        let natural = ImagePlacement.naturalSize(pixelSize: CGSize(width: image.width, height: image.height), imageScale: scale,
                                                 outputScale: document.pixelScale)
        let canvas = document.canvasBounds
        let rect: CGRect
        var grownCanvas: CGRect?
        switch insertion {
        case .centered(let visible):
            let area = visible.intersection(canvas)
            let center = area.isNull || area.isEmpty ? CGPoint(x: canvas.midX, y: canvas.midY) : CGPoint(x: area.midX, y: area.midY)
            rect = ImagePlacement.placed(size: natural, in: canvas, centeredOn: center)
        case .at(let point):
            rect = ImagePlacement.placed(size: natural, in: canvas, centeredOn: point)
        case .beside(let edge):
            guard let layout = CombineLayout.place(imageSize: natural, onto: canvas, edge: edge) else { return false }
            rect = layout.rect
            grownCanvas = layout.canvas
        }
        let ref = ImageRef(name: "images/\(UUID().uuidString).png")
        var style = newStyle(lineWidthPoints: 1)
        if grownCanvas != nil { style.shadow = false }
        let object = AnnotationObject(kind: .image(ImageObject(rect: rect.applying(document.transform.inverse).standardized, image: ref)),
                                      style: style)
        addImage(oriented, for: ref)
        if let grownCanvas {
            changeCanvas("Combine Images") { document in
                document.objects.append(object)
                document.canvasRect = grownCanvas
            }
        } else {
            change("Add Image") { $0.objects.append(object) }
        }
        selection = [object.id]
        return true
    }
}
