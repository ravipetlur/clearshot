import CoreGraphics

/// Delete on a pixel selection: the area is erased, filled from the pixels around it.
extension AnnotationEditor {
    /// An Erase redaction over the pixel selection, as one undo step, and the selection cleared. It is the person's own
    /// redaction, never one of the secrets check's masks, and stays an object: moving or resizing it fills it again from
    /// around its new place. Does nothing without a pixel selection, or during a crop.
    public func erasePixelSelection() {
        guard let rect = pixelSelection, crop == nil else { return }
        let object = AnnotationObject(kind: .redact(RedactObject(rect: rect, style: .erase, intensity: settings.redactIntensity)),
                                      style: ObjectStyle(color: RGBAColor(red: 0, green: 0, blue: 0), lineWidth: 1, shadow: false))
        change("Erase") { $0.objects.append(object) }
        pixelSelection = nil
    }
}
