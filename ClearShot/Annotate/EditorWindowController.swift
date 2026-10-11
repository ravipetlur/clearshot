import AppKit
import CSAnnotation
import CSCore
import CSSensitive
import Observation
import SwiftUI
import UniformTypeIdentifiers

enum ChangesChoice {
    case keep, discard, cancel
}

/// One editor window: resizable, ⌘Tab-able while the Dock icon is on, optionally always on top. It answers the main
/// menu's editor items (File, View), which reach it through the responder chain.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let editor: AnnotationEditor
    let canvas = CanvasController()
    /// The manager owns every controller and outlives it, so the reference is never dangling.
    private unowned let manager: AnnotateManager
    private let onClose: (EditorWindowController) -> Void
    private var hasPresented = false
    /// The window has closed: a Take Screenshot still running has nowhere to come back to.
    private var isClosed = false
    /// The scan a Mask Sensitive Info is running, nil when none is. While it runs the command is off, so it can't run twice
    /// (the tool strip's button follows: `AnnotateSensitiveCheck.isMasking`); closing the window cancels it.
    private var maskScan: Task<Void, Never>? {
        didSet { sensitiveCheck.isMasking = maskScan != nil }
    }
    /// The "Checking for sensitive info…" HUD that scan has up, so that closing the window takes it down (`HUDController.hide`)
    /// instead of leaving it for its 30 seconds. Nil when the command had a scan's result already and showed none.
    private var maskProgress: Int?
    /// What the tool strip's sensitive-info button shows, and the background scan behind it. It sits beside the command: a click
    /// on the button is the command.
    let sensitiveCheck: AnnotateSensitiveCheck

    init(editor: AnnotationEditor, manager: AnnotateManager, alwaysOnTop: Bool,
         onClose: @escaping (EditorWindowController) -> Void) {
        self.editor = editor
        self.manager = manager
        self.onClose = onClose
        sensitiveCheck = AnnotateSensitiveCheck(editor: editor, preferences: manager.preferences)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = editor.title
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
        window.level = alwaysOnTop ? .floating : .normal
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: EditorView(editor: editor, canvas: canvas, actions: makeActions(),
                                                               sensitive: sensitiveCheck))
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(Self.initialSize(for: editor))
        // Before the canvas exists: it passes these on through the controller.
        canvas.imageProblem = { [weak self] problem in self?.showImageProblem(problem) }
        canvas.toggleBackgroundPanel = { [weak self] in self?.toggleBackgroundTool(nil) }
        observeEdits()
        // Scans the picture the editor opened with, and again whenever it changes.
        sensitiveCheck.start()
    }

    /// The close button's dot shows edits not yet applied.
    private func observeEdits() {
        withObservationTracking {
            window?.isDocumentEdited = editor.hasUnappliedChanges
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeEdits() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The image (the background's frame, or the canvas) at 100% plus the bars, within 85% of the screen.
    private static func initialSize(for editor: AnnotationEditor) -> NSSize {
        let output = editor.outputBounds
        let scale = editor.document.pixelScale
        let wanted = NSSize(width: output.width / scale + 48, height: output.height / scale + 120)
        let visible = (NSScreen.activeScreen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(max(wanted.width, 720), visible.width * 0.85),
                      height: min(max(wanted.height, 480), visible.height * 0.85))
    }

    /// Brings the editor forward. Only the first time does it centre the window and fit the picture, and open the
    /// Background panel if the last editor closed with it open; a repeat ⌘E, or the quit prompt, must not reset the
    /// person's zoom.
    func present() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        let first = !hasPresented
        hasPresented = true
        if first { window.center() }
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        if first {
            window.layoutIfNeeded()
            canvas.zoomToFit()
            let preferences = manager.preferences
            if preferences[Prefs.annotateRememberBackgroundTool], preferences[Prefs.annotateBackgroundToolWasOpen] {
                // The panel takes width from the canvas: fit again beside it.
                openBackgroundPanel(thenZoomToFit: true)
            }
        }
        // On every presentation, not only the first: the canvas may not exist yet when the window first appears.
        canvas.canvas?.copyWholeImage = { [weak self] in self?.makeActions().copy() }
        // The text being typed keeps the keyboard: a repeat ⌘E mustn't send its letters to the canvas, where they pick tools.
        if let view = canvas.canvas { window.makeFirstResponder(view.inlineTextView ?? view) }
    }

    /// Applies the edits, then closes the window, unless the person kept drawing while the write ran: those edits are
    /// still unapplied, so the window stays.
    private func done() {
        canvas.canvas?.finishEditing()
        Task {
            guard await manager.apply(editor) else { return }
            // A crop begun during the write is applied now, so it counts as the edit it is and keeps the window open.
            canvas.canvas?.finishEditing()
            if !editor.hasUnappliedChanges { close() }
        }
    }

    private func makeActions() -> EditorActions {
        EditorActions(
            done: { [weak self] in self?.done() },
            save: { [weak self] in self?.run { _ = await $0.manager.save($0.editor) } },
            saveAs: { [weak self] closeAfter in
                let skip = NSEvent.modifierFlags.contains(.option)
                self?.run { controller in
                    if await controller.manager.saveAs(controller.editor, skipDialog: skip), closeAfter { controller.closeAfterSaving() }
                }
            },
            copy: { [weak self] in self?.run { await $0.manager.copyImage($0.editor) } },
            share: { [weak self] view in self?.run { await $0.manager.share($0.editor, from: view) } },
            printImage: { [weak self] fit in self?.run { await $0.manager.printImage($0.editor, fitOnOnePage: fit) } },
            raycast: { [weak self] in self?.run { await $0.manager.sendToRaycast($0.editor) } },
            pin: { [weak self] in self?.run { await $0.manager.pin($0.editor) } },
            dragFile: { [weak self] in
                guard let self else { return nil }
                // The drag carries the text being typed too, and a pending crop.
                canvas.canvas?.finishEditing()
                return manager.dragFile(for: editor)
            },
            resize: { [weak self] in self?.showResizeSheet() },
            focusCanvas: { [weak self] in
                guard let self, let view = canvas.canvas else { return }
                window?.makeFirstResponder(view)
            },
            takeScreenshot: { [weak self] in self?.takeScreenshot(nil) },
            pasteImage: { [weak self] in self?.pasteImageFromClipboard(nil) },
            chooseImage: { [weak self] in self?.chooseImage(nil) },
            toggleBackgroundPanel: { [weak self] in self?.toggleBackgroundTool(nil) },
            backgroundPictures: { [weak self] in self?.backgroundPictures() ?? BackgroundPictureSource.none },
            endTextEditing: { [weak self] in self?.canvas.canvas?.endTextEditing() },
            backgroundLibrary: manager.pictures.library,
            addBackgroundPicture: { [weak self] in self?.addBackgroundPicture() },
            removeBackgroundPicture: { [weak self] id in self?.removeBackgroundPicture(id) },
            desktopPictureURL: { [weak self] in
                guard let screen = self?.window?.screen ?? NSScreen.main else { return nil }
                return NSWorkspace.shared.desktopImageURL(for: screen)
            },
            maskSensitiveInfo: { [weak self] in self?.maskSensitiveInfo(nil) }
        )
    }

    /// "Save As… and Close" and "Save and Close". `close()` skips `windowShouldClose`, so it is only for an editor with
    /// nothing left unapplied (a saved capture, or a project saved as a project, which continues with the new file).
    /// Otherwise some edits exist only in the exported file, or were made while the save ran, and closing goes through
    /// the Keep / Discard / Cancel question like any other close.
    private func closeAfterSaving() {
        // A crop begun while the save ran is still pending; applying it makes it an edit the close question covers.
        canvas.canvas?.finishEditing()
        if editor.hasUnappliedChanges {
            window?.performClose(nil)
        } else {
            close()
        }
    }

    /// Runs an output after finishing any inline text edit, then follows the file's name: a Save As of a project, or a
    /// Save that had to pick a free name, renames the document.
    private func run(_ work: @escaping (EditorWindowController) async -> Void) {
        canvas.canvas?.finishEditing()
        Task {
            await work(self)
            window?.title = editor.title
        }
    }

    // MARK: Menu items: every main action has a menu item and a shortcut

    /// Holding a shortcut down repeats it: the outputs take the key but act once.
    private var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// Typing in the inline text editor keeps the keys a text view uses.
    private var isTyping: Bool { window?.firstResponder is NSText }

    @objc func saveImage(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().save()
    }

    @objc func saveImageAs(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().saveAs(false)
    }

    /// ⌥ Save As: the last folder and format, no dialog.
    @objc func saveImageAsWithoutDialog(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        run { _ = await $0.manager.saveAs($0.editor, skipDialog: true) }
    }

    /// "Save and exit": Save, then close if nothing is left unapplied.
    @objc func saveAndClose(_ sender: Any?) {
        run { controller in
            if await controller.manager.save(controller.editor) { controller.closeAfterSaving() }
        }
    }

    @objc func copyImage(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().copy()
    }

    @objc func sendToRaycast(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().raycast()
    }

    @objc func printImage(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().printImage(true)
    }

    /// File › Pin to the Screen (D-P10), as the Pin button. It has no key equivalent; one can be assigned in System
    /// Settings › Keyboard › App Shortcuts.
    @objc func pinToScreen(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        makeActions().pin()
    }

    @objc func zoomIn(_ sender: Any?) { canvas.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { canvas.zoomOut() }
    @objc func zoomToActualSize(_ sender: Any?) { canvas.zoom(to: 1) }
    @objc func zoomToFit(_ sender: Any?) { canvas.zoomToFit() }

    // MARK: Crop & Resize

    @objc func cropAndResize(_ sender: Any?) {
        // Text being typed holds a live change open, and a crop session can't start under one.
        canvas.canvas?.endTextEditing()
        editor.tool = .crop
    }

    @objc func rotateImageLeft(_ sender: Any?) {
        canvas.canvas?.endTextEditing()
        editor.rotateLeft()
    }

    @objc func rotateImageRight(_ sender: Any?) {
        canvas.canvas?.endTextEditing()
        editor.rotateRight()
    }

    @objc func flipImageHorizontally(_ sender: Any?) {
        canvas.canvas?.endTextEditing()
        editor.flipHorizontally()
    }

    @objc func flipImageVertically(_ sender: Any?) {
        canvas.canvas?.endTextEditing()
        editor.flipVertically()
    }

    @objc func resizeImage(_ sender: Any?) {
        showResizeSheet()
    }

    @objc func revertToOriginal(_ sender: Any?) {
        canvas.canvas?.endTextEditing()
        editor.revertToOriginal()
    }

    /// Resize Image… as a sheet on the editor, starting from the output's size in pixels (the background's frame, or
    /// the canvas) and held to the editor's `resizeLimit`.
    private func showResizeSheet() {
        guard let window, window.attachedSheet == nil else { return }
        canvas.canvas?.endTextEditing()
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        let close: () -> Void = { [weak window, weak sheet] in
            if let window, let sheet { window.endSheet(sheet) }
        }
        let hosting = NSHostingController(rootView: ResizeSheet(size: editor.outputBounds.size, limit: editor.resizeLimit,
                                                                onResize: { [weak self] width, height in
            self?.editor.resizeImage(width: width, height: height)
            close()
        }, onCancel: close))
        sheet.contentViewController = hosting
        sheet.setContentSize(hosting.view.fittingSize)
        window.beginSheet(sheet)
    }

    // MARK: Mask Sensitive Info

    /// Edit › Mask Sensitive Info (or Unmask Sensitive Info), and the tool strip's sensitive-info button, which runs this same
    /// method. It is a toggle (`SensitiveButtonState.action`):
    /// - **Masked look** (the document holds masks the secrets check made, and no unmasked finding is known): takes every one of
    ///   those masks out as one undo step, and says "Unmasked N items". The person's own redactions stay.
    /// - **Otherwise** scans the picture as it is now for the kinds switched on in Settings › Quick Access, and adds a Pixelate mask
    ///   over each finding, all as one undo step (`SensitiveInfoScan` says what is scanned and how the masks are placed). It is an
    ///   explicit request, so the switch that turns the automatic checks off doesn't apply to it, only the four kinds do; with none
    ///   on there is nothing to look for, and the item and the button are off (unless there are masks to take out).
    ///
    /// Both refuse the same way (a crop or a drag begun meanwhile) and never run twice at once.
    ///
    /// The button's own background scan (`AnnotateSensitiveCheck`) reads the same picture the same way. When it has read exactly
    /// this picture for these kinds, its masks are the ones a scan would make now, and are used instead of scanning again; the
    /// rest, the refusals and the one-run-at-a-time rule included, is the same either way, and the button is told what the run
    /// found, so it shows the outcome at once.
    ///
    /// Nothing is logged but counts and the time it took.
    @objc func maskSensitiveInfo(_ sender: Any?) {
        let kinds = manager.preferences[Prefs.sensitiveKinds]
        guard maskScan == nil, !isClosed, window?.attachedSheet == nil else { return }
        // Nothing to look for and nothing to take out.
        guard !kinds.isEmpty || editor.document.secretsMaskCount > 0 else { return }
        // Text being typed and a pending crop are part of the picture: finish them first, as an output does.
        canvas.canvas?.finishEditing()
        // The state catches up with the document before it says what a click does.
        sensitiveCheck.refresh()
        if sensitiveCheck.state.action == .unmask {
            unmaskSensitiveInfo()
            return
        }
        guard !kinds.isEmpty else { return }
        let document = editor.document
        let images = editor.images
        let picture = document.pictureIdentity
        let ready = sensitiveCheck.takeFound(for: picture, kinds: kinds)
        let hud = manager.hud
        // Long enough that it can't fade while a big picture is read in tiles; the result replaces it. A scan that is ready
        // needs no message.
        let progress = ready == nil ? hud.show(MaskCommandText.checking, symbol: "magnifyingglass", duration: .seconds(30)) : nil
        maskProgress = progress
        maskScan = Task { [weak self] in
            let outcome: Result<SensitiveInfoScan.Found, any Error>
            if let ready {
                outcome = .success(ready)
            } else {
                do {
                    outcome = .success(try await SensitiveInfoScan.run(document, images: images, kinds: kinds))
                } catch {
                    outcome = .failure(error)
                }
            }
            // The scan can return normally when the cancel came after its last check, so a result is dropped here too: a window
            // that has closed has nowhere to show it, and nothing is added to its document.
            guard let self, !Task.isCancelled, !isClosed else {
                if let progress { hud.hide(progress) }
                return
            }
            maskScan = nil
            maskProgress = nil
            finishMaskScan(outcome, of: picture, kinds: kinds, wasReady: ready != nil)
        }
    }

    /// The masked look's click: takes out every mask the secrets check made, as one undo step of its own, and says how many.
    /// Nothing is scanned, so there is nothing to wait for or to run twice: the removal takes every marked mask, and a second one
    /// that comes before the first has landed finds none and does nothing.
    private func unmaskSensitiveInfo() {
        let hud = manager.hud
        editor.asOneUndoStep { [weak self] in
            guard let self, !isClosed else { return }
            guard let removed = editor.removeSecretsMasks(actionName: MaskCommandText.unmaskCommandName) else {
                // A crop, a drag or text being typed began: not interrupted, nothing removed.
                hud.show(MaskCommandText.unmaskEditInProgress, symbol: "exclamationmark.triangle.fill")
                return
            }
            guard removed > 0 else { return }
            Log.annotate.info("Unmask Sensitive Info: \(MaskCommandText.unmaskLogSummary(masksRemoved: removed))")
            // The document is the picture it was before the masks (or one nobody has read): the button shows the warning again, with
            // a scan only when it has to.
            sensitiveCheck.refresh()
            hud.show(MaskCommandText.unmaskResult(masksRemoved: removed), symbol: "eye")
        }
    }

    /// The command's result: the HUD says what was masked, and the button is told what the run found or masked. `picture` is
    /// the one that was scanned, which an undo of the masks makes again.
    private func finishMaskScan(_ outcome: Result<SensitiveInfoScan.Found, any Error>, of picture: PictureIdentity,
                                kinds: SensitiveKinds, wasReady: Bool) {
        let hud = manager.hud
        switch outcome {
        case .failure(let error):
            Log.annotate.error("Mask Sensitive Info couldn't check the image: \(error)")
            sensitiveCheck.failed(of: picture, kinds: kinds)
            hud.show(MaskCommandText.couldntCheck, symbol: "exclamationmark.triangle.fill")
        case .success(let found):
            let summary = MaskCommandText.logSummary(findings: found.findings, masksAdded: found.masks.count)
            // A ready scan's time is the background check's, made earlier.
            Log.annotate.info("Mask Sensitive Info: \(summary)" + (wasReady ? ", from the check made earlier" : " in \(BadgeText.seconds(found.duration)) s"))
            guard !found.masks.isEmpty else {
                sensitiveCheck.checked(found, of: picture, kinds: kinds)
                hud.show(MaskCommandText.result(masksAdded: 0), symbol: "checkmark.circle")
                return
            }
            // Masks are in the document's own pixels (base pixels), so a turn, crop or resize made while the scan ran doesn't
            // misplace them. They are one undo step of their own, apart from anything recorded in the same event.
            editor.asOneUndoStep { [weak self] in
                guard let self, !isClosed else { return }
                if editor.addMasks(found.masks, actionName: MaskCommandText.commandName) {
                    sensitiveCheck.masked(found, of: picture, kinds: kinds)
                    hud.show(MaskCommandText.result(masksAdded: found.masks.count), symbol: "eye.slash")
                } else {
                    // A crop, a drag or text being typed began while the scan ran: not interrupted, nothing added.
                    sensitiveCheck.checked(found, of: picture, kinds: kinds)
                    hud.show(MaskCommandText.editInProgress, symbol: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    // MARK: The Background tool

    /// Edit › Background Tool, the tool strip's button and the panel's letter: shows or hides the Background panel. Text
    /// being typed is finished first: it holds a live change open, under which opening the panel would add no background.
    /// Holding the letter down toggles once.
    @objc func toggleBackgroundTool(_ sender: Any?) {
        guard !isKeyRepeat else { return }
        canvas.canvas?.endTextEditing()
        if editor.isBackgroundPanelOpen {
            editor.closeBackgroundPanel()
        } else {
            openBackgroundPanel()
        }
    }

    /// Opens the panel, which gives a document without a background its default style, as one undo step, once the
    /// picture of an image-backed fill has been fetched. `thenZoomToFit` fits the canvas again once the panel is up, for the
    /// first presentation, whose fit was made without it. A window closed meanwhile takes its editor with it: the open
    /// then does nothing.
    private func openBackgroundPanel(thenZoomToFit: Bool = false) {
        let pictures = backgroundPictures()
        Task { [weak self, weak editor] in
            await editor?.openBackgroundPanel(pictures: pictures)
            if thenZoomToFit { self?.canvas.zoomToFit() }
        }
    }

    /// The pictures of image-backed fills for the screen the window is on.
    private func backgroundPictures() -> BackgroundPictureSource {
        manager.pictures.source(for: window?.screen)
    }

    /// Add background…: a picture file copied into the background library, for the panel to apply. A file ImageIO can't
    /// read as a picture, or one that can't be copied, is refused with the HUD. Nil then, and when the open panel is
    /// cancelled.
    private func addBackgroundPicture() -> UUID? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a picture for the background"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try manager.pictures.library.add(copying: url).id
        } catch {
            Log.annotate.error("Couldn't add \(url.lastPathComponent) to the background pictures: \(error)")
            manager.hud.show("Couldn't use that image as a background", symbol: "exclamationmark.triangle.fill")
            return nil
        }
    }

    /// A custom background tile's Remove: deletes the picture from the library. Documents that show it keep their own copy.
    private func removeBackgroundPicture(_ id: UUID) {
        do {
            try manager.pictures.library.remove(id)
        } catch {
            Log.annotate.error("Couldn't remove the background picture \(id): \(error)")
            manager.hud.show("Couldn't remove that background", symbol: "exclamationmark.triangle.fill")
        }
    }

    // MARK: Add Image

    /// Tells the person an image couldn't be read or added. The canvas stays silent for the cases that are the person's own
    /// state (a crop, a change in progress).
    private func showImageProblem(_ problem: ImageProblem) {
        let message = switch problem {
        case .unreadable: "Couldn't read the image"
        case .notAdded: "Couldn't add the image"
        }
        manager.hud.show(message, symbol: "exclamationmark.triangle.fill")
    }

    /// Take Screenshot…: the editor steps aside for an area selection, then comes back with the shot as an image object in
    /// the middle of what's visible. Cancelling brings it back unchanged. Images stay out of Crop & Resize.
    ///
    /// The editor steps aside only once the capture is allowed to start, so the permission alert and "A capture is already in
    /// progress" don't appear over a window that has just vanished. It comes back only if it is still open.
    @objc func takeScreenshot(_ sender: Any?) {
        guard let window, editor.crop == nil, let capture = manager.captureImage else { return }
        canvas.canvas?.finishEditing()
        Task {
            var didHide = false
            let picked = await capture {
                didHide = true
                window.orderOut(nil)
            }
            guard !isClosed else { return }
            if didHide {
                NSApp.activate()
                present()
            }
            guard let picked, let view = canvas.canvas else { return }
            view.addImage(picked, .centered(visible: view.visibleOutputRect))
        }
    }

    /// Paste Image from Clipboard: the clipboard's image files or image data as image objects.
    @objc func pasteImageFromClipboard(_ sender: Any?) {
        guard editor.crop == nil, let view = canvas.canvas else { return }
        view.finishEditing()
        // Only a pasteboard with no image at all says so; one with an image that doesn't load is reported as unreadable.
        guard ImageInput.hasImage(.general) else {
            manager.hud.show("There's no image on the clipboard", symbol: "doc.on.clipboard")
            return
        }
        view.addImages(ImageInput.pictures(from: .general), to: .visibleMiddle)
    }

    /// Choose Image…: an image file as an image object. The insert is an undo step of its own, as a drop's or a paste's is
    /// (`addImages`): the open panel runs a modal loop, which leaves the menu event's undo group open, so the text edit
    /// `finishEditing` recorded in it would otherwise be undone with the image.
    @objc func chooseImage(_ sender: Any?) {
        guard editor.crop == nil, let view = canvas.canvas else { return }
        view.finishEditing()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an image to add"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let picked = ImageInput.load(url) else {
            manager.hud.show("Couldn't open \(url.lastPathComponent)", symbol: "exclamationmark.triangle.fill")
            return
        }
        view.addImages(ImageInput.Pictures(images: [picked]), to: .visibleMiddle)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleBackgroundTool(_:)) {
            menuItem.state = editor.isBackgroundPanelOpen ? .on : .off
        }
        // "Mask Sensitive Info" or "Unmask Sensitive Info", as the button's state says a click does.
        if menuItem.action == #selector(maskSensitiveInfo(_:)) {
            menuItem.title = SensitiveButtonText.menuTitle(for: sensitiveCheck.state.phase)
        }
        return switch menuItem.action {
        case #selector(copyImage(_:)), #selector(sendToRaycast(_:)):
            !isTyping
        case #selector(saveImage(_:)), #selector(saveImageAs(_:)), #selector(saveImageAsWithoutDialog(_:)), #selector(saveAndClose(_:)):
            !editor.isSaving
        case #selector(pinToScreen(_:)):
            !editor.isApplying
        case #selector(revertToOriginal(_:)):
            editor.document.canRevertToOriginal && window?.attachedSheet == nil
        // The Resize sheet is modal to the editor: nothing may change the canvas under it, or its sizes go stale. Opening
        // the Background panel may add a background, which changes the frame the sheet started from.
        case #selector(cropAndResize(_:)), #selector(rotateImageLeft(_:)), #selector(rotateImageRight(_:)),
             #selector(flipImageHorizontally(_:)), #selector(flipImageVertically(_:)), #selector(resizeImage(_:)),
             #selector(toggleBackgroundTool(_:)):
            window?.attachedSheet == nil
        // Images stay out of Crop & Resize, and out from under the Resize sheet.
        case #selector(takeScreenshot(_:)), #selector(pasteImageFromClipboard(_:)), #selector(chooseImage(_:)):
            editor.crop == nil && window?.attachedSheet == nil
        // One scan at a time, nothing to look for with every kind switched off, and nothing under the Resize sheet. (The tool
        // strip's button is off for the first two, and a sheet blocks its window's clicks.)
        case #selector(maskSensitiveInfo(_:)):
            sensitiveCheck.isEnabled && window?.attachedSheet == nil
        default:
            true
        }
    }

    /// Unapplied edits are kept, discarded, or the close is cancelled.
    func askAboutChanges() -> ChangesChoice {
        let alert = NSAlert()
        switch editor.source {
        case .history:
            alert.messageText = "Keep your changes to “\(editor.title)”?"
            alert.informativeText = "They haven't been applied to the screenshot yet."
            alert.addButton(withTitle: "Keep")
        case .project:
            alert.messageText = "Save changes to “\(editor.title)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
        }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return switch alert.runModal() {
        case .alertFirstButtonReturn: .keep
        case .alertSecondButtonReturn: .discard
        default: .cancel
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Done is writing: closing now would let the write apply edits the person just chose to discard.
        guard !editor.isApplying else { return false }
        // Text being typed and a pending crop are part of the edits: finish them, so they are kept or discarded with the rest.
        canvas.canvas?.finishEditing()
        guard editor.hasUnappliedChanges else { return true }
        switch askAboutChanges() {
        case .keep:
            done()
            return false
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    /// The Edit menu's mask item keeps the title an editor last gave it, which with no editor answering (a History or Settings
    /// window in front, or the last editor closed) would say "Unmask" on a disabled item: it goes back to its own. An editor
    /// that becomes key again sets it when the menu opens (`validateMenuItem`). Called when an editor window resigns key and when
    /// it closes.
    private static func resetMaskMenuTitle() {
        func visit(_ menu: NSMenu) {
            for item in menu.items {
                if item.action == #selector(maskSensitiveInfo(_:)) { item.title = SensitiveButtonText.menuTitleWithNoEditor }
                if let submenu = item.submenu { visit(submenu) }
            }
        }
        if let main = NSApp.mainMenu { visit(main) }
    }

    func windowDidResignKey(_ notification: Notification) {
        canvas.canvas?.endSpaceHold()
        // Another window is key now: if it is no editor the item is disabled, and mustn't read "Unmask".
        Self.resetMaskMenuTitle()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor.undoManager
    }

    /// Every editor's close writes whether its panel was open, so the last one closed decides what the next one opens
    /// with.
    func windowWillClose(_ notification: Notification) {
        isClosed = true
        // Any scan for the button is cancelled, and a result that arrives later does nothing.
        sensitiveCheck.stop()
        Self.resetMaskMenuTitle()
        maskScan?.cancel()
        maskScan = nil
        // The scan stops at its next check; the message that says it is working goes now.
        if let progress = maskProgress { manager.hud.hide(progress) }
        maskProgress = nil
        manager.preferences[Prefs.annotateBackgroundToolWasOpen] = editor.isBackgroundPanelOpen
        onClose(self)
    }
}
