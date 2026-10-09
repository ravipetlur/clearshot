import AppKit
import CSCore
import CSRecording

/// The menu bar icon and its menu. The layout's items are made once, each action's with its shortcut, which then
/// follows the shortcut store by itself; every open puts them back, renames Hide/Show Desktop Icons, and adds Show Hidden
/// Overlays and Show Hidden Pins while there is something hidden. While a recording runs the icon is its Stop button
/// instead (`apply`).
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private unowned let coordinator: AppCoordinator
    private let menu = NSMenu()
    /// `StatusMenuLayout`'s items, in order. A menu item can be in one menu only; `removeAllItems` lets them go before
    /// they are added again.
    private var layoutItems: [NSMenuItem] = []
    /// The one item whose title changes: Hide or Show Desktop Icons.
    private var desktopIconsItem: NSMenuItem?
    /// Each action's item, to put its key equivalent right when the action's shortcut changes.
    private var actionItems: [ClearShotAction: NSMenuItem] = [:]
    /// "Show menu bar icon"; a recording shows the icon whatever it says.
    private var prefersVisible = true
    /// What `apply` last showed; at first the plain icon with its menu.
    private var presentation = RecordingStatusPresentation.make(phase: .none, elapsed: 0, showsTime: false,
                                                                conversionProgress: nil)
    /// The second item beside the icon, only while the presentation has one: Resume while paused, the GIF's progress
    /// while converting.
    private var secondaryItem: NSStatusItem?

    /// A click on the icon while it is the Stop button.
    var onStopClicked: (() -> Void)?
    /// A click on the second item's Resume.
    var onResumeClicked: (() -> Void)?
    /// A click on the second item while a GIF is being made.
    var onConversionClicked: (() -> Void)?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        statusItem.button?.image = Self.symbol(presentation.symbolName, description: "ClearShot")
        layoutItems = makeLayoutItems()
        menu.delegate = self
        statusItem.menu = menu
        // The notification center keeps the observer for good, so it captures the controller weakly.
        NotificationCenter.default.addObserver(forName: ShortcutStore.didChange, object: ShortcutStore.app,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeyEquivalents() }
        }
    }

    /// The "Show menu bar icon" setting. While a recording forces the icon visible it stays, and goes once the recording
    /// ends if the setting hides it.
    var isVisible: Bool {
        get { prefersVisible }
        set {
            prefersVisible = newValue
            statusItem.isVisible = newValue || presentation.forcesVisible
        }
    }

    /// Where the icon is on screen, for the one-time "Press to stop recording"; nil while it isn't shown.
    var buttonScreenFrame: CGRect? {
        guard statusItem.isVisible, let window = statusItem.button?.window else { return nil }
        return window.frame
    }

    /// Shows the icon as a recording's phase wants (`RecordingStatusPresentation`): its menu, or the Stop action without
    /// one; its symbol and the elapsed time beside it (monospaced digits); shown even with the icon hidden; and the
    /// second item. Applying the same presentation again does nothing, so the 1 Hz updates and every ending's reset
    /// are cheap.
    func apply(_ presentation: RecordingStatusPresentation) {
        guard presentation != self.presentation else { return }
        self.presentation = presentation
        statusItem.menu = presentation.usesMenu ? menu : nil
        if let button = statusItem.button {
            button.target = presentation.usesMenu ? nil : self
            button.action = presentation.usesMenu ? nil : #selector(stopClicked)
            button.image = Self.symbol(presentation.symbolName,
                                       description: presentation.usesMenu ? "ClearShot" : "Stop Recording")
            if let title = presentation.title {
                statusItem.length = NSStatusItem.variableLength
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                button.title = title
            } else {
                statusItem.length = NSStatusItem.squareLength
                button.imagePosition = .imageOnly
                button.title = ""
            }
        }
        statusItem.isVisible = prefersVisible || presentation.forcesVisible
        applySecondary(presentation.secondary)
    }

    private func applySecondary(_ secondary: RecordingStatusPresentation.Secondary?) {
        guard let secondary else {
            if let secondaryItem { NSStatusBar.system.removeStatusItem(secondaryItem) }
            secondaryItem = nil
            return
        }
        let item = secondaryItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        secondaryItem = item
        guard let button = item.button else { return }
        button.target = self
        button.imagePosition = .imageLeading
        switch secondary {
        case .resume:
            button.image = Self.symbol("play.fill", description: "Resume Recording")
            button.font = nil
            button.title = "Resume"
            button.toolTip = nil
            button.action = #selector(resumeClicked)
        case .converting(let progress):
            button.image = Self.symbol("photo.stack", description: "Creating GIF")
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.title = "Creating GIF… \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
            // A click asks whether to stop: Continue, Save as a Video or Delete.
            button.toolTip = "Stop creating the GIF"
            button.action = #selector(conversionClicked)
        }
    }

    private static func symbol(_ name: String, description: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        image?.isTemplate = true
        return image
    }

    @objc private func stopClicked() { onStopClicked?() }
    @objc private func resumeClicked() { onResumeClicked?() }
    @objc private func conversionClicked() { onConversionClicked?() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // The keys follow the keyboard layout in use now, which a switch since the last change of a shortcut may have
        // altered.
        refreshKeyEquivalents()
        menu.removeAllItems()
        // Only while thumbnails or pins are hidden, so there is a visible way back to them besides the hotkeys.
        let hiddenOverlays = coordinator.quickAccess.hasHiddenOverlays
        let hiddenPins = coordinator.pins.hasHiddenPins
        if hiddenOverlays {
            let show = NSMenuItem(title: "Show Hidden Overlays", action: #selector(showHiddenOverlays), keyEquivalent: "")
            show.target = self
            show.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
            menu.addItem(show)
        }
        if hiddenPins {
            let show = NSMenuItem(title: "Show Hidden Pins", action: #selector(showHiddenPins), keyEquivalent: "")
            show.target = self
            show.image = NSImage(systemSymbolName: "pin", accessibilityDescription: nil)
            menu.addItem(show)
        }
        if hiddenOverlays || hiddenPins { menu.addItem(.separator()) }
        desktopIconsItem?.title = ClearShotAction.toggleDesktopIcons
            .menuTitle(desktopIconsHidden: coordinator.desktopIcons.isHidden)
        layoutItems.forEach(menu.addItem)
    }

    /// `StatusMenuLayout`'s items, made once.
    private func makeLayoutItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        for entry in StatusMenuLayout.entries {
            switch entry {
            case .action(let action):
                let item = item(for: action)
                if action == .toggleDesktopIcons { desktopIconsItem = item }
                items.append(item)
            case .separator:
                items.append(.separator())
            case .settings:
                #if DEBUG
                let selfTest = NSMenuItem(title: "Run Capture Self-Test", action: #selector(runSelfTest), keyEquivalent: "")
                selfTest.target = self
                items.append(selfTest)
                #endif
                let item = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
                item.target = self
                items.append(item)
            case .about:
                let item = NSMenuItem(title: "About ClearShot", action: #selector(openAbout), keyEquivalent: "")
                item.target = self
                items.append(item)
            case .quit:
                items.append(NSMenuItem(title: "Quit ClearShot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            }
        }
        return items
    }

    /// An action's item, showing the action's shortcut as its key equivalent; `refreshKeyEquivalents` keeps that in step.
    private func item(for action: ClearShotAction) -> NSMenuItem {
        let title = action.menuTitle(desktopIconsHidden: coordinator.desktopIcons.isHidden)
        let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = action.rawValue
        item.image = NSImage(systemSymbolName: action.symbolName, accessibilityDescription: nil)
        actionItems[action] = item
        applyKeyEquivalent(to: item, for: action)
        return item
    }

    /// Every action's key equivalent from the shortcut store now: after any change there, whichever action it was.
    private func refreshKeyEquivalents() {
        for (action, item) in actionItems {
            applyKeyEquivalent(to: item, for: action)
        }
    }

    /// `item`'s key equivalent and modifiers from `action`'s shortcut; none when it has no shortcut, or one that a menu
    /// can't show (a keypad key).
    private func applyKeyEquivalent(to item: NSMenuItem, for action: ClearShotAction) {
        guard let shortcut = ShortcutStore.app.shortcut(for: action),
              let equivalent = MenuKeyEquivalent.make(for: shortcut, character: { KeyboardLayout.character(for: $0) }) else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = equivalent.key
        item.keyEquivalentModifierMask = NSEvent.ModifierFlags(
            rawValue: CarbonModifiers.eventFlags(from: equivalent.carbonModifiers))
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = ClearShotAction(rawValue: raw) else { return }
        coordinator.perform(action)
    }

    @objc private func showHiddenOverlays() { coordinator.quickAccess.toggleVisibility() }
    @objc private func showHiddenPins() { coordinator.pins.toggleVisibility() }
    @objc private func openSettings() { coordinator.showSettings() }
    @objc private func openAbout() { coordinator.showAbout() }

    #if DEBUG
    @objc private func runSelfTest() { coordinator.runCaptureSelfTest() }
    #endif
}
