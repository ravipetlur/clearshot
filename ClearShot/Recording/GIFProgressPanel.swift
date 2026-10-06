import AppKit
import CSCore
import SwiftUI

/// The GIF being made, where its thumbnail will appear: a 240 pt floating panel on the Quick Access side of the active
/// screen, above the thumbnails already there (in the corner when there are none, or no room), with the recording's
/// first frame, a progress bar, "Creating GIF…", the GIF's size so far and Stop. No history item exists until the GIF
/// is done, so this stands in for the thumbnail. It never activates ClearShot and sits under capture overlays, which
/// leave it out of screenshots like every ClearShot window but pins.
final class GIFProgressPanel {
    static let width: CGFloat = 240

    private let model: GIFProgressModel
    private let panel: NSPanel
    private let preferences: Preferences
    private let thumbnailFrames: () -> [CGRect]
    private var screen: NSScreen?

    /// `imagePixels` is the recording's size, for the picture's shape; `thumbnailFrames` says where the thumbnails on
    /// screen are; Stop calls `onStop`.
    init(preferences: Preferences, imagePixels: CGSize, thumbnailFrames: @escaping () -> [CGRect],
         onStop: @escaping () -> Void) {
        self.preferences = preferences
        self.thumbnailFrames = thumbnailFrames
        model = GIFProgressModel(onStop: onStop)
        let aspect = imagePixels.width > 0 && imagePixels.height > 0 ? imagePixels.height / imagePixels.width : 0.5625
        model.imageHeight = min(max((Self.width * aspect).rounded(), Self.width * 0.5), Self.width * 1.25)
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = FirstMouseHostingView(rootView: GIFProgressView(model: model))
        host.frame = CGRect(origin: .zero, size: host.fittingSize)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
    }

    /// On the active screen, above its thumbnails.
    func show() {
        screen = NSScreen.activeScreen
        place()
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// Above the thumbnails on the panel's screen, so a thumbnail that comes or goes meanwhile moves it.
    private func place() {
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        let x = preferences[Prefs.quickAccessPosition] == .left
            ? visible.minX + QuickAccessLayout.margin
            : visible.maxX - QuickAccessLayout.margin - size.width
        let corner = visible.minY + QuickAccessLayout.margin
        var y = thumbnailFrames().filter { $0.intersects(visible) }.map { $0.maxY + QuickAccessLayout.spacing }.max() ?? corner
        if y + size.height > visible.maxY - QuickAccessLayout.margin { y = corner }
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
    }

    /// The recording's first frame, once it has been read.
    func setImage(_ image: CGImage) {
        model.image = image
    }

    func update(progress: Double, bytesWritten: Int64) {
        model.progress = min(max(progress, 0), 1)
        model.bytesWritten = bytesWritten
        place()
    }

    func close() {
        panel.orderOut(nil)
    }
}

@Observable
private final class GIFProgressModel {
    var image: CGImage?
    var imageHeight: CGFloat = 135
    var progress = 0.0
    var bytesWritten: Int64 = 0
    let onStop: () -> Void

    init(onStop: @escaping () -> Void) {
        self.onStop = onStop
    }
}

private struct GIFProgressView: View {
    let model: GIFProgressModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                if let image = model.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: GIFProgressPanel.width, height: model.imageHeight)
            .clipped()
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: model.progress)
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Creating GIF…")
                            .font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: model.bytesWritten, countStyle: .file))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Stop", action: model.onStop)
                }
            }
            .padding(12)
        }
        .frame(width: GIFProgressPanel.width)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}

/// A click on Stop works without first bringing the panel forward.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
