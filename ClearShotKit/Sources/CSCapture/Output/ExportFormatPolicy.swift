import CSCore

public enum ExportFormatPolicy {
    /// The format a capture is saved in. A transparent window shot can't be saved as JPEG without losing its
    /// transparent background, so it's saved as PNG instead.
    public static func format(preferred: ImageFormat, isTransparent: Bool) -> ImageFormat {
        isTransparent && !preferred.supportsTransparency ? .png : preferred
    }
}
