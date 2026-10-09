import Foundation

/// What registering one global hot key came to.
public enum HotkeyRegistrationResult: Equatable, Sendable {
    case registered
    /// The system refused the keys: `eventHotKeyExistsErr`.
    case refused
    /// Any other status, as the system's number.
    case failed(Int32)
}

/// The system's side of global hot keys, which `HotkeyRegistry` drives. The app's Carbon registrar is the real one; tests
/// use a fake, so the bookkeeping is tested without registering a hot key.
@MainActor
public protocol HotkeyRegistrar: AnyObject {
    /// Installs the handler for hot-key presses, once; `onPress` gets the ID a hot key was registered with.
    func installPressHandler(_ onPress: @escaping @MainActor (UInt32) -> Void)
    func register(id: UInt32, shortcut: ShortcutSpec) -> HotkeyRegistrationResult
    func unregister(id: UInt32)
}

/// Keeps one hot key registered for every action that has a shortcut in the `ShortcutStore`, and runs the action when its
/// key is pressed.
///
/// - **IDs:** an action's hot key has the ID `index in ClearShotAction.allCases + 1`, the same for the life of the process.
/// - **Changes:** after every `ShortcutStore.didChange`, the changed action's hot key (or every action's, after a reset of
///   all) is unregistered and registered again with the shortcut now stored, and so is every action that is refused or
///   failed, which may have been waiting for keys the change frees. Everything affected is unregistered before any is
///   registered again, so actions that swap shortcuts don't refuse each other.
/// - **Pausing:** `pause()` unregisters everything, for the Settings recorder to see the keys instead of the actions
///   running. Pauses nest by count; the last `resume()` registers everything from the store as it is then.
/// - **Results:** an action whose registration was refused or failed is listed in `unregisteredActions` until a later
///   registration succeeds or its shortcut is cleared. The list stands while paused, as it was when the keys were let
///   go, and the last `resume()` replaces it.
/// - **Log:** a refusal or failure is logged when it is new for the action: a different result, or the same result for a
///   different shortcut. Registering again with the same outcome (a resume, a retry) says nothing more.
@MainActor
public final class HotkeyRegistry {
    private let registrar: any HotkeyRegistrar
    private let store: ShortcutStore
    private let notificationCenter: NotificationCenter
    private let logger: AppLogger
    private let onAction: @MainActor (ClearShotAction) -> Void

    private var started = false
    private var pauseCount = 0
    private var observer: (any NSObjectProtocol)?
    /// The actions whose hot key the registrar holds.
    private var registered: Set<ClearShotAction> = []
    /// The last attempt to register each action; an action with no shortcut has none. A pause keeps them: only the next
    /// registration replaces an attempt, which is also what tells a new result from one already logged.
    private var attempts: [ClearShotAction: Attempt] = [:]

    /// One registration tried: the shortcut it was for, and how it came out.
    private struct Attempt: Equatable {
        let shortcut: ShortcutSpec
        let result: HotkeyRegistrationResult
    }

    /// `notificationCenter` is the one the store posts `didChange` to, and `logger` is where presses and failures go.
    public init(registrar: any HotkeyRegistrar, store: ShortcutStore, notificationCenter: NotificationCenter = .default,
                logger: AppLogger = Log.hotkeys, onAction: @escaping @MainActor (ClearShotAction) -> Void) {
        self.registrar = registrar
        self.store = store
        self.notificationCenter = notificationCenter
        self.logger = logger
        self.onAction = onAction
    }

    isolated deinit {
        if let observer { notificationCenter.removeObserver(observer) }
        unregisterAll()
    }

    /// Installs the press handler, registers every action with a shortcut, and follows the store from now on. A second
    /// call does nothing.
    public func start() {
        guard !started else { return }
        started = true
        registrar.installPressHandler { [weak self] id in self?.pressed(id) }
        // The store posts on whatever thread wrote; the registrar is used on the main one only.
        observer = notificationCenter.addObserver(forName: ShortcutStore.didChange, object: store,
                                                  queue: .main) { [weak self] note in
            let action = ShortcutStore.changedAction(in: note)
            MainActor.assumeIsolated { self?.storeDidChange(action: action) }
        }
        if pauseCount == 0 { apply(ClearShotAction.allCases) }
    }

