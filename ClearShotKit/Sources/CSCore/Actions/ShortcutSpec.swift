/// A keyboard shortcut in Carbon terms (virtual key code and Carbon modifier mask).
public struct ShortcutSpec: Sendable, Equatable, Hashable {
    public static let command = 256
    public static let shift = 512
    public static let option = 2048
    public static let control = 4096

    public let carbonKeyCode: Int
    public let carbonModifiers: Int

    public init(carbonKeyCode: Int, carbonModifiers: Int) {
        self.carbonKeyCode = carbonKeyCode
        self.carbonModifiers = carbonModifiers
    }

    public static func commandShift(_ keyCode: Int) -> ShortcutSpec {
        ShortcutSpec(carbonKeyCode: keyCode, carbonModifiers: command | shift)
    }
}

/// Carbon virtual key codes (kVK_ANSI_*) used by default shortcuts.
public enum KeyCode {
    public static let digit2 = 19
    public static let digit3 = 20
    public static let digit4 = 21
    public static let digit5 = 23
    public static let digit6 = 22
}
