import AppKit
import CSCore
import CSHistory
import Quartz

/// One pin: its panel and view, the history item it shows, its zoom, opacity and style, and its lock. The pin keeps the
/// item's ID; its actions look the current item up in the store.
final class PinController {
    let itemID: UUID
    let panel = PinPanel()
    let view = PinView(frame: NSRect(x: 0, y: 0, width: PinGeometry.minimumSide, height: PinGeometry.minimumSide))
    /// Where the pin goes when it first shows.
    let anchor: PinAnchor
    /// A click on the unlock badge; the manager unlocks the pin.
    var onUnlock: (() -> Void)?
    /// Shown while the pointer is over a locked pin: a child window of the panel then, ordered out otherwise.
    private let badge = PinLockBadge()
    /// While locked: the pointer is over the pin or its badge, so the badge shows and a hide-on-hover pin is faded out.
    private var pointerInside = false
    /// The item as the pin last asked to draw it, to tell a change to the picture from one to its details.
    var item: HistoryItem
    /// Each decode of the working copy takes the next generation; only the newest is applied.
    var decodes = GenerationCounter()
    /// Placed and put on screen; false while the first decode runs.
    private(set) var isPresented = false
    /// The picture's size in points at 100%.
    private(set) var imagePoints: CGSize = .zero
    private(set) var zoom: Double = 1
    private(set) var opacity: Double = 1
    /// This pin's style, from the Settings defaults when it was made.
    var style: PinStyle {
        didSet { applyStyle() }
    }

    /// Locked, the pin lets every click, scroll and drag through to the app below, never becomes key and shows no hover
    /// controls or readout; its badge unlocks it. Unlocking also ends hide-on-hover, so the pin is back at its opacity.
    var isLocked = false {
        didSet {
            guard isLocked != oldValue else { return }
            panel.isLocked = isLocked
            panel.ignoresMouseEvents = isLocked
            view.isLocked = isLocked
            if isLocked {
                // A key pin gives up key, so typing goes back to the app in front: ordered out and in again, it isn't
                // key, and locked it can't become key.
                if panel.isKeyWindow {
                    panel.orderOut(nil)
                    panel.orderFrontRegardless()
                }
            } else {
                pointerInside = false
                hidesOnHover = false
                hideBadge()
            }
        }
    }

    /// While locked, the pin fades out while the pointer is over it and comes back when it leaves. Its badge stays.
    var hidesOnHover = false {
        didSet {
            guard hidesOnHover != oldValue else { return }
            updateHoverFade()
        }
    }

    init(item: HistoryItem, anchor: PinAnchor, style: PinStyle) {
        itemID = item.id
        self.item = item
        self.anchor = anchor
        self.style = style
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        badge.onUnlock = { [weak self] in self?.onUnlock?() }
        // Global monitors get nothing while the pointer is over the badge, a ClearShot window; it says when it leaves.
        badge.onPointerExited = { [weak self] in self?.trackPointer(at: NSEvent.mouseLocation) }
    }

