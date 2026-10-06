import CoreGraphics
import CSCore
import Foundation

/// Where the editor gets the pictures of image-backed fills, for the editor's display: the desktop (sharp or to be
/// blurred), a system wallpaper by its file name, and a custom picture by its id. Each answers nil when it has none.
public struct BackgroundPictureSource: Sendable {
    public var desktop: @MainActor @Sendable () async -> CGImage?
    public var systemWallpaper: @MainActor @Sendable (String) async -> CGImage?
    public var customPicture: @MainActor @Sendable (UUID) async -> CGImage?

    public init(desktop: @escaping @MainActor @Sendable () async -> CGImage?,
                systemWallpaper: @escaping @MainActor @Sendable (String) async -> CGImage?,
                customPicture: @escaping @MainActor @Sendable (UUID) async -> CGImage?) {
        self.desktop = desktop
        self.systemWallpaper = systemWallpaper
        self.customPicture = customPicture
    }

    /// No pictures: every image-backed fill falls back to the first gradient. For applying fills that need none.
    public static var none: BackgroundPictureSource {
        BackgroundPictureSource(desktop: { nil }, systemWallpaper: { _ in nil }, customPicture: { _ in nil })
    }
}

/// The Background tool: the panel, the background's undo steps, presets and Previous Settings.
///
/// Background changes are canvas changes (`changeCanvas`), so they never auto-expand the canvas. Like the canvas fill they
/// are ignored while a live change is open, except style edits, which join it, and they stay out of Crop & Resize, where
/// the canvas shows the content alone. A whole style (a fill click, a preset, Previous Settings) is applied asynchronously,
/// since its picture may have to be fetched and prepared. A late picture never overwrites a later change: the apply is
/// dropped if, while it waits, a newer apply or Remove Background is asked for, the background changes in any way (a style
/// edit, undo, redo), or a crop or a live change opens.
extension AnnotationEditor {
    // MARK: Reading

    /// What the document renders, in output pixels: the background's frame, less what auto-balance trims, or the canvas
    /// without a background. Whatever sizes the output (the canvas view, the Resize sheet) uses this. It is measured with
    /// `renderCache`, which the canvas shares, so auto-balance's trims are measured once while the content is unchanged.
    public var outputBounds: CGRect {
        Renderer.outputBounds(of: document, images: images, cache: renderCache)
    }

    /// The kind whose presets, Previous Settings and auto-apply preset the document takes.
    public var presetKind: BackgroundPresetKind {
        BackgroundPresetKind(of: document)
    }

    /// What opening the panel on a document without a background applies: its kind's Previous Settings, or else its kind's
    /// standard style.
    public var defaultBackgroundStyle: BackgroundStyle {
        preferences[presetKind.previousKey].style ?? presetKind.standardStyle
    }

    /// The document's kind's presets, in the menu's order.
    public var presets: [BackgroundPreset] {
        preferences[presetKind.presetsKey].presets
    }

    /// The preset whose style is exactly the background's, which the panel names; nil without a background.
    public var matchingPreset: BackgroundPreset? {
        guard let style = document.background?.style else { return nil }
        return preferences[presetKind.presetsKey].matching(style)
    }

    /// The preset applied or saved last in this editor, while it still exists.
    public var lastAppliedPreset: BackgroundPreset? {
        lastAppliedPresetID.flatMap { preferences[presetKind.presetsKey].preset(id: $0) }
    }

    /// Whether the last applied preset is the one applied to every new capture of the document's kind.
    public var autoAppliesLastPreset: Bool {
        guard let preset = lastAppliedPreset else { return false }
        return UUID(uuidString: preferences[presetKind.autoApplyKey]) == preset.id
    }

    /// Whether the document's kind has Previous Settings to apply.
    public var canApplyPreviousSettings: Bool {
        preferences[presetKind.previousKey].style != nil
    }

    // MARK: The panel

    /// Shows the panel. A document without a background gets `defaultBackgroundStyle` as one undo step, "Add Background",
    /// unless a crop is being edited or a live change is open: then the panel opens with nothing applied.
    public func openBackgroundPanel(pictures: BackgroundPictureSource) async {
        isBackgroundPanelOpen = true
        guard document.background == nil, crop == nil, !isInLiveChange else { return }
        await applyBackground(defaultBackgroundStyle, actionName: "Add Background", pictures: pictures)
    }

