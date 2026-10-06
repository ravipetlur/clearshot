import AppKit
import CSCapture
import CSCore

/// Hide Desktop Icons. While on, a cover on every display shows the wallpaper (from the provider window shots share)
/// over the desktop icons and widgets; it stays on across launches. Captures leave out the icons and widgets under the
/// covers, which they would otherwise show, since the covers are ClearShot windows and left out themselves.
final class DesktopIcons {
    private let preferences: Preferences
    /// Shared with window shots and editors: the covers show its pictures, never copies of them.
    private let wallpapers: WallpaperProvider
    private let drops: DesktopDropReceiver
    /// The covers are up. Stored in `Prefs.desktopIconsHidden`.
    private(set) var isHidden = false
    /// One cover per display, by display ID.
    private var covers: [CGDirectDisplayID: DesktopCoverPanel] = [:]
    /// Each picture request is a generation; one that a newer request, a screen change or showing the icons overtook
    /// shows nothing when it finishes.
    private var generations = GenerationCounter()
    private var pictureRequest: Task<Void, Never>?
    private var spaceRefresh: Task<Void, Never>?
    /// The refresh waiting for the desktop to fade to a new picture.
    private var pictureChangeRefresh: Task<Void, Never>?
    private var periodicRefresh: Task<Void, Never>?
    /// The wallpaper settings the covers last followed.
    private var wallpaperSettings: WallpaperSettings

    /// A dynamic desktop picture changes through the day.
    private static let periodicRefreshInterval: Duration = .seconds(10 * 60)
    /// How long a Space switch animates. The new Space's wallpaper is taken after it, so the cache window shots share
    /// gets the new picture rather than one caught mid-switch.
    private static let spaceSwitchDuration: Duration = .seconds(1)
    /// How long the desktop fades to a new picture; likewise, the covers take it after that.
    private static let desktopFadeDuration: Duration = .seconds(1)
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    init(preferences: Preferences, wallpapers: WallpaperProvider, hud: HUDController, gate: ModalGate) {
        self.preferences = preferences
        self.wallpapers = wallpapers
        drops = DesktopDropReceiver(hud: hud, gate: gate)
        wallpaperSettings = WallpaperSettings(preferences)
        observeWallpaperSettings()
        observeDisplays()
    }

    /// At launch: hides the icons again if they were hidden when ClearShot last quit.
    func restore() {
        if preferences[Prefs.desktopIconsHidden] { setHidden(true) }
    }

    /// Covers the desktop on every display, or takes the covers away, and remembers the choice.
    func setHidden(_ hidden: Bool) {
        preferences[Prefs.desktopIconsHidden] = hidden
        guard hidden != isHidden else { return }
        isHidden = hidden
        if hidden {
            placeCovers()
            startPeriodicRefresh()
        } else {
            _ = generations.next()
            pictureRequest?.cancel()
            spaceRefresh?.cancel()
            pictureChangeRefresh?.cancel()
            periodicRefresh?.cancel()
            covers.values.forEach { $0.close() }
            covers = [:]
        }
    }

    /// The status menu's "Hide/Show Desktop Icons" and the hotkey.
    func toggle() {
        setHidden(!isHidden)
    }

    /// After a Space change, once the coordinator has had the capture flow drop the cached desktop pictures (when
    /// "Update wallpaper when switching Spaces" is on). The covers follow the same setting and never drop the pictures
    /// for their own sake, since window shots share them. With the setting off they keep the picture they have.
    func spaceDidChange() {
        guard isHidden, preferences[Prefs.updateWallpaperOnSpaceChange] else { return }
        spaceRefresh?.cancel()
        spaceRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.spaceSwitchDuration)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// macOS said the desktop picture changed: once the desktop has faded to it, the covers take the new one, dropping
    /// the provider's cached pictures first. Taken at once, the capture could catch the old or fading picture and the
    /// provider would keep it under the new picture's file, for window shots too. Each notice restarts the wait, so a
    /// burst of them makes one refresh. Internal, for the coordinator's observer.
    func desktopPictureChanged() {
        guard isHidden else { return }
        pictureChangeRefresh?.cancel()
        pictureChangeRefresh = Task { [weak self] in
            try? await Task.sleep(for: Self.desktopFadeDuration)
            guard !Task.isCancelled else { return }
            self?.refresh(invalidating: true)
        }
    }