    /// Shows the pin for the first time with its decoded picture, where `place` puts a picture of that many points at
    /// 100%, fading in over 0.15 s unless Reduce Motion is on. It never takes key.
    func present(_ image: CGImage, place: (_ imagePoints: CGSize) -> PinStart) {
        setPicture(image)
        let start = place(imagePoints)
        zoom = start.zoom
        view.zoom = zoom
        applyStyle()
        panel.setFrame(start.frame, display: false)
        view.layoutSubtreeIfNeeded()
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = fades ? 0 : opacity
        panel.orderFrontRegardless()
        isPresented = true
        guard fades else {
            panel.invalidateShadow()
            return
        }
        Task {
            await NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = opacity
            }
            panel.invalidateShadow()
        }
    }

    /// Shows a new decode of the working copy (an annotation, a rotate, a resize): the zoom is kept, within the new
    /// picture's maximum, and the window keeps its top-left corner.
    func replacePicture(_ image: CGImage) {
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        setPicture(image)
        zoom = PinGeometry.clampedZoom(zoom, imagePoints: imagePoints)
        view.zoom = zoom
        let size = PinGeometry.windowSize(imagePoints: imagePoints, zoom: zoom)
        panel.setFrame(CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        view.layoutSubtreeIfNeeded()
        applyStyle()
        // A locked pin can change size too (Annotate's Done, a rotate): the badge keeps to the new corner, or goes if
        // the pointer is no longer over the pin.
        if badge.parent != nil { placeBadge() }
        trackPointer(at: NSEvent.mouseLocation)
    }

    private func setPicture(_ image: CGImage) {
        imagePoints = PinGeometry.imagePoints(pixelSize: CGSize(width: image.width, height: image.height), scale: item.scale)
        view.setPicture(image, imagePoints: imagePoints)
    }

    // MARK: Zoom, opacity, moves

    /// Zooms to `newZoom`, clamped to this picture's limits, keeping the screen point `anchor` at the same place on the
    /// pin (a pinch), or the centre when nil (the zoom keys).
    func setZoom(_ newZoom: Double, anchor: CGPoint?) {
        guard isPresented else { return }
        zoom = PinGeometry.clampedZoom(newZoom, imagePoints: imagePoints)
        view.zoom = zoom
        let size = PinGeometry.windowSize(imagePoints: imagePoints, zoom: zoom)
        panel.setFrame(PinGeometry.zoomed(panel.frame, to: size, anchor: anchor), display: true)
        view.layoutSubtreeIfNeeded()
    }

    /// One pinch step, about the pointer. The shadow is redone once the gesture ends.
    func pinch(by magnification: Double, ended: Bool) {
        setZoom(zoom * (1 + magnification), anchor: NSEvent.mouseLocation)
        if ended { panel.invalidateShadow() }
    }

    /// A zoom key or menu preset, about the centre.
    func zoom(to newZoom: Double) {
        setZoom(newZoom, anchor: nil)
        panel.invalidateShadow()
    }

    /// Sets the opacity, clamped to 10–100%, and shows it in the readout (a scroll; a menu preset needs none).
    func setOpacity(_ newOpacity: Double, showsReadout: Bool = true) {
        guard isPresented else { return }
        opacity = PinGeometry.clampedOpacity(newOpacity)
        panel.alphaValue = opacity
        if showsReadout { view.showReadout("\(Int((opacity * 100).rounded()))%") }
    }

    func nudge(_ direction: PinNudge, large: Bool) {
        guard isPresented else { return }
        panel.setFrameOrigin(PinGeometry.nudged(panel.frame, direction, large: large).origin)
    }

    // MARK: Style

    /// Draws `style` as the item allows (a transparent picture keeps only the shadow) and redoes the shadow.
    private func applyStyle() {
        view.apply(style.effective(isTransparent: item.isTransparent), isTransparent: item.isTransparent)
        panel.hasShadow = style.shadow
        panel.invalidateShadow()
    }

    // MARK: Lock

    /// Follows the pointer while the pin is locked and on screen: the badge shows while the pointer is over the pin or
    /// the badge, and a hide-on-hover pin is faded out meanwhile.
    func trackPointer(at location: CGPoint) {
        guard isLocked, isPresented, panel.isVisible else { return }
        let inside = NSMouseInRect(location, panel.frame, false)
            || (badge.isVisible && NSMouseInRect(location, badge.frame, false))
        guard inside != pointerInside else { return }
        pointerInside = inside
        if inside { showBadge() } else { hideBadge() }
        updateHoverFade()
    }

    /// A hide-on-hover pin fades out over 0.15 s while the pointer is over it, and back to its opacity when it leaves.
    private func updateHoverFade() {
        guard isPresented, panel.isVisible else { return }
        setAlpha(hidesOnHover && pointerInside ? 0 : opacity,
                 duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15)
    }

    /// Animates the panel's alpha; a zero duration sets it at once and replaces a fade still in flight.
    private func setAlpha(_ alpha: Double, duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = alpha
        }
    }

    private func showBadge() {
        placeBadge()
        guard badge.parent == nil else { return }
        // A child window moves with the pin and stays above it.
        panel.addChildWindow(badge, ordered: .above)
        badge.orderFrontRegardless()
        badge.invalidateShadow()
    }

    private func placeBadge() {
        badge.setFrame(PinLockBadge.frame(forPin: panel.frame), display: false)
    }

    /// Detached and ordered out explicitly: a child of an ordered-out parent can linger on screen.
    private func hideBadge() {
        if badge.parent != nil { panel.removeChildWindow(badge) }
        badge.orderOut(nil)
    }

    // MARK: Hiding and closing

    /// Orders the pin and its badge out (Toggle Pins Visibility). Ordered out from under the pointer it gets no
    /// `mouseExited`, so its hover is reset, and it comes back at its opacity. It stays locked if it was.
    func hide() {
        hideBadge()
        pointerInside = false
        view.resetHover()
        if isPresented { setAlpha(opacity, duration: 0) }
        panel.orderOut(nil)
    }

    /// Brings a hidden pin back, without taking key, and redoes its shadow.
    func show() {
        guard isPresented else { return }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// Orders the badge and the panel out, and Quick Look first if it ever took this panel as its controller: Quick Look
    /// keeps an unretained reference to it.
    func close() {
        hideBadge()
        if QLPreviewPanel.sharedPreviewPanelExists(), let preview = QLPreviewPanel.shared(),
           (preview.currentController as AnyObject?) === panel {
            preview.orderOut(nil)
        }
        panel.orderOut(nil)
    }
}
