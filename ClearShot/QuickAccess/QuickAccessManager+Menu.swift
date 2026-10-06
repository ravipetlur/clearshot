import AppKit
import CSCapture
import CSCore
import CSHistory

/// The thumbnail's right-click menu and the image and audio changes it offers.
extension QuickAccessManager {
    /// A video or GIF has no image to print, annotate, pin, change, read or send: those items are left out. It opens in
    /// the Video Editor instead, a video with audio can lose it (Mute Audio…), and a GIF ClearShot recorded can be
    /// trimmed; a GIF opened from a file has neither the editor nor the trim.
    func menu(for controller: QuickAccessItemController) -> NSMenu {
        let item = controller.item
        let isScreenshot = item.kind == .screenshot
        let fileURL = actions.file(for: item)
        let menu = NSMenu()
        menu.autoenablesItems = false
        // A thumbnail with a save or image change running ignores commands that would race it, so those items are off.
        let idle = !controller.isBusy
        func add(_ title: String, key: String = "", enabled: Bool = true, _ handler: @escaping () -> Void) {
            let entry = NSMenuItem.action(title, key: key, handler: handler)
            entry.isEnabled = enabled
            menu.addItem(entry)
        }

        add("Copy", key: "c", enabled: idle) { [weak self] in self?.perform(.copy, on: controller, optionHeld: false) }
        add("Save", key: "s", enabled: idle && !controller.isSaved) { [weak self] in
            self?.perform(.save, on: controller, optionHeld: false)
        }
        // Always asks, whatever the "Save button" setting makes Save do.
        add("Save As…", enabled: idle) { [weak self] in self?.saveAndClose(controller, askingWhere: true) }
        menu.addItem(NSSharingServicePicker(items: [fileURL]).standardShareMenuItem)
        menu.addItem(openWithItem(for: actions.openWithFile(for: item)))
        add("Show in Finder") { [weak self] in self?.actions.showInFinder(item) }
        add("Open in Mail…") { [weak self] in self?.actions.mail(item) }
        if isScreenshot {
            add("Print…") { [weak self] in
                guard let self, gate.allowsQuestion() else { return }
                // The print dialog is modal; the countdown waits for it.
                hold(controller)
                actions.printImage(item)
                release(controller)
            }
        }
        add("Quick Look", enabled: idle) { [weak self] in self?.perform(.quickLook, on: controller, optionHeld: false) }

        if isScreenshot {
            menu.addItem(.separator())
            add("Open Annotation Tool…", key: "e", enabled: idle) { [weak self] in
                self?.perform(.annotate, on: controller, optionHeld: false)
            }
            add("Pin to the Screen", enabled: idle) { [weak self] in self?.perform(.pin, on: controller, optionHeld: false) }
            add("Rotate Left", enabled: idle) { [weak self] in self?.transform(controller, .rotateLeft) }
            add("Flip Horizontal", enabled: idle) { [weak self] in self?.transform(controller, .flipHorizontal) }
            if item.scale > 1 {
                add("Scale Retina to 1x", enabled: idle) { [weak self] in self?.transform(controller, .scaleTo1x) }
            }
            add("Resize…", enabled: idle) { [weak self] in self?.showResize(for: controller) }
            // Recognition only reads the working copy, so it leaves the thumbnail's busy flag alone; the history hold
            // that Extract Text takes keeps the capture if the thumbnail closes meanwhile.
            add("Extract Text") { [weak self] in Task { await self?.actions.extractText(item) } }
            add("Send to Raycast AI Chat…") { [weak self] in
                guard let self else { return }
                guard let png = try? Data(contentsOf: actions.workingCopy(for: item)) else {
                    hud.show("Couldn't read the screenshot", symbol: "exclamationmark.triangle.fill")
                    return
                }
                RaycastBridge.send(pngData: png, hud: hud)
            }
        } else {
            // A GIF opened from a file has no source video, so there is nothing for the editor or Trim the GIF… to trim.
            let opensInEditor = item.opensInVideoEditor(root: history.root)
            let mutes = item.kind == .video && item.hasAudio == true
            if opensInEditor || mutes { menu.addItem(.separator()) }
            if opensInEditor {
                add("Open Video Editor…", key: "e", enabled: idle) { [weak self] in
                    self?.perform(.annotate, on: controller, optionHeld: false)
                }
            }
            if mutes {
                add("Mute Audio…", enabled: idle) { [weak self] in self?.muteAudio(controller) }
            }
            if opensInEditor, item.kind == .gif {
                add("Trim the GIF…", enabled: idle) { [weak self] in self?.perform(.trim, on: controller, optionHeld: false) }
            }
        }

        menu.addItem(.separator())
        add("Close All…") { [weak self] in self?.closeAll() }
        add("Save All…") { [weak self] in Task { await self?.saveAll() } }
        add("Temporarily Hide") { [weak self] in self?.setHidden(true) }
        add(controller.isSaved ? "Move to Trash" : "Delete", enabled: idle) { [weak self] in
            self?.perform(.trash, on: controller, optionHeld: false)
        }
        return menu
    }

