import AppKit
import CSAnnotation
import CSCapture
import CSCore

/// The pictures image-backed background fills show, for captures and for the editor: a display's desktop from the one
/// shared `WallpaperProvider`, the system wallpapers, and the user's own pictures in `library`. A capture resolves its
/// preset's fill for the captured display; an editor gets a `BackgroundPictureSource` for the screen its window is on.
@MainActor final class BackgroundPictures {
    let library: BackgroundLibrary
    private let wallpapers: WallpaperProvider

    init(wallpapers: WallpaperProvider, library: BackgroundLibrary) {
        self.wallpapers = wallpapers
        self.library = library
    }

    /// The pictures for `display`: its desktop, and the system wallpapers and custom pictures, which are the same on every
    /// display.
    func source(for display: DisplayInfo, layout: DisplayLayout) -> BackgroundPictureSource {
        BackgroundPictureSource(
            desktop: { await self.picture(for: .desktop, display: display, layout: layout) },
            systemWallpaper: { fileName in await self.picture(for: .systemWallpaper(fileName: fileName), display: display, layout: layout) },
            customPicture: { id in await self.picture(for: .custom(id: id), display: display, layout: layout) })
    }

    /// The pictures for the display `screen` shows (an editor window's screen), or the main display's when there is no
    /// screen or it is no longer connected.
    func source(for screen: NSScreen?) -> BackgroundPictureSource {
        let layout = DisplayLayout.current()
        let display = screen?.displayID.flatMap { layout.display(id: $0) } ?? layout.main
        return source(for: display, layout: layout)
    }

    /// The picture `fill` shows on `display`, not yet prepared for a frame: the display's desktop for Desktop and Blurred
    /// desktop (blurred when prepared), or the system wallpaper or custom picture decoded upright, off the main actor. Nil
    /// when it can't be had, and for the fills that show no picture from a source (the captured window wallpaper is the
    /// capture's own).
    func picture(for fill: BackgroundFill, display: DisplayInfo, layout: DisplayLayout) async -> CGImage? {
        switch fill {
        case .desktop, .blurredDesktop:
            return await wallpapers.image(for: display, layout: layout, source: .desktop, customPath: "", plainColorHex: "")
        case .systemWallpaper(let fileName):
            return await Task.detached(priority: .userInitiated) {
                SystemWallpapers.url(for: fileName).flatMap { ImageOps.loadUpright($0) }
            }.value
        case .custom(let id):
            let library = library
            return await Task.detached(priority: .userInitiated) {
                library.url(for: id).flatMap { ImageOps.loadUpright($0) }
            }.value
        case .none, .color, .gradient, .windowWallpaper, .blurredScreenshot:
            return nil
        }
    }
}
