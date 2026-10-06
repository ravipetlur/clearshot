import AppKit

/// The app's main menu. ClearShot usually has no Dock icon, but its windows still need standard key equivalents
/// (⌘C/⌘V in text fields, ⌘W, ⌘Q). Actions with a nil target go through the responder chain: the app's to the app
/// delegate, the editor's (File, View, Duplicate, Crop & Resize, Background Tool, Add Image) to the key editor's window controller and canvas. With no editor open,
/// nothing answers those, so they are disabled.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About ClearShot", action: #selector(AppDelegate.showAboutAction(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Settings…", action: #selector(AppDelegate.showSettingsAction(_:)), keyEquivalent: ","))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ClearShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenuItem(appMenu))

        main.addItem(submenuItem(fileMenu()))

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenu.addItem(NSMenuItem(title: "Duplicate", action: #selector(AnnotationCanvasView.duplicate(_:)), keyEquivalent: "d"))
        // No shortcut: the canvas's own Delete key deletes the selection.
        editMenu.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        // Crop & Resize. Rotate and Resize Image… take ⌥⌘ shortcuts (⌘R alone is Send to Raycast AI Chat). Crop &
        // Resize and Background Tool (checked while the panel is open) have their letters instead, since a plain letter
        // would catch typing; Flip and Revert to Original have none.
        editMenu.addItem(.separator())
        editMenu.addItem(item("Crop & Resize", #selector(EditorWindowController.cropAndResize(_:)), ""))
        editMenu.addItem(item("Background Tool", #selector(EditorWindowController.toggleBackgroundTool(_:)), ""))
        editMenu.addItem(item("Rotate Left", #selector(EditorWindowController.rotateImageLeft(_:)), "l", [.command, .option]))
        editMenu.addItem(item("Rotate Right", #selector(EditorWindowController.rotateImageRight(_:)), "r", [.command, .option]))
        editMenu.addItem(item("Flip Horizontal", #selector(EditorWindowController.flipImageHorizontally(_:)), ""))
        editMenu.addItem(item("Flip Vertical", #selector(EditorWindowController.flipImageVertically(_:)), ""))
        editMenu.addItem(item("Resize Image…", #selector(EditorWindowController.resizeImage(_:)), "i", [.command, .option]))
        editMenu.addItem(item("Revert to Original", #selector(EditorWindowController.revertToOriginal(_:)), ""))
        // Add Image, the tool strip's menu. No key equivalents: ⌘V already pastes an image.
        let addImageMenu = NSMenu(title: "Add Image")
        addImageMenu.addItem(item("Take Screenshot…", #selector(EditorWindowController.takeScreenshot(_:)), ""))
        addImageMenu.addItem(item("Paste Image from Clipboard", #selector(EditorWindowController.pasteImageFromClipboard(_:)), ""))
        addImageMenu.addItem(item("Choose Image…", #selector(EditorWindowController.chooseImage(_:)), ""))
        let addImageItem = NSMenuItem(title: "Add Image", action: nil, keyEquivalent: "")
        addImageItem.submenu = addImageMenu
        editMenu.addItem(.separator())
        editMenu.addItem(addImageItem)
        main.addItem(submenuItem(editMenu))

        main.addItem(submenuItem(viewMenu()))

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        main.addItem(submenuItem(windowMenu))
        NSApp.windowsMenu = windowMenu

        return main
    }

    /// The editor's outputs, and Close.
    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("Save", #selector(EditorWindowController.saveImage(_:)), "s"))
        menu.addItem(item("Save As…", #selector(EditorWindowController.saveImageAs(_:)), "s", [.command, .shift]))
        // Shown in place of Save As… while ⌥ is held.
        let withoutDialog = item("Save As Without Dialog", #selector(EditorWindowController.saveImageAsWithoutDialog(_:)), "s",
                                 [.command, .shift, .option])
        withoutDialog.isAlternate = true
        menu.addItem(withoutDialog)
        menu.addItem(item("Save and Close", #selector(EditorWindowController.saveAndClose(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Copy Image", #selector(EditorWindowController.copyImage(_:)), "c", [.command, .shift]))
        menu.addItem(item("Send to Raycast AI Chat", #selector(EditorWindowController.sendToRaycast(_:)), "r"))
        // No key equivalent (D-P10): one can be assigned in System Settings › Keyboard › App Shortcuts.
        menu.addItem(item("Pin to the Screen", #selector(EditorWindowController.pinToScreen(_:)), ""))
        menu.addItem(.separator())
        menu.addItem(item("Print…", #selector(EditorWindowController.printImage(_:)), "p"))
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    /// The editor's zoom.
    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "+"))
        // ⌘= too, so Zoom In needs no Shift on a US keyboard.
        let zoomInWithoutShift = item("Zoom In", #selector(EditorWindowController.zoomIn(_:)), "=")
        zoomInWithoutShift.isHidden = true
        zoomInWithoutShift.allowsKeyEquivalentWhenHidden = true
        menu.addItem(zoomInWithoutShift)
        menu.addItem(item("Zoom Out", #selector(EditorWindowController.zoomOut(_:)), "-"))
        menu.addItem(item("Actual Size", #selector(EditorWindowController.zoomToActualSize(_:)), "0"))
        menu.addItem(item("Zoom to Fit", #selector(EditorWindowController.zoomToFit(_:)), "9"))
        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String,
                             _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func submenuItem(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem()
        item.submenu = menu
        return item
    }
}
