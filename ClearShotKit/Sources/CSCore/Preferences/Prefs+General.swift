import Foundation

/// What happens right after a capture. Pin applies to screenshots only.
public enum AfterCaptureAction: String, CaseIterable, Sendable, Identifiable, StringPrefEnum {
    case showQuickAccess, copy, save, openEditor, pin

    public var id: String { rawValue }

    public var rowTitle: String {
        switch self {
        case .showQuickAccess: "Show Quick Access Overlay"
        case .copy: "Copy file to clipboard"
        case .save: "Save"
        case .openEditor: "Open Annotate / Video Editor"
        case .pin: "Pin to the screen"
        }
    }

    public var appliesToRecordings: Bool { self != .pin }

    /// The set after switching `action` on or off, or nil if that would leave no action enabled.
    public static func toggling(_ action: AfterCaptureAction, in set: Set<AfterCaptureAction>, on: Bool) -> Set<AfterCaptureAction>? {
        var result = set
        if on {
            result.insert(action)
        } else {
            result.remove(action)
        }
        return result.isEmpty ? nil : result
    }
}

/// What "copy to clipboard" puts on the pasteboard.
public enum ClipboardMode: String, CaseIterable, Sendable, Identifiable, PrefValue {
    case fileAndImage, imageOnly, fileOnly

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fileAndImage: "File & Image (default)"
        case .imageOnly: "Image only"
        case .fileOnly: "File only"
        }
    }
}

public extension Prefs {
    /// The Info.plist key a build sets the default save folder with, from `CLEARSHOT_DEFAULT_SAVE_FOLDER` in
    /// Config/Defaults.xcconfig (Desktop) or Config/Local.xcconfig.
    static let defaultSaveFolderInfoKey = "ClearShotDefaultSaveFolder"

    static var defaultExportLocation: URL {
        defaultExportLocation(folder: Bundle.main.object(forInfoDictionaryKey: defaultSaveFolderInfoKey) as? String)
    }

    /// The default save folder: `folder`, a path relative to the home folder, or Desktop when it's missing, empty,
    /// absolute or climbs out of the home folder.
    static func defaultExportLocation(folder: String?,
                                      home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let trimmed = (folder ?? "").trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
        let components = trimmed.split(separator: "/")
        let usable = !trimmed.isEmpty && !(folder ?? "").hasPrefix("/") && !(folder ?? "").hasPrefix("~")
            && !components.contains("..") && !components.contains(".")
        return home.appending(path: (usable ? trimmed : "Desktop") + "/", directoryHint: .isDirectory)
    }

    // General
    static let showMenuBarIcon = PrefKey("showMenuBarIcon", default: true)
    static let didInformAboutHiddenMenuBarIcon = PrefKey("didInformAboutHiddenMenuBarIcon", default: false)
    static let hideDesktopIconsWhileCapturing = PrefKey("hideDesktopIconsWhileCapturing", default: true)
    static let playSounds = PrefKey("playSounds", default: false)
    static let exportLocation = PrefKey("exportLocation", default: Prefs.defaultExportLocation)
    static let afterScreenshotActions = PrefKey("afterScreenshotActions", default: Set<AfterCaptureAction>([.showQuickAccess, .copy, .save]))
    static let afterRecordingActions = PrefKey("afterRecordingActions", default: Set<AfterCaptureAction>([.showQuickAccess, .copy, .save]))

    // File naming and clipboard (Advanced pane)
    static let fileNameTemplate = PrefKey("fileNameTemplate", default: FileNameTemplate.standard)
    static let fileNameUseUTC = PrefKey("fileNameUseUTC", default: false)
    static let fileNameRemoveIllegalCharacters = PrefKey("fileNameRemoveIllegalCharacters", default: true)
    static let fileNameNextAutoIncrement = PrefKey("fileNameNextAutoIncrement", default: 1)
    static let askForNameAfterCapture = PrefKey("askForNameAfterCapture", default: false)
    static let addRetinaSuffix = PrefKey("addRetinaSuffix", default: false)
    static let clipboardMode = PrefKey("clipboardMode", default: ClipboardMode.fileAndImage)

    // App state
    static let onboardingCompleted = PrefKey("onboardingCompleted", default: false)
    /// Hide Desktop Icons is on; restored at launch.
    static let desktopIconsHidden = PrefKey("desktopIconsHidden", default: false)
}
