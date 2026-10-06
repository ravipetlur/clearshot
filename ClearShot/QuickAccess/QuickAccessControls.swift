import AppKit
import AVFoundation
import CSHistory
import CSRecording

/// A view that never takes clicks itself, so they reach the view below; its subviews still get theirs.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Shows a thumbnail scaled to fit, through its layer. Clicks go to the view below.
final class ThumbnailView: NSView {
    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.contents = image
        layer?.contentsGravity = .resizeAspect
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A dark translucent capsule with white text: the Copy and Save hover buttons.
final class PillButton: NSButton {
    init(label: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        layer?.cornerCurve = .continuous
        setLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The thumbnail's panel never activates ClearShot, so without this the first click only brings the panel forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setLabel(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
        ])
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// A small dark circle with a white symbol: the corner hover buttons.
final class CircleButton: NSButton {
    init(symbol: String, label: String) {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        imagePosition = .imageOnly
        contentTintColor = .white
        setLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The tooltip, and what VoiceOver reads.
    func setLabel(_ text: String) {
        toolTip = text
        setAccessibilityLabel(text)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }
}

/// A standard button that takes the first click in a thumbnail's panel: the name strip's Save and Discard.
final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

extension MediaBadge {
    /// A video's or GIF's badge (`MediaBadge`), its size read from the working copy now, so it is current after Mute or
    /// Replace. Nil for a screenshot.
    init?(item: HistoryItem, root: URL) {
        guard item.kind == .video || item.kind == .gif else { return nil }
        let path = item.mediaURL(in: root).path(percentEncoded: false)
        let bytes = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value
        self.init(isGIF: item.kind == .gif, duration: item.duration, bytes: bytes, hasAudio: item.hasAudio)
    }
}

/// The dark capsule at the bottom-left of a video or GIF thumbnail and History cell, in the overlay buttons' style:
/// `MediaBadge`'s text in small white text, then the speaker. It draws itself, so a drag image can be rendered from it
/// (`image()`). Clicks go to the view below.
final class MediaBadgeView: NSView {
    static let height: CGFloat = 18
    private static let padding: CGFloat = 7
    private static let speakerGap: CGFloat = 3
    private static let attributes: [NSAttributedString.Key: Any] = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        return [
            .foregroundColor: NSColor.white,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
            .paragraphStyle: style,
        ]
    }()
    private static let speaker = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white])))

    var content: MediaBadge? {
        didSet {
            guard content != oldValue else { return }
            isHidden = content == nil
            setAccessibilityLabel(content.map { $0.showsSpeaker ? "\($0.text), with sound" : $0.text })
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The size the content needs, at most `maxWidth` wide (the text is then cut short, the speaker kept).
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        guard let content else { return .zero }
        let text = (content.text as NSString).size(withAttributes: Self.attributes).width.rounded(.up)
        let speaker = content.showsSpeaker ? Self.speakerGap + (Self.speaker?.size.width ?? 0) : 0
        let width = Self.padding * 2 + text + speaker
        return NSSize(width: min(width, max(maxWidth, Self.height)), height: Self.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let speakerSize = content.showsSpeaker ? Self.speaker?.size ?? .zero : .zero
        let speakerWidth = content.showsSpeaker ? Self.speakerGap + speakerSize.width : 0
        let text = NSAttributedString(string: content.text, attributes: Self.attributes)
        let textHeight = text.size().height
        let textRect = NSRect(x: bounds.minX + Self.padding, y: bounds.midY - textHeight / 2,
                              width: max(0, bounds.width - Self.padding * 2 - speakerWidth), height: textHeight)
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if content.showsSpeaker, let speaker = Self.speaker {
            speaker.draw(in: NSRect(x: textRect.maxX + Self.speakerGap, y: bounds.midY - speakerSize.height / 2,
                                    width: speakerSize.width, height: speakerSize.height))
        }
    }

    /// The badge as it is drawn now, rendered at once on the main actor (so no drawing is left for later, off it), for
    /// a drag image; nil while it shows nothing.
    func image() -> NSImage? {
        guard content != nil, !isHidden, bounds.width > 0,
              let bitmap = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: bitmap)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// What a thumbnail's hover preview plays: a video's file, or a GIF itself, so a GIF shortened by Trim the GIF… shows
/// only what it holds, at its own timing.
enum HoverPreviewSource: Equatable {
    case video(URL)
    case gif(URL)
}

/// A video's or GIF's hover preview, over the picture in the frame it is given:
/// - a video plays muted and looping (`AVQueuePlayer` + `AVPlayerLooper`), filling the frame;
/// - a GIF animates in an image view, fitted as its picture is.
///
/// Nothing is loaded until `play`, and `stop` lets go of the player or the image. Only one plays at a time. Hover
/// already gives that, since one thumbnail is under the pointer, but a panel that moves out from under a still pointer
/// gets no `mouseExited`; so, belt and braces, starting one stops any other. That other thumbnail keeps its hover
/// state, and its preview starts again once the pointer comes back to it. Clicks go to the view below.
final class HoverPreviewView: NSView {
    /// The preview playing now, if any.
    private static weak var playing: HoverPreviewView?

    private let playerLayer = AVPlayerLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var imageView: NSImageView?
    /// A GIF's file being read, off the main actor.
    private var loading: Task<Void, Never>?
    /// What is playing.
    private var source: HoverPreviewSource?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func makeBackingLayer() -> CALayer { playerLayer }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Plays `source` from its start, looping, after stopping any other preview. Playing the same source again does
    /// nothing. A GIF is read off the main actor, so a long one doesn't hold up the hover, and shows once read; one
    /// that can't be read leaves the picture showing.
    func play(_ source: HoverPreviewSource) {
        if self.source == source { return }
        stop()
        if let other = Self.playing, other !== self { other.stop() }
        self.source = source
        Self.playing = self
        switch source {
        case .video(let url):
            let player = AVQueuePlayer()
            player.isMuted = true
            player.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            playerLayer.player = player
            self.player = player
            player.play()
            isHidden = false
        case .gif(let url):
            loading = Task { [weak self] in
                let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }.value
                // Stopped, or another source asked for, while it was read.
                guard let self, !Task.isCancelled, self.source == source, let data, let image = NSImage(data: data) else {
                    return
                }
                showGIF(image)
            }
        }
    }

    /// The GIF, animating in an image view over the picture.
    private func showGIF(_ image: NSImage) {
        let imageView = NSImageView(frame: bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.imageScaling = .scaleProportionallyUpOrDown
        // Display only: an editable image view would take a dropped image in place of the GIF.
        imageView.isEditable = false
        imageView.animates = true
        imageView.image = image
        addSubview(imageView)
        self.imageView = imageView
        isHidden = false
    }

    /// Stops and lets go of the player or the image, and its file.
    func stop() {
        guard source != nil else { return }
        loading?.cancel()
        loading = nil
        looper?.disableLooping()
        looper = nil
        player?.pause()
        player?.removeAllItems()
        playerLayer.player = nil
        player = nil
        imageView?.animates = false
        imageView?.image = nil
        imageView?.removeFromSuperview()
        imageView = nil
        source = nil
        isHidden = true
        if Self.playing === self { Self.playing = nil }
    }
}

/// Supplies the PNG for a drag only when the drop target asks for image data. Apps that take files get the file URL and
/// never trigger the read.
nonisolated final class DragImageProvider: NSObject, NSPasteboardItemDataProvider {
    let pngURL: URL

    init(pngURL: URL) {
        self.pngURL = pngURL
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard let data = try? Data(contentsOf: pngURL) else { return }
        item.setData(data, forType: type)
    }
}
