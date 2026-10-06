import AppKit
import CSAnnotation
import Observation
import SwiftUI

/// Keeps a canvas smaller than the window centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let size = documentView.frame.size
        if rect.width > size.width { rect.origin.x = (size.width - rect.width) / 2 }
        if rect.height > size.height { rect.origin.y = (size.height - rect.height) / 2 }
        return rect
    }
}

extension NSScrollView {
    /// Scrolls so what the document view shows stays where it was on screen after its content moved by `shift` (in the
    /// document view's points), from the clip view's `origin` as it was before the change. The target goes through the clip
    /// view's own constraint, which `scroll(to:)` alone skips: a `CenteringClipView` keeps a document smaller than it
    /// centred, and any clip view keeps what it shows inside the document.
    func scroll(keepingContentFrom origin: NSPoint, shiftedBy shift: CGVector) {
        let clip = contentView
        let target = NSRect(origin: NSPoint(x: origin.x + shift.dx, y: origin.y + shift.dy), size: clip.bounds.size)
        clip.scroll(to: clip.constrainBoundsRect(target).origin)
        reflectScrolledClipView(clip)
    }
}

/// The canvas's scroll view: zoom (pinch) and panning, which "Lock canvas" turns off.
final class CanvasScrollView: NSScrollView {
    var isLocked: () -> Bool = { false }
    /// Called after anything that can change the zoom: a pinch, a smart-magnify, ⌘-scroll or `setMagnification`.
    var onMagnificationChange: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if isLocked() { return }
        super.scrollWheel(with: event)
        onMagnificationChange?()
    }

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnificationChange?()
    }

    override func smartMagnify(with event: NSEvent) {
        super.smartMagnify(with: event)
        onMagnificationChange?()
    }

    override func setMagnification(_ magnification: CGFloat, centeredAt point: NSPoint) {
        super.setMagnification(magnification, centeredAt: point)
        onMagnificationChange?()
    }
}

/// Zoom for the bottom bar: Fit, 50/100/200/400%, ⌘+ / ⌘−.
@Observable
final class CanvasController {
    static let levels: [Double] = [0.5, 1, 2, 4]

    var magnification: Double = 1
    @ObservationIgnored weak var scrollView: NSScrollView?
    @ObservationIgnored weak var canvas: AnnotationCanvasView?
    /// Tells the person an image couldn't be read or added (the window controller supplies it).
    @ObservationIgnored var imageProblem: ((ImageProblem) -> Void)?
    /// Shows or hides the Background panel, for the canvas's letter (the window controller supplies it).
    @ObservationIgnored var toggleBackgroundPanel: (() -> Void)?

    func zoom(to level: Double) {
        guard let scrollView else { return }
        let clamped = min(max(level, scrollView.minMagnification), scrollView.maxMagnification)
        let visible = scrollView.contentView.bounds
        scrollView.setMagnification(clamped, centeredAt: NSPoint(x: visible.midX, y: visible.midY))
        magnification = scrollView.magnification
    }

    /// Fits the canvas in the scroll view as the window lays it out now. The layout comes first: the Background panel
    /// shown or hidden in the same change as a background added or removed hasn't resized the scroll view yet.
    func zoomToFit() {
        scrollView?.window?.layoutIfNeeded()
        guard let scrollView, let canvas, canvas.frame.width > 0, canvas.frame.height > 0 else { return }
        let available = scrollView.contentSize
        // Before the first layout the scroll view has no size; fitting to nothing would clamp the zoom to its minimum.
        guard available.width > 0, available.height > 0 else { return }
        let fit = min((available.width - 32) / canvas.frame.width, (available.height - 32) / canvas.frame.height)
        scrollView.magnification = min(max(fit, scrollView.minMagnification), 1)
        magnification = scrollView.magnification
    }

    /// Steps from the scroll view's own zoom, which a pinch or ⌘-scroll may have changed since the label last updated.
    func zoomIn() { zoom(to: liveMagnification * 1.25) }
    func zoomOut() { zoom(to: liveMagnification / 1.25) }

    private var liveMagnification: Double {
        scrollView.map { Double($0.magnification) } ?? magnification
    }
}

struct CanvasContainer: NSViewRepresentable {
    let editor: AnnotationEditor
    let controller: CanvasController

    func makeNSView(context: Context) -> CanvasScrollView {
        let scrollView = CanvasScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .underPageBackgroundColor
        let canvas = AnnotationCanvasView(editor: editor)
        canvas.magnification = { [weak scrollView] in Double(scrollView?.magnification ?? 1) }
        canvas.fitToWindow = { [weak controller] in controller?.zoomToFit() }
        canvas.imageProblem = { [weak controller] problem in controller?.imageProblem?(problem) }
        canvas.toggleBackgroundPanel = { [weak controller] in controller?.toggleBackgroundPanel?() }
        scrollView.documentView = canvas
        scrollView.isLocked = { [weak editor] in editor?.isCanvasLocked ?? false }
        controller.scrollView = scrollView
        controller.canvas = canvas
        scrollView.onMagnificationChange = { [weak controller, weak scrollView] in
            if let scrollView { controller?.magnification = Double(scrollView.magnification) }
        }
        // After this layout pass the scroll view has its size: fit the picture and take the keyboard.
        Task { @MainActor [weak controller, weak canvas] in
            controller?.zoomToFit()
            if let canvas { canvas.window?.makeFirstResponder(canvas) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: CanvasScrollView, context: Context) {}
}
