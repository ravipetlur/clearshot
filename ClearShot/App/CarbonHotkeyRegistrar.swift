import Carbon.HIToolbox
import CSCore

/// The system side of global shortcuts: Carbon hot keys, which a menu bar app can register without any permission.
/// `HotkeyRegistry` decides what is registered; this registers it.
///
/// One handler for hot-key presses is installed on the application event target, and every hot key is registered to that
/// same target, so a press goes straight to the handler. All of it runs on the main thread, where Carbon delivers them.
final class CarbonHotkeyRegistrar: HotkeyRegistrar {
    /// What the C callback reaches through its `userData` pointer: the Swift side of the press handler.
    fileprivate final class PressBox {
        var onPress: (@MainActor (UInt32) -> Void)?
    }

    private let box = PressBox()
    private var handler: EventHandlerRef?
    /// The hot keys registered now, by the ID `HotkeyRegistry` gave them.
    private var hotKeys: [UInt32: EventHotKeyRef] = [:]

    isolated deinit {
        for reference in hotKeys.values { UnregisterEventHotKey(reference) }
        if let handler { RemoveEventHandler(handler) }
    }

    func installPressHandler(_ onPress: @escaping @MainActor (UInt32) -> Void) {
        box.onPress = onPress
        guard handler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        // The box is held by this object, which removes the handler before it goes, so the unretained pointer stays valid.
        let userData = Unmanaged.passUnretained(box).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &eventType, userData, &handler)
        if status != noErr {
            Log.hotkeys.error("Couldn't install the hot-key handler: status \(status)")
        }
    }

    func register(id: UInt32, shortcut: ShortcutSpec) -> HotkeyRegistrationResult {
        guard let keyCode = UInt32(exactly: shortcut.carbonKeyCode),
              let modifiers = UInt32(exactly: shortcut.carbonModifiers) else {
            return .failed(OSStatus(paramErr))
        }
        unregister(id: id)
        var reference: EventHotKeyRef?
        // Options 0 (non-exclusive), as v1.0.0 registered: macOS refuses only same-process duplicates, or registrations
        // exclusive on both sides, so another app holding the same keys is not detected. That is deliberate parity.
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: hotKeySignature, id: id),
                                         GetApplicationEventTarget(), 0, &reference)
        if status == OSStatus(eventHotKeyExistsErr) { return .refused }
        guard status == noErr else { return .failed(status) }
        // Carbon sets the reference whenever it reports success. Without one the hot key could not be released later, so
        // that counts as a failure.
        guard let hotKey = reference else {
            assertionFailure("RegisterEventHotKey succeeded without a hot key reference")
            return .failed(OSStatus(paramErr))
        }
        hotKeys[id] = hotKey
        return .registered
    }

    func unregister(id: UInt32) {
        guard let reference = hotKeys.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(reference)
    }
}

/// The signature `CSht` that every hot key of ClearShot's is registered with; a press with another is not ours.
private nonisolated let hotKeySignature: OSType = "CSht".utf8.reduce(0) { $0 << 8 | OSType($1) }

/// Carbon's callback for a hot-key press. It is a C function and holds no state; `userData` is the registrar's `PressBox`.
///
/// Carbon delivers application-target events on the main thread, so `MainActor.assumeIsolated` (which traps if it were
/// wrong) is sound. The box is still alive: the registrar removes this handler before it lets go of the box.
private nonisolated func hotKeyPressed(_ call: EventHandlerCallRef?, _ event: EventRef?,
                                       _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == hotKeySignature else { return OSStatus(eventNotHandledErr) }
    let id = hotKeyID.id
    let box = Unmanaged<CarbonHotkeyRegistrar.PressBox>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { box.onPress?(id) }
    return noErr
}
