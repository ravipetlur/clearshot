import AppKit
import CSHistory
import CSRecording

/// One capture in the History grid: its thumbnail (with a video's or GIF's badge), display name, source app icon and
/// relative time. The cell keeps the item's ID and image stamp, so a thumbnail that finishes loading after the cell was
/// reused is dropped.
final class HistoryCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryCell")
    static let size = NSSize(width: 192, height: 168)
    private static let thumbnailHeight: CGFloat = 120

    private let thumbnailView = HistoryThumbnailView()
    private let selectionRing = SelectionRingView()
    private let nameField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let timeField = NSTextField(labelWithString: "")

    /// The item shown, and its image stamp (`modifiedAt`).
    private(set) var itemID: UUID?
    private var stamp: Date?
    private var createdAt: Date?

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.size))
        buildViews()
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateSelection() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clear()
    }

    private func clear() {
        itemID = nil
        stamp = nil
        createdAt = nil
        thumbnailView.image = nil
        thumbnailView.badge = nil
        nameField.stringValue = ""
        timeField.stringValue = ""
        iconView.image = nil
        iconView.isHidden = true
        view.toolTip = nil
    }

    // MARK: Content

    /// Shows `item`, or nothing when it has just left history (the grid catches up on the next turn). `badge` is a
    /// video's or GIF's, nil for a screenshot.
    func configure(_ item: HistoryItem?, icon: NSImage?, badge: MediaBadge?, now: Date, thumbnails: HistoryThumbnails) {
        guard let item else {
            clear()
            return
        }
        itemID = item.id
        stamp = item.modifiedAt
        createdAt = item.createdAt
        nameField.stringValue = item.displayName
        iconView.image = icon
        iconView.isHidden = icon == nil
        updateTime(now: now)
        view.toolTip = Self.toolTip(for: item)
        thumbnailView.badge = badge
        let id = item.id
        let stamp = item.modifiedAt
        thumbnailView.image = thumbnails.image(for: item) { [weak self] image in
            guard let self, itemID == id, self.stamp == stamp else { return }
            thumbnailView.image = image
        }
    }

    func updateTime(now: Date) {
        guard let createdAt else { return }
        timeField.stringValue = HistoryTime.label(for: createdAt, now: now)
    }

    /// Selected, or about to be by a rubber band: the ring, in the accent colour while the window is key.
    func updateSelection() {
        let shows = highlightState == .forSelection || (isSelected && highlightState != .forDeselection)
        selectionRing.isHidden = !shows
        selectionRing.needsDisplay = true
    }

    /// A drag-out's image: the picture where the cell shows it, with a video's or GIF's badge on it. The default draws
    /// the item's `imageView` and `textField`, which this cell doesn't use. Frames are in the unflipped item view's
    /// coordinates, as AppKit wants.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let image = thumbnailView.image else { return super.draggingImageComponents }
        let picture = view.convert(thumbnailView.pictureRect, from: thumbnailView)
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = NSImage(cgImage: image, size: picture.size)
        component.frame = picture
        guard let badge = thumbnailView.badgeImage() else { return [component] }
        let label = NSDraggingImageComponent(key: .label)
        label.contents = badge.image
        label.frame = view.convert(badge.frame, from: thumbnailView)
        return [component, label]
    }

    /// The display name, then the app and window title when known.
    private static func toolTip(for item: HistoryItem) -> String {
        let source = [item.appName, item.windowTitle].compactMap { $0?.isEmpty == false ? $0 : nil }
        return source.isEmpty ? item.displayName : item.displayName + "\n" + source.joined(separator: " · ")
    }

    // MARK: Views

    private func buildViews() {
        nameField.font = .preferredFont(forTextStyle: .callout)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        timeField.font = .preferredFont(forTextStyle: .caption1)
        timeField.textColor = .secondaryLabelColor
        timeField.lineBreakMode = .byTruncatingTail
        timeField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .caption1)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.isHidden = true

        // The icon goes first; without one, the time moves left into its place.
        let details = NSStackView(views: [iconView, timeField])
        details.orientation = .horizontal
        details.alignment = .centerY
        details.spacing = 4

        selectionRing.isHidden = true
        for subview in [thumbnailView, selectionRing, nameField, details] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The ring sits 2 pt outside the thumbnail, so its 3-pt line overlaps the thumbnail's edge by 1 pt and its
        // 8-pt corners follow the thumbnail's 6-pt ones.
        let ringOutset: CGFloat = 2
        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: view.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: Self.thumbnailHeight),

            selectionRing.topAnchor.constraint(equalTo: thumbnailView.topAnchor, constant: -ringOutset),
            selectionRing.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: ringOutset),
            selectionRing.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: -ringOutset),
            selectionRing.trailingAnchor.constraint(equalTo: thumbnailView.trailingAnchor, constant: ringOutset),

            nameField.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 8),
            nameField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            details.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 4),
            details.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            details.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])
    }
}

/// The thumbnail area: the picture fitted inside, on a fill with rounded corners, or a photo symbol while the picture
/// loads or when there is none; a video's or GIF's badge at the picture's bottom-left.
private final class HistoryThumbnailView: NSView {
    var image: CGImage? {
        didSet {
            picture.image = image
            placeholder.isHidden = image != nil
            // The badge follows the picture's corner.
            needsLayout = true
        }
    }

    var badge: MediaBadge? {
        get { badgeView.content }
        set {
            badgeView.content = newValue
            needsLayout = true
        }
    }

    private let picture = ThumbnailView()
    private let placeholder = NSImageView()
    private let badgeView = MediaBadgeView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        placeholder.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        placeholder.symbolConfiguration = NSImage.SymbolConfiguration(textStyle: .title1)
        placeholder.contentTintColor = .tertiaryLabelColor
        for subview in [picture, placeholder] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }
        // Placed by `layout`, not by constraints.
        addSubview(badgeView)
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: topAnchor),
            picture.bottomAnchor.constraint(equalTo: bottomAnchor),
            picture.leadingAnchor.constraint(equalTo: leadingAnchor),
            picture.trailingAnchor.constraint(equalTo: trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Where the picture is drawn, fitted inside and centred; the whole area while there is none.
    var pictureRect: NSRect {
        guard let image, image.width > 0, image.height > 0 else { return bounds }
        let scale = min(bounds.width / CGFloat(image.width), bounds.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 6
        let picture = pictureRect
        let size = badgeView.fittingSize(maxWidth: picture.width - inset * 2)
        badgeView.frame = NSRect(x: picture.minX + inset, y: picture.minY + inset, width: size.width, height: size.height)
    }

    /// The badge as drawn, and where, for a drag image; nil without one.
    func badgeImage() -> (image: NSImage, frame: NSRect)? {
        layoutSubtreeIfNeeded()
        return badgeView.image().map { ($0, badgeView.frame) }
    }
}

/// The selection border around a thumbnail: the accent colour while the window is key, the unemphasized selection
/// colour otherwise. The grid redraws it when the window's key state changes.
private final class SelectionRingView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let color: NSColor = window?.isKeyWindow == true ? .controlAccentColor : .unemphasizedSelectedContentBackgroundColor
        layer?.borderColor = color.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