    /// Unregisters every hot key until the matching `resume()`. Nothing is registered while paused, and a change in the
    /// store applies on the last `resume()`.
    public func pause() {
        pauseCount += 1
        if pauseCount == 1 { unregisterAll() }
    }

    /// Ends one `pause()`; the last one registers every action again. A `resume()` with no pause open does nothing.
    public func resume() {
        guard pauseCount > 0 else { return }
        pauseCount -= 1
        if pauseCount == 0, started { apply(ClearShotAction.allCases) }
    }

    /// Registers `action` again with the shortcut the store has now, or every action's when `action` is nil (everything
    /// changed), and tries again every action that is refused or failed: the change may have freed the keys it was
    /// refused for. The registry calls it on every store change; it is public so that tests can call it too. While
    /// paused, or before `start()`, nothing is registered and there is nothing to do.
    public func storeDidChange(action: ClearShotAction?) {
        guard started, pauseCount == 0 else { return }
        let changed = action.map { [$0] } ?? ClearShotAction.allCases
        let retried = unregisteredActions
        apply(ClearShotAction.allCases.filter { changed.contains($0) || retried.contains($0) })
    }

    /// The actions that have a shortcut but no hot key because registering it was refused or failed, in
    /// `ClearShotAction.allCases` order. While paused, the list as it was before the pause.
    public var unregisteredActions: [ClearShotAction] {
        ClearShotAction.allCases.filter { action in
            switch attempts[action]?.result {
            case .refused?, .failed?: true
            case .registered?, nil: false
            }
        }
    }

    // MARK: Private

    private static func id(for action: ClearShotAction) -> UInt32 {
        // `allCases` has every case, so the action is always found.
        UInt32(ClearShotAction.allCases.firstIndex(of: action)!) + 1
    }

    private static func action(forID id: UInt32) -> ClearShotAction? {
        let index = Int(id) - 1
        return ClearShotAction.allCases.indices.contains(index) ? ClearShotAction.allCases[index] : nil
    }

    /// Unregisters `actions`, then registers each again from the store. All the unregistering comes first: two actions
    /// that swap shortcuts would otherwise find the keys still held by the other.
    private func apply(_ actions: [ClearShotAction]) {
        for action in actions { unregister(action) }
        for action in actions { register(action) }
    }

    /// Lets go of the action's hot key. What the last attempt came out as stays, until the next registration.
    private func unregister(_ action: ClearShotAction) {
        if registered.remove(action) != nil {
            registrar.unregister(id: Self.id(for: action))
        }
    }

    private func unregisterAll() {
        for action in ClearShotAction.allCases { unregister(action) }
    }

    private func register(_ action: ClearShotAction) {
        guard let shortcut = store.shortcut(for: action) else {
            attempts[action] = nil
            return
        }
        let result = registrar.register(id: Self.id(for: action), shortcut: shortcut)
        let attempt = Attempt(shortcut: shortcut, result: result)
        let isNew = attempts[action] != attempt
        attempts[action] = attempt
        let keys = "key code \(shortcut.carbonKeyCode), modifiers \(shortcut.carbonModifiers)"
        switch result {
        case .registered:
            registered.insert(action)
        case .refused:
            if isNew { logger.warning("Couldn't register the shortcut of \(action.rawValue) (\(keys)): macOS refused it") }
        case .failed(let status):
            if isNew { logger.error("Couldn't register the shortcut of \(action.rawValue) (\(keys)): status \(status)") }
        }
    }

    /// A press arrives for a registered hot key; one for an ID that is not an action's, or for an action that has no hot
    /// key now (its shortcut was cleared or paused after the system queued the press), is dropped.
    private func pressed(_ id: UInt32) {
        guard let action = Self.action(forID: id), registered.contains(action) else { return }
        logger.info("Hotkey: \(action.rawValue)")
        onAction(action)
    }
}
