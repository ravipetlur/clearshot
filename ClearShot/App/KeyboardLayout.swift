import Carbon.HIToolbox
import CSCore

/// What a key is called on the keyboard layout in use: the character `UCKeyTranslate` gives its key code. A shortcut's
/// text (`⇧⌘4`) and its menu key equivalent both take their key from here.
enum KeyboardLayout {
    /// The character the current ASCII-capable layout gives the key `keyCode` pressed alone, with dead keys giving their
    /// own character; nil on any failure (no such key, no layout data, a key that types nothing). When the layout in use
    /// can't type Latin letters (Russian, say), it is the ASCII-capable one used last, so a shortcut keeps a Latin name.
    /// Read on every call, so a change of layout shows at once. Main thread only: the input source calls require it.
    static func character(for keyCode: Int) -> String? {
        guard let code = UInt16(exactly: keyCode),
              let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        let capacity = 4
        var characters = [UniChar](repeating: 0, count: capacity)
        var length = 0
        var deadKeyState: UInt32 = 0
        // The layout bytes belong to the input source; keep both alive until the translation is done.
        let status = withExtendedLifetime((source, layoutData)) {
            CFDataGetBytePtr(layoutData).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
                UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, capacity, &length, &characters)
            }
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

extension ShortcutText {
    /// `shortcut` as text on the keyboard layout in use, such as `⇧⌘4`.
    static func string(for shortcut: ShortcutSpec) -> String {
        string(for: shortcut) { KeyboardLayout.character(for: $0) }
    }
}
