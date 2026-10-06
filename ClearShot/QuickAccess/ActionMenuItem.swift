import AppKit

/// Runs a closure as a menu item's action. NSMenuItem's target is weak, so the item keeps this object alive through
/// `representedObject`. A plain NSMenuItem is used instead of a subclass because a subclass must override NSMenuItem's
/// nonisolated initializers, which `copy()` calls.
final class MenuActionTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func fire() {
        handler()
    }
}

extension NSMenuItem {
    /// A menu item that runs `handler` when chosen.
    static func action(_ title: String, symbol: String? = nil, key: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let target = MenuActionTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(MenuActionTarget.fire), keyEquivalent: key)
        item.target = target
        item.representedObject = target
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }
}