    /// Hides the panel. The background stays, and so does an apply still loading its picture: it lands.
    public func closeBackgroundPanel() {
        isBackgroundPanelOpen = false
    }

    // MARK: Applying a style

    /// Applies `style`, clamped, as one undo step named `actionName`, and with `presetID` makes that preset the last
    /// applied one. An image-backed fill's picture comes from `pictures` (the captured wallpaper from `capturedWallpaper`),
    /// prepared off the main actor for the frame the style gives (`BackgroundImagePrep`), and joins the document's images
    /// in the same step; a fill whose picture can't be had becomes the first catalog gradient. Any other fill stores no
    /// picture.
    ///
    /// Nothing happens while a crop is being edited or a live change is open. The apply is dropped if, while its picture is
    /// fetched or prepared, either opens, a newer apply or Remove Background is asked for, or the background changes.
    public func applyBackground(_ style: BackgroundStyle, actionName: String, pictures: BackgroundPictureSource,
                                presetID: UUID? = nil) async {
        guard canChangeBackground else { return }
        backgroundRequest &+= 1
        let request = backgroundRequest
        let requestedOver = document.background
        var style = style.clamped()
        var image: ImageRef?
        var prepared: (picture: CGImage, ref: ImageRef)?
        switch style.fill {
        case .windowWallpaper:
            image = capturedWallpaper
        case let fill where fill.isImageBacked:
            let found = await picture(for: fill, from: pictures)
            guard isCurrentBackgroundRequest(request, over: requestedOver) else { return }
            if let found {
                // The frame of the document as it is now, with this style, untrimmed: the largest the picture must cover.
                var framed = document
                framed.background = DocumentBackground(style: style)
                let frame = framed.backgroundLayout()?.frame.size ?? document.canvasBounds.size
                prepared = await Task.detached(priority: .userInitiated) { () -> (picture: CGImage, ref: ImageRef)? in
                    guard let picture = BackgroundImagePrep.prepare(found, for: fill, frame: frame) else { return nil }
                    return (picture, BackgroundImagePrep.reference(for: picture))
                }.value
                guard isCurrentBackgroundRequest(request, over: requestedOver) else { return }
                image = prepared?.ref
            }
        default:
            break
        }
        if style.fill.isImageBacked, image == nil {
            log.info("No picture for the background fill \(style.fill); using the first gradient instead")
            style.fill = .gradient(.standard)
        }
        if let prepared { addImage(prepared.picture, for: prepared.ref) }
        let background = DocumentBackground(style: style, image: image)
        changeCanvas(actionName) { $0.background = background }
        if let presetID { lastAppliedPresetID = presetID }
    }

    /// A fill click: the current style, or `defaultBackgroundStyle` without a background, with `fill`, applied as
    /// "Change Background".
    public func setBackgroundFill(_ fill: BackgroundFill, pictures: BackgroundPictureSource) async {
        var style = document.background?.style ?? defaultBackgroundStyle
        style.fill = fill
        await applyBackground(style, actionName: "Change Background", pictures: pictures)
    }

    /// Edits the background's style, then clamps it: a typed value or a click as one undo step (a run of them within a
    /// second when `coalescing`, the color panel's stream), or, inside a live change (a slider drag, which
    /// `sliderEditingChanged` opens and closes), just an edit the drag records as one step when it ends.
    ///
    /// Nothing happens without a background (the panel stays open after its undo) or while a crop is being edited. A fill
    /// changed to another that shows no picture drops the old picture; one changed to an image-backed fill is ignored
    /// whole, since that fill needs its picture resolved (`setBackgroundFill`).
    public func updateBackgroundStyle(_ actionName: String, coalescing: Bool = false, _ body: (inout BackgroundStyle) -> Void) {
        guard let background = document.background, crop == nil else { return }
        var style = background.style
        body(&style)
        style = style.clamped()
        var image = background.image
        if style.fill != background.style.fill {
            guard !style.fill.isImageBacked else { return }
            image = nil
        }
        let edited = DocumentBackground(style: style, image: image)
        if isInLiveChange {
            updateLive { $0.background = edited }
        } else {
            changeCanvas(actionName, coalescing: coalescing) { $0.background = edited }
        }
    }

