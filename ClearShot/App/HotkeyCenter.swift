import CSCore

extension ShortcutStore {
    /// The one store of the app's shortcuts, in the app's own preferences: the hot keys, the status menu, Settings and
    /// the checks all read and write this one, which is how they hear of each other's changes.
    static let app = ShortcutStore(defaults: .standard)
}

/// The app's global hot keys: the `HotkeyRegistry` on the Carbon registrar, behind one place the coordinator, onboarding
/// and Settings reach.
final class HotkeyCenter {
    /// One for the app, since one process can register a hot key once: a second would be refused its own keys.
    static let shared = HotkeyCenter()

    private let registrar = CarbonHotkeyRegistrar()
    /// What a press runs; set by `start`.
    private var onAction: ((ClearShotAction) -> Void)?
    /// Made on first use, so that it can hand a press to `onAction` through `self`.
    private lazy var registry = HotkeyRegistry(registrar: registrar, store: .app) { [weak self] action in
        self?.onAction?(action)
    }

    private init() {}

    /// Registers every action's shortcut and runs `onAction` for its presses. The shortcuts have to be migrated before
    /// this (`LegacyShortcutMigration`), or an upgrade would register the defaults over the user's.
    func start(_ onAction: @escaping (ClearShotAction) -> Void) {
        self.onAction = onAction
        registry.start()
    }

    /// Stops every hot key until the matching `resume()`; the Settings recorder uses it to see the keys instead of the
    /// actions running. Pauses nest.
    func pause() { registry.pause() }
    func resume() { registry.resume() }

    /// The actions with a shortcut that has no hot key because macOS refused it or registering it failed.
    var unregisteredActions: [ClearShotAction] { registry.unregisteredActions }
}