    /// A capture open in Annotate keeps its changes in the editor's document, which was made before any rotation or
    /// resize done here and would overwrite it on Done. Trash and Discard would remove the capture from under the
    /// editor, and a Done writing at the time would bring it back. So all of these wait until the editor closes, as
    /// History's Delete does; so does Mute Audio… while the Video Editor has the video open. True, after saying so,
    /// when the capture is being annotated or edited.
    func refuseWhileAnnotating(_ controller: QuickAccessItemController) -> Bool {
        guard isEditing(controller.item.id) else { return false }
        if controller.item.kind == .screenshot {
            hud.show("Finish annotating this screenshot first", symbol: "pencil.tip.crop.circle")
        } else {
            hud.show("Finish editing this video first", symbol: "film")
        }
        return true
    }

    /// Mute Audio…: asks first, since it can't be undone, then removes the audio track from the working copy (and the
    /// saved file when ClearShot wrote it and it hasn't changed since). The thumbnail is busy meanwhile, so nothing
    /// else races it and the Video Editor won't open it; the store's `.updated` refreshes it. The question is refused
    /// while a capture or recording is under way (`ModalGate`).
    func muteAudio(_ controller: QuickAccessItemController) {
        guard !refuseWhileAnnotating(controller), !controller.isBusy, gate.allowsQuestion() else { return }
        // The alert is modal; the countdown waits for it.
        hold(controller)
        let alert = NSAlert()
        alert.messageText = "Are you sure you want to remove the audio track?"
        alert.informativeText = "You can't undo this action."
        alert.addButton(withTitle: "Remove the Audio").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        release(controller)
        // The editor may have opened the video, or a save started, while the alert was up.
        guard confirmed, !refuseWhileAnnotating(controller), !controller.isBusy else { return }
        controller.isBusy = true
        Task {
            defer { controller.isBusy = false }
            guard let updated = await actions.muteAudio(controller.item) else { return }
            if controller.item != updated { refresh(updated) }
        }
    }

    /// Applies an image change. The store's `.updated` refreshes the thumbnail and re-stacks, since its shape may have
    /// changed; if the change couldn't be recorded in the store, the thumbnail is refreshed here instead.
    func transform(_ controller: QuickAccessItemController, _ change: ImageTransform) {
        guard !refuseWhileAnnotating(controller) else { return }
        guard !controller.isBusy else { return }
        controller.isBusy = true
        Task {
            defer { controller.isBusy = false }
            guard let updated = await actions.transform(controller.item, change) else { return }
            if controller.item != updated { refresh(updated) }
        }
    }

    /// The dialog isn't modal, so the thumbnail's countdown waits for it; otherwise the thumbnail could close while the
    /// person is typing. It takes focus, so it is refused while a capture or recording is under way (`ModalGate`).
    func showResize(for controller: QuickAccessItemController) {
        guard !refuseWhileAnnotating(controller), gate.allowsQuestion() else { return }
        ResizeWindowController.present(
            pixelSize: controller.item.pixelSize,
            onResize: { [weak self, weak controller] width, height in
                guard let self else { return }
                guard let controller else {
                    hud.show("That thumbnail was closed", symbol: "exclamationmark.triangle.fill")
                    return
                }
                transform(controller, .resize(width: width, height: height))
            },
            onClose: { [weak self, weak controller] in
                guard let self, let controller else { return }
                release(controller)
            })
        // After presenting, which closes an earlier dialog and releases its hold first.
        hold(controller)
    }

    /// "Open With" and the apps that can open the file, the default one marked. ClearShot opens images too (Finder's
    /// Open With), but offering itself on its own thumbnail would only import the image again.
    private func openWithItem(for url: URL) -> NSMenuItem {
        let parent = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: url).filter {
            Bundle(url: $0)?.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        for app in apps.prefix(20) {
            let name = FileManager.default.displayName(atPath: app.path(percentEncoded: false))
            let entry = NSMenuItem.action(app == defaultApp ? "\(name) (default)" : name) {
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
            let icon = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            submenu.addItem(entry)
        }
        if apps.isEmpty {
            let none = NSMenuItem(title: "No apps", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
        }
        parent.submenu = submenu
        return parent
    }
}
