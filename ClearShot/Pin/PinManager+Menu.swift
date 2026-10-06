import AppKit
import CSCore

/// A pin's right-click menu: closing and locking, the capture's actions, then this pin's zoom, opacity and style. The
/// keys it shows are handled by the panel itself (`PinPanel.performKeyEquivalent`).
extension PinManager {
    func menu(for controller: PinController) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, key: String = "", _ handler: @escaping () -> Void) {
            menu.addItem(.action(title, key: key, handler: handler))
        }

        add("Close", key: "w") { [weak self] in self?.perform(.close, on: controller) }
        add("Close All") { [weak self] in self?.closeAll() }
        // A locked pin lets right-clicks through, so neither is ever shown checked; its badge unlocks it.
        add("Lock") { [weak self] in self?.lock(controller, hidingOnHover: false) }
        add("Lock and Hide Screenshot on Mouse Over") { [weak self] in self?.lock(controller, hidingOnHover: true) }

        menu.addItem(.separator())
        add("Open Annotation Tool…", key: "e") { [weak self] in self?.perform(.annotate, on: controller) }
        add("Copy to Clipboard", key: "c") { [weak self] in self?.perform(.copy, on: controller) }
        add("Save As…", key: "s") { [weak self] in self?.perform(.saveAs, on: controller) }
        add("Extract Text") { [weak self] in self?.extractText(from: controller) }

        menu.addItem(.separator())
        let ceiling = PinGeometry.maximumZoom(imagePoints: controller.imagePoints)
        menu.addItem(presetsItem("Zoom", presets: PinGeometry.zoomPresets, current: controller.zoom,
                                 isReachable: { $0 <= ceiling }) { controller.zoom(to: $0) })
        menu.addItem(presetsItem("Opacity", presets: PinGeometry.opacityPresets, current: controller.opacity) {
            controller.setOpacity($0, showsReadout: false)
        })
        // A transparent picture has no card to round or outline (`PinStyle.effective`).
        let opaque = !controller.item.isTransparent
        menu.addItem(styleItem("Shadow", \.shadow, of: controller, enabled: true))
        menu.addItem(styleItem("Rounded Corners", \.roundedCorners, of: controller, enabled: opaque))
        menu.addItem(styleItem("Border", \.border, of: controller, enabled: opaque))
        return menu
    }

    /// A submenu of percentages with the current one checked; presets `isReachable` turns down are disabled.
    private func presetsItem(_ title: String, presets: [Double], current: Double,
                             isReachable: (Double) -> Bool = { _ in true },
                             choose: @escaping (Double) -> Void) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for preset in presets {
            let entry = NSMenuItem.action("\(Int((preset * 100).rounded()))%") { choose(preset) }
            entry.state = PinGeometry.isCurrent(preset, current) ? .on : .off
            entry.isEnabled = isReachable(preset)
            submenu.addItem(entry)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = submenu
        return parent
    }

    /// One of this pin's style switches, checked while on. A disabled one shows unchecked.
    private func styleItem(_ title: String, _ setting: WritableKeyPath<PinStyle, Bool>, of controller: PinController,
                           enabled: Bool) -> NSMenuItem {
        let entry = NSMenuItem.action(title) { controller.style[keyPath: setting].toggle() }
        entry.state = enabled && controller.style[keyPath: setting] ? .on : .off
        entry.isEnabled = enabled
        return entry
    }
}
