public enum StatusMenuEntry: Sendable, Equatable {
    case action(ClearShotAction)
    case separator
    case settings
    case about
    case quit
}

/// The menu bar menu, top to bottom.
public enum StatusMenuLayout {
    public static let entries: [StatusMenuEntry] = [
        .action(.allInOne),
        .action(.captureArea),
        .action(.capturePreviousArea),
        .action(.captureFullscreen),
        .action(.captureWindow),
        .action(.selfTimer),
        .action(.scrollingCapture),
        .action(.captureText),
        .action(.recordScreen),
        .separator,
        .action(.openFile),
        .action(.openFromClipboard),
        .action(.chooseAndPinImage),
        .action(.openCaptureHistory),
        .action(.restoreLastCapture),
        .separator,
        .action(.toggleDesktopIcons),
        .separator,
        .settings,
        .about,
        .quit,
    ]
}