    // MARK: Covers

    /// One cover per screen, each the screen's size. A display that stays keeps its cover and picture, so nothing
    /// flickers; a new display's cover stays off screen until its picture is in.
    private func placeCovers() {
        var placed: [CGDirectDisplayID: DesktopCoverPanel] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.displayID, placed[id] == nil else { continue }
            let cover = covers.removeValue(forKey: id) ?? makeCover()
            cover.setFrame(screen.frame, display: true)
            placed[id] = cover
        }
        // What is left belongs to displays that went away.
        covers.values.forEach { $0.close() }
        covers = placed
        refresh()
    }

    private func makeCover() -> DesktopCoverPanel {
        let cover = DesktopCoverPanel(drops: drops)
        cover.onShowIcons = { [weak self] in self?.setHidden(false) }
        return cover
    }

    // MARK: Pictures

    /// Asks for every cover's picture again; `invalidating` first drops the provider's cached desktop pictures. A newer
    /// request overtakes one still waiting.
    private func refresh(invalidating: Bool = false) {
        guard isHidden else { return }
        if invalidating { wallpapers.invalidate() }
        let generation = generations.next()
        pictureRequest?.cancel()
        pictureRequest = Task { [weak self] in await self?.showPictures(generation: generation) }
    }

    /// Each display's wallpaper. A custom image is the same on every display and the provider doesn't cache it, so it is
    /// read once and every cover shows that one image; one that can't be read gives way to the desktop picture for this
    /// request.
    private func showPictures(generation: Int) async {
        let layout = DisplayLayout.current()
        let settings = WallpaperSettings(preferences)
        var source = settings.source
        var shared: CGImage?
        if source == .customImage {
            shared = await wallpapers.image(for: layout.main, layout: layout, source: .customImage,
                                            customPath: settings.customPath, plainColorHex: settings.plainColorHex)
            guard generations.isCurrent(generation) else { return }
            if shared == nil { source = .desktop }
        }
        for display in layout.displays {
            var picture = shared
            if picture == nil {
                picture = await wallpapers.image(for: display, layout: layout, source: source,
                                                 customPath: settings.customPath, plainColorHex: settings.plainColorHex)
                guard generations.isCurrent(generation) else { return }
            }
            guard let picture else {
                Log.app.warning("No wallpaper for the desktop cover on display \(display.id)")
                continue
            }
            covers[display.id]?.show(picture)
        }
    }

    // MARK: Refreshes

    /// The settings the covers' pictures follow. `Preferences` reports a write to any key as a change, so the covers act
    /// only when one of these differs.
    private struct WallpaperSettings: Equatable {
        let source: WallpaperSource
        let customPath: String
        let plainColorHex: String

        init(_ preferences: Preferences) {
            source = preferences[Prefs.wallpaperSource]
            customPath = preferences[Prefs.customWallpaperPath]
            plainColorHex = preferences[Prefs.wallpaperPlainColor]
        }
    }

    private func observeWallpaperSettings() {
        withObservationTracking {
            _ = WallpaperSettings(preferences)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.wallpaperSettingsDidChange()
                self?.observeWallpaperSettings()
            }
        }
    }

    private func wallpaperSettingsDidChange() {
        let settings = WallpaperSettings(preferences)
        guard settings != wallpaperSettings else { return }
        wallpaperSettings = settings
        refresh(invalidating: true)
    }

    /// Screens added, removed or rearranged place the covers again; waking and unlocking take fresh pictures, since the
    /// desktop picture may have changed meanwhile.
    private func observeDisplays() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isHidden else { return }
                self.placeCovers()
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(invalidating: true) }
        }
        DistributedNotificationCenter.default().addObserver(forName: Self.screenUnlocked, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(invalidating: true) }
        }
    }

    /// While the covers are up, fresh pictures every 10 minutes.
    private func startPeriodicRefresh() {
        periodicRefresh?.cancel()
        periodicRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.periodicRefreshInterval)
                guard !Task.isCancelled else { return }
                self?.refresh(invalidating: true)
            }
        }
    }
}
