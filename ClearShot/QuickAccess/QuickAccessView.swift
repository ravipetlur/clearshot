import AppKit
import CSCore
import CSHistory
import CSRecording

/// What a thumbnail asks its manager to do. `trim` opens a video or GIF in the Video Editor with its trimming handles
/// up.
enum QuickAccessCommand: Equatable {
    case copy, save, showInFinder, close, trash, annotate, pin, quickLook, trim
    case submitName(String), discard
    case swipeAway, hideAll
}

/// What a video or GIF thumbnail shows besides its picture: the badge, and what its hover preview plays, the working
/// copy (a GIF itself, so a trimmed GIF previews only what it holds).
struct QuickAccessMedia: Equatable {
    var badge: MediaBadge
    var preview: HoverPreviewSource
    /// When the working copy last changed, so a preview playing while Mute, Replace or Trim the GIF… swaps the file starts
    /// again on the new one.
    var modifiedAt: Date?
    /// False for a GIF opened from a file, which has no source video to trim: it has no pencil or Trim button.
    var opensInVideoEditor: Bool

    /// Nil for a screenshot.
    init?(item: HistoryItem, root: URL) {
        guard let badge = MediaBadge(item: item, root: root) else { return nil }
        self.badge = badge
        let file = item.mediaURL(in: root)
        preview = item.kind == .gif ? .gif(file) : .video(file)
        modifiedAt = item.modifiedAt
        opensInVideoEditor = item.opensInVideoEditor(root: root)
    }
}

/// What a drag carries: `file` (the saved file, or the working copy) and, for a screenshot, the lossless PNG for
/// image-only targets; nil for a video or GIF, which carries only its file.
struct QuickAccessDragFiles {
    var file: URL
    var png: URL?
}

protocol QuickAccessViewDelegate: AnyObject {
    func quickAccessView(_ view: QuickAccessView, perform command: QuickAccessCommand, optionHeld: Bool)
    func quickAccessView(_ view: QuickAccessView, hoverChanged hovering: Bool)
    func quickAccessViewDragFiles(_ view: QuickAccessView) -> QuickAccessDragFiles?
    func quickAccessView(_ view: QuickAccessView, dragEndedWith operation: NSDragOperation, optionHeld: Bool)
    func quickAccessViewMenu(_ view: QuickAccessView) -> NSMenu?
}

/// One Quick Access thumbnail: the image, the hover buttons, the name strip, drag-out, swipe gestures and the
/// right-click menu. A video or GIF also has its badge, a Trim button beside the pencil (which opens the Video Editor;
/// a GIF opened from a file has neither), no Pin, and a looping preview (a video muted, a GIF as itself) while the
/// pointer is over it.
final class QuickAccessView: NSView, NSDraggingSource {
    weak var delegate: QuickAccessViewDelegate?
    /// The "Save button" setting: Save asks where to save unless ⌥ is held. The manager keeps it current.
    var saveAsksByDefault = false {
        didSet { if saveAsksByDefault != oldValue { refreshSaveTitle() } }
    }

    /// The corner buttons' side; the badge is centred on the trash button's row.
    private static let circleSize: CGFloat = 22

    private let thumbnailView = ThumbnailView()
    private let previewView = HoverPreviewView()
    private let dimView = PassthroughView()
    private let badgeView = MediaBadgeView()
    private let controls = PassthroughView()
    private let copyButton = PillButton(label: "Copy")
    private let saveButton = PillButton(label: "Save")
    private let closeButton = CircleButton(symbol: "xmark", label: "Close")
    private let annotateButton = CircleButton(symbol: "pencil", label: "Annotate")
    private let trimButton = CircleButton(symbol: "scissors", label: "Trim")
    private let pinButton = CircleButton(symbol: "pin", label: "Pin to the screen")
    private let trashButton = CircleButton(symbol: "trash", label: "Move to Trash")
    private let nameStrip = NSView()
    private let nameField = NSTextField()
    private let nameSaveButton = FirstMouseButton(title: "Save", target: nil, action: nil)
    private let discardButton = FirstMouseButton(title: "Discard", target: nil, action: nil)

