import CoreGraphics
import CSCore
import Foundation

/// The background a capture gets: its style and, for an image-backed fill, the picture it shows.
public struct CaptureBackground: Sendable {
    public var style: BackgroundStyle
    /// The image-backed fill's picture as resolved for the capture (the capture's display's desktop, a system wallpaper, a
    /// custom picture, or the wallpaper captured behind a window), not yet prepared; nil when it couldn't be had, or for a
    /// fill without one.
    public var picture: CGImage?

    public init(style: BackgroundStyle, picture: CGImage?) {
        self.style = style
        self.picture = picture
    }
}

/// What background a new capture gets: none, a preset's style, or a window's own wallpaper ("With wallpaper").
public enum CaptureBackgroundChoice: Equatable, Sendable {
    case none
    case preset(BackgroundStyle)
    case windowWallpaper
}

/// Which background applies to a new capture.
public enum AutoApply {
    /// The background for a capture. Screenshots take the screenshot preset, windows only the window preset. ⇧
    /// (`shiftHeld`: for an area, held at the mouse-down that starts the drag, since ⇧ pressed during the drag squares the
    /// selection; for a window, held at the click) skips a preset that would apply: a screenshot then gets none, and a
    /// window its window background setting as it is (`windowMode`). Without a window preset, a window gets the setting,
    /// which ⇧ switches between wallpaper and transparent.
    public static func choice(isWindow: Bool, shiftHeld: Bool, screenshotPreset: BackgroundPreset?,
                              windowPreset: BackgroundPreset?, windowMode: WindowBackgroundMode) -> CaptureBackgroundChoice {
        guard isWindow else {
            guard let screenshotPreset, !shiftHeld else { return .none }
            return .preset(screenshotPreset.style)
        }
        if let windowPreset, !shiftHeld { return .preset(windowPreset.style) }
        // ⇧ switches the setting only when there is no window preset for it to skip.
        let switched = shiftHeld && windowPreset == nil
        return (windowMode == .wallpaper) != switched ? .windowWallpaper : .none
    }

    /// Each kind's auto-apply preset: its auto-apply id (`BackgroundPresetKind.autoApplyKey`) looked up in its own list.
    /// "" (off), an id that isn't one, or one no preset of that kind has, is nil.
    @MainActor
    public static func presets(in preferences: Preferences) -> (screenshot: BackgroundPreset?, window: BackgroundPreset?) {
        func preset(_ kind: BackgroundPresetKind) -> BackgroundPreset? {
            preferences[kind.presetsKey].preset(idString: preferences[kind.autoApplyKey])
        }
        return (preset(.screenshot), preset(.window))
    }
}

/// A capture that gets a background becomes a document, so it reopens in Annotate with its background editable. It
/// reads no preferences and writes no files, and everything it takes is Sendable, so it runs off the main actor.
public enum CaptureDocument {
    /// The document for `base`, the processed capture (`pixelScale` its pixels per point), with `background`, its images
    /// and its render (`Renderer.render`, no cache).
    ///
    /// The base is stored as `AnnotationStorage.historyBase`, as a history item's document has it. The style is
    /// `clamped()`. An image-backed fill's picture is prepared for the style's frame around the capture, untrimmed
    /// (`BackgroundImagePrep.prepare`; the captured window wallpaper stays as it is), and stored under a fresh name
    /// (`BackgroundImagePrep.reference(for:)`). An image-backed fill without a picture, or whose picture can't be
    /// prepared, becomes the first catalog gradient: the document's fill then differs from the one asked for, which the
    /// caller logs. Nil when the render fails, or when the document couldn't be read back (`isWellFormed`).
    public static func make(base: CGImage, pixelScale: Double, isWindowShot: Bool, background: CaptureBackground)
        -> (document: AnnotationDocument, images: ImageStore, rendered: CGImage)? {
        var document = AnnotationDocument(baseSize: CGSize(width: base.width, height: base.height), pixelScale: pixelScale,
                                          base: AnnotationStorage.historyBase)
        document.isWindowShot = isWindowShot
        var images = ImageStore([AnnotationStorage.historyBase.name: base])
        var style = background.style.clamped()
        var pictureRef: ImageRef?
        if style.fill.isImageBacked {
            // The frame with this style, untrimmed: the largest the picture has to cover.
            document.background = DocumentBackground(style: style)
            if let picture = background.picture, let frame = document.backgroundLayout()?.frame.size,
               let prepared = BackgroundImagePrep.prepare(picture, for: style.fill, frame: frame) {
                let ref = BackgroundImagePrep.reference(for: prepared)
                images.set(prepared, for: ref)
                pictureRef = ref
            } else {
                style.fill = .gradient(.standard)
            }
        }
        document.background = DocumentBackground(style: style, image: pictureRef)
        guard document.isWellFormed, let rendered = Renderer.render(document, images: images) else { return nil }
        return (document, images, rendered)
    }
}
