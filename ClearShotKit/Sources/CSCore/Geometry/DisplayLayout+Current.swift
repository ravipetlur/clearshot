import AppKit

public extension DisplayLayout {
    /// The live display layout, read from `NSScreen`.
    @MainActor static func current() -> DisplayLayout {
        let infos = NSScreen.screens.map { screen -> DisplayInfo in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            let id = number?.uint32Value ?? CGMainDisplayID()
            return DisplayInfo(id: id, name: screen.localizedName, frame: screen.frame,
                               scale: screen.backingScaleFactor, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                               safeAreaTop: screen.safeAreaInsets.top)
        }
        if infos.isEmpty {
            let id = CGMainDisplayID()
            return DisplayLayout(displays: [DisplayInfo(id: id, name: "Display", frame: CGDisplayBounds(id),
                                                        scale: 1, isBuiltIn: false, safeAreaTop: 0)])
        }
        return DisplayLayout(displays: infos)
    }
}