    private var thumbnail: CGImage?
    /// Nil for a screenshot.
    private var media: QuickAccessMedia?
    private var isSaved = false
    private var isNewest = false
    private var isNaming = false
    private var isHovering = false
    private var swipe = SwipeTracker()
    private var mouseDownEvent: NSEvent?
    private var dragOptionHeld = false
    /// True from the start of a drag-out until it ends: the pointer leaving the thumbnail then isn't a hover change.
    private var isDragging = false
    /// Kept for the drag's lifetime: a drop target may ask for the PNG after the drag image is gone.
    private var dragProvider: DragImageProvider?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        buildControls()
        buildNameStrip()
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Keyboard focus

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        NotificationCenter.default.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
    }

    /// The hover buttons never take first responder, so a click on one would leave the window itself focused and
    /// Space with nowhere to go. Taking focus whenever the panel becomes key keeps ⌘ shortcuts and Space working.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard !isNaming else { return }
        window?.makeFirstResponder(self)
    }

    // MARK: Configuration

    /// `name` is non-nil while the thumbnail asks for a file name. The newest of several thumbnails gets an accent
    /// border. `media` is a video's or GIF's badge and preview, nil for a screenshot.
    func configure(thumbnail: CGImage?, isSaved: Bool, isNewest: Bool, naming name: String?, media: QuickAccessMedia?) {
        self.thumbnail = thumbnail
        thumbnailView.image = thumbnail
        self.isSaved = isSaved
        self.isNewest = isNewest
        let previewChanged = media?.preview != self.media?.preview || media?.modifiedAt != self.media?.modifiedAt
        self.media = media
        badgeView.content = media?.badge
        annotateButton.setLabel(media == nil ? "Annotate" : "Video Editor")
        // A GIF opened from a file can't be trimmed, so the Video Editor has nothing to open for it.
        annotateButton.isHidden = media?.opensInVideoEditor == false
        trimButton.isHidden = media?.opensInVideoEditor != true
        // A video or GIF can't be pinned, so it has no Pin button (its menu leaves Pin out too).
        pinButton.isHidden = media != nil
        if previewChanged {
            // A new file under a running preview: start again on it.
            previewView.stop()
            updatePreview()
        }
        if let name, !isNaming { nameField.stringValue = name }
        let wasNaming = isNaming
        isNaming = name != nil
        // The name strip is about to be hidden. Focus left in it (the field editor is a descendant of the text field)
        // would make the panel treat every ⌘ shortcut and Space as text editing.
        if wasNaming, !isNaming, (window?.firstResponder as? NSView)?.isDescendant(of: nameStrip) == true {
            window?.makeFirstResponder(self)
        }
        // On every thumbnail: Delete removes an unsaved capture; Move to Trash also trashes a saved one's file.
        trashButton.setLabel(isSaved ? "Move to Trash" : "Delete")
        refreshSaveTitle()
        applyColors()
        updateControlsVisibility()
        needsLayout = true
    }

    /// Focuses the name field with its text selected, so typing replaces the suggested name.
    func beginEditingName() {
        guard isNaming, let window else { return }
        window.makeKey()
        window.makeFirstResponder(nameField)
        nameField.currentEditor()?.selectAll(nil)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let strip = isNaming ? QuickAccessLayout.nameStripHeight : 0
        let imageRect = NSRect(x: 0, y: strip, width: bounds.width, height: max(0, bounds.height - strip))
        thumbnailView.frame = imageRect
        // The preview fills the thumbnail's frame, which `QuickAccessLayout` clamps for a portrait video.
        previewView.frame = imageRect
        dimView.frame = imageRect
        controls.frame = imageRect
        nameStrip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: strip)
        nameStrip.isHidden = !isNaming
        layoutControls(in: controls.bounds)
        layoutBadge(in: imageRect)
        layoutNameStrip(in: nameStrip.bounds)
    }

    /// Bottom-left, centred on the trash button's row; while the hover buttons show, it moves along to the trash
    /// button's right (videos have no Pin button at the other end).
    private func layoutBadge(in rect: NSRect) {
        let inset: CGFloat = 6
        let x = controls.isHidden ? rect.minX + inset : convert(trashButton.frame, from: controls).maxX + inset
        let size = badgeView.fittingSize(maxWidth: rect.maxX - inset - x)
        badgeView.frame = NSRect(x: x, y: rect.minY + inset + (Self.circleSize - size.height) / 2, width: size.width,
                                 height: size.height)
    }

    private func layoutControls(in rect: NSRect) {
        let pill = NSSize(width: min(112, rect.width - 24), height: 26)
        let x = rect.midX - pill.width / 2
        copyButton.frame = NSRect(x: x, y: rect.midY + 3, width: pill.width, height: pill.height)
        saveButton.frame = NSRect(x: x, y: rect.midY - 3 - pill.height, width: pill.width, height: pill.height)
        let size = Self.circleSize
        let inset: CGFloat = 6
        closeButton.frame = NSRect(x: rect.minX + inset, y: rect.maxY - inset - size, width: size, height: size)
        annotateButton.frame = NSRect(x: rect.maxX - inset - size, y: rect.maxY - inset - size, width: size, height: size)
        trimButton.frame = annotateButton.frame.offsetBy(dx: -(size + 4), dy: 0)
        trashButton.frame = NSRect(x: rect.minX + inset, y: rect.minY + inset, width: size, height: size)
        pinButton.frame = NSRect(x: rect.maxX - inset - size, y: rect.minY + inset, width: size, height: size)
    }

    private func layoutNameStrip(in rect: NSRect) {
        guard isNaming else { return }
        nameField.frame = NSRect(x: 8, y: rect.maxY - 8 - 22, width: rect.width - 16, height: 22)
        let height: CGFloat = 24
        let saveWidth = max(nameSaveButton.fittingSize.width, 60)
        let discardWidth = max(discardButton.fittingSize.width, 70)
        nameSaveButton.frame = NSRect(x: rect.maxX - 6 - saveWidth, y: 6, width: saveWidth, height: height)
        discardButton.frame = NSRect(x: nameSaveButton.frame.minX - 4 - discardWidth, y: 6, width: discardWidth, height: height)
    }

    private func buildControls() {
        for view in [thumbnailView, previewView, dimView, badgeView, controls, nameStrip] as [NSView] {
            addSubview(view)
        }
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        dimView.alphaValue = 0
        trimButton.isHidden = true
        for button in [copyButton, saveButton, closeButton, annotateButton, trimButton, pinButton, trashButton] as [NSButton] {
            button.target = self
            button.action = #selector(controlPressed(_:))
            controls.addSubview(button)
        }
        controls.isHidden = true
    }

    private func buildNameStrip() {
        nameField.placeholderString = "File name"
        nameField.controlSize = .small
        nameField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.isScrollable = true
        nameField.cell?.sendsActionOnEndEditing = false
        nameField.target = self
        nameField.action = #selector(controlPressed(_:))
        for button in [nameSaveButton, discardButton] {
            button.controlSize = .small
            button.bezelStyle = .push
            button.target = self
            button.action = #selector(controlPressed(_:))
        }
        nameStrip.addSubview(nameField)
        nameStrip.addSubview(nameSaveButton)
        nameStrip.addSubview(discardButton)
        nameStrip.isHidden = true
    }

    // MARK: Appearance

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = (isNewest ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        }
        layer?.borderWidth = isNewest ? 2 : 1
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovering(true) }
    override func mouseExited(with event: NSEvent) {
        // A drag-out leaves the thumbnail on purpose; hover is settled when the drag ends.
        guard !isDragging else { return }
        setHovering(false)
    }
    override func mouseMoved(with event: NSEvent) { refreshSaveTitle() }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        refreshSaveTitle()
        updateControlsVisibility()
        updatePreview()
        delegate?.quickAccessView(self, hoverChanged: hovering)
    }

    /// Forgets the hover without telling the delegate. A panel ordered out from under the pointer gets no `mouseExited`,
    /// so the manager calls this when it hides the stack.
    func resetHover() {
        isHovering = false
        refreshSaveTitle()
        updateControlsVisibility()
        updatePreview()
    }

    /// Stops a video's or GIF's preview and lets go of its player: for a thumbnail closing or ordered out.
    func stopPreview() {
        previewView.stop()
    }

    private func updateControlsVisibility() {
        let show = isHovering && !isNaming
        controls.isHidden = !show
        // The badge moves aside for the trash button.
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            dimView.animator().alphaValue = show ? 1 : 0
        }
    }

    /// A video (muted) or GIF plays, looping, only while the pointer is over it.
    private func updatePreview() {
        if isHovering, let media {
            previewView.play(media.preview)
        } else {
            previewView.stop()
        }
    }

    /// "Save", or "Save As…" when Save will ask where (the setting, flipped while ⌥ is held), or "Show in Finder" once
    /// the capture is saved.
    private func refreshSaveTitle() {
        let asks = QuickAccessRules.saveAsksForLocation(optionHeld: NSEvent.modifierFlags.contains(.option),
                                                        askByDefault: saveAsksByDefault)
        saveButton.setLabel(isSaved ? "Show in Finder" : asks ? "Save As…" : "Save")
    }

    // MARK: Buttons

    @objc private func controlPressed(_ sender: NSControl) {
        let command: QuickAccessCommand
        if sender === copyButton {
            command = .copy
        } else if sender === saveButton {
            command = isSaved ? .showInFinder : .save
        } else if sender === closeButton {
            command = .close
        } else if sender === annotateButton {
            command = .annotate
        } else if sender === trimButton {
            command = .trim
        } else if sender === pinButton {
            command = .pin
        } else if sender === trashButton {
            command = .trash
        } else if sender === nameField || sender === nameSaveButton {
            command = .submitName(nameField.stringValue)
        } else if sender === discardButton {
            command = .discard
        } else {
            return
        }
        delegate?.quickAccessView(self, perform: command, optionHeld: NSEvent.modifierFlags.contains(.option))
    }

    // MARK: Mouse: click, double-click, drag-out

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if !isNaming { window?.makeFirstResponder(self) }
        if event.clickCount == 2 {
            mouseDownEvent = nil
            delegate?.quickAccessView(self, perform: .annotate, optionHeld: event.modifierFlags.contains(.option))
            return
        }
        mouseDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent else { return }
        let from = start.locationInWindow
        let to = event.locationInWindow
        guard hypot(to.x - from.x, to.y - from.y) >= 4 else { return }
        mouseDownEvent = nil
        guard let files = delegate?.quickAccessViewDragFiles(self) else { return }
        dragOptionHeld = event.modifierFlags.contains(.option)
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(files.file.absoluteString, forType: .fileURL)
        dragProvider = files.png.map(DragImageProvider.init(pngURL:))
        if let dragProvider { pasteboardItem.setDataProvider(dragProvider, forTypes: [.png]) }
        let item = NSDraggingItem(pasteboardWriter: pasteboardItem)
        item.setDraggingFrame(thumbnailView.frame, contents: thumbnail.map { NSImage(cgImage: $0, size: thumbnailView.frame.size) })
        isDragging = true
        beginDraggingSession(with: [item], event: start, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy, never move: dropping into Finder must leave the saved file where it is.
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        // The pointer may have left while mouseExited was ignored; settle hover now, before the delegate can close us.
        if let window, !bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)) {
            setHovering(false)
        }
        delegate?.quickAccessView(self, dragEndedWith: operation,
                                  optionHeld: dragOptionHeld || NSEvent.modifierFlags.contains(.option))
    }

    // MARK: Gestures, menu, keys

    override func scrollWheel(with event: NSEvent) {
        // Trackpad gestures only: a mouse wheel has no phase, and momentum after the fingers lift is ignored.
        guard event.momentumPhase.isEmpty, !event.phase.isEmpty else { return }
        if event.phase.contains(.began) { swipe.begin() }
        let fingersDown = event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
        switch swipe.add(deltaX: event.scrollingDeltaX, fingersDown: fingersDown) {
        case .dismiss: delegate?.quickAccessView(self, perform: .swipeAway, optionHeld: false)
        case .hideAll: delegate?.quickAccessView(self, perform: .hideAll, optionHeld: false)
        case .none: break
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        delegate?.quickAccessViewMenu(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            delegate?.quickAccessView(self, perform: .quickLook, optionHeld: false)
        } else {
            super.keyDown(with: event)
        }
    }
}