    /// Remove background: one undo step, which also closes the panel. Nothing happens without a background, while a crop is
    /// being edited or while a live change is open. A picture still on its way for an earlier choice is dropped.
    public func removeBackground() {
        guard canChangeBackground, document.background != nil else { return }
        backgroundRequest &+= 1
        changeCanvas("Remove Background") { $0.background = nil }
        closeBackgroundPanel()
    }

    // MARK: Presets and Previous Settings

    /// Applies `preset`'s style as "Apply Preset", and makes it the last applied preset.
    public func applyPreset(_ preset: BackgroundPreset, pictures: BackgroundPictureSource) async {
        await applyBackground(preset.style, actionName: "Apply Preset", pictures: pictures, presetID: preset.id)
    }

    /// Applies the document's kind's Previous Settings as "Apply Previous Settings"; nothing when there are none.
    public func applyPreviousSettings(pictures: BackgroundPictureSource) async {
        guard let style = preferences[presetKind.previousKey].style else { return }
        await applyBackground(style, actionName: "Apply Previous Settings", pictures: pictures)
    }

    /// Saves the background's style as a new preset of the document's kind (`BackgroundPresetList.add` names it), and makes
    /// it the last applied preset. Nil, saving nothing, without a background.
    @discardableResult
    public func saveBackgroundAsPreset(named name: String) -> BackgroundPreset? {
        guard let style = document.background?.style else { return nil }
        var preset: BackgroundPreset?
        editPresets { preset = $0.add(name: name, style: style) }
        lastAppliedPresetID = preset?.id
        return preset
    }

    /// Update "<name>": writes the background's style into the last applied preset. Nothing without both.
    public func updateLastAppliedPreset() {
        guard let style = document.background?.style, let preset = lastAppliedPreset else { return }
        editPresets { $0.update(preset.id, style: style) }
    }

    public func renamePreset(_ id: UUID, to name: String) {
        editPresets { $0.rename(id, to: name) }
    }

    /// Deletes the preset. If it was the kind's auto-apply preset, auto-apply turns off; if it was the last applied one,
    /// there is none.
    public func deletePreset(_ id: UUID) {
        editPresets { $0.remove(id) }
        let autoApply = presetKind.autoApplyKey
        if UUID(uuidString: preferences[autoApply]) == id { preferences[autoApply] = "" }
        if lastAppliedPresetID == id { lastAppliedPresetID = nil }
    }

    /// "Apply to New Screenshots Automatically": on makes the last applied preset the kind's auto-apply preset (nothing
    /// without one); off turns auto-apply off for the kind.
    public func setAutoApplyLastPreset(_ on: Bool) {
        let key = presetKind.autoApplyKey
        if on {
            guard let preset = lastAppliedPreset else { return }
            preferences[key] = preset.id.uuidString
        } else {
            preferences[key] = ""
        }
    }

    // MARK: Helpers

    /// Background commands wait for an open live change to end and stay out of Crop & Resize.
    private var canChangeBackground: Bool {
        crop == nil && !isInLiveChange
    }

    /// An apply that has awaited may go on: no newer apply or Remove Background was asked for, the background is still
    /// `background`, the one it was asked over (no style edit, undo or redo since: the apply would put back the style from
    /// before them), and it may still change the background.
    private func isCurrentBackgroundRequest(_ request: Int, over background: DocumentBackground?) -> Bool {
        request == backgroundRequest && document.background == background && canChangeBackground
    }

    /// The picture an image-backed fill shows, from its source; nil for the captured wallpaper and the fills without one.
    private func picture(for fill: BackgroundFill, from pictures: BackgroundPictureSource) async -> CGImage? {
        switch fill {
        case .desktop, .blurredDesktop:
            return await pictures.desktop()
        case .systemWallpaper(let fileName):
            return await pictures.systemWallpaper(fileName)
        case .custom(let id):
            return await pictures.customPicture(id)
        case .none, .color, .gradient, .windowWallpaper, .blurredScreenshot:
            return nil
        }
    }

    /// Edits the document's kind's preset list in the preferences.
    private func editPresets(_ body: (inout BackgroundPresetList) -> Void) {
        let key = presetKind.presetsKey
        var list = preferences[key]
        body(&list)
        preferences[key] = list
    }
}
