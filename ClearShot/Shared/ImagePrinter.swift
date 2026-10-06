import AppKit

/// Printing a picture: Annotate's Print… and Print on Several Pages… and the thumbnail's Print…. The print panel
/// carries "Scale image to fit on one page". Ticked, the picture shrinks onto one page; unticked, it runs over several
/// pages along its longer side, down for a tall capture and across for a wide one, at the width or height of the page.
enum ImagePrinter {
    /// The system print panel for `image` shown at `pointSize`; `fitOnOnePage` is the checkbox's starting state.
    static func run(_ image: CGImage, pointSize: NSSize, fitOnOnePage: Bool) {
        // The view shares the image's bitmap: a 16 383 px capture isn't drawn into a new one.
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: pointSize))
        imageView.image = NSImage(cgImage: image, size: pointSize)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let isTall = pointSize.height >= pointSize.width
        // The operation keeps a copy of the print info it is made with, so the starting pagination and orientation go
        // on first; the checkbox's changes reach the panel's print info through the accessory. A picture wider than
        // tall starts in landscape; the panel's Orientation can still turn it.
        let info = NSPrintInfo()
        if !isTall { info.orientation = .landscape }
        FitOnOnePageAccessory.paginate(info, fitOnOnePage: fitOnOnePage, isTall: isTall)
        let operation = NSPrintOperation(view: imageView, printInfo: info)
        // Paper size and orientation, since ClearShot has no Page Setup (landscape suits a wide capture), and the preview
        // the checkbox redraws.
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview])
        operation.printPanel.addAccessoryController(FitOnOnePageAccessory(isTall: isTall, fitOnOnePage: fitOnOnePage))
        NSApp.activate()
        operation.run()
    }
}

/// The print panel's "Scale image to fit on one page" checkbox, which sets the pagination of the print info the panel
/// shows and has the panel redraw its preview.
private final class FitOnOnePageAccessory: NSViewController, NSPrintPanelAccessorizing {
    /// Whether the picture is at least as tall as it is wide, so pages run down it rather than across.
    private let isTall: Bool

    /// The checkbox's state. The panel observes it (`keyPathsForValuesAffectingPreview`), and its print info has the
    /// matching pagination before the panel hears of a change.
    @objc dynamic var fitOnOnePage: Bool {
        didSet { applyPagination() }
    }

    init(isTall: Bool, fitOnOnePage: Bool) {
        self.isTall = isTall
        self.fitOnOnePage = fitOnOnePage
        super.init(nibName: nil, bundle: nil)
        // The print panel's pop-up menu lists the accessory by its title; untitled, it showed "ClearShot" and the
        // checkbox was out of view behind it.
        title = "Image"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The panel's print info, handed over as the panel opens. It is the checkbox's only way to the job's settings: the
    /// operation works on its own copy of the info it was made with, and the panel on another object again. It gets the
    /// checkbox's pagination as it arrives and on every change.
    override var representedObject: Any? {
        didSet { applyPagination() }
    }

    override func loadView() {
        let checkbox = NSButton(checkboxWithTitle: "Scale image to fit on one page", target: self,
                                action: #selector(toggleFitOnOnePage(_:)))
        checkbox.state = fitOnOnePage ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(checkbox)
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            checkbox.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            checkbox.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        container.setFrameSize(container.fittingSize)
        view = container
    }

    @objc private func toggleFitOnOnePage(_ sender: NSButton) {
        fitOnOnePage = sender.state == .on
    }

    private func applyPagination() {
        guard let shown = representedObject as? NSPrintInfo else { return }
        Self.paginate(shown, fitOnOnePage: fitOnOnePage, isTall: isTall)
    }

    /// On one page: both directions fit, centred both ways. Over several: the longer side pages, the other fits the
    /// paper and is centred.
    static func paginate(_ info: NSPrintInfo, fitOnOnePage: Bool, isTall: Bool) {
        let pages: (horizontal: NSPrintInfo.PaginationMode, vertical: NSPrintInfo.PaginationMode)
        if fitOnOnePage {
            pages = (.fit, .fit)
        } else {
            pages = isTall ? (.fit, .automatic) : (.automatic, .fit)
        }
        info.horizontalPagination = pages.horizontal
        info.verticalPagination = pages.vertical
        info.isHorizontallyCentered = pages.horizontal == .fit
        info.isVerticallyCentered = pages.vertical == .fit
    }

    // MARK: NSPrintPanelAccessorizing

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Scale image to fit on one page", .itemDescription: fitOnOnePage ? "On" : "Off"]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        [Self.fitOnOnePageKey]
    }

    /// The panel observes `localizedSummaryItems`, which follows the checkbox.
    @objc nonisolated static func keyPathsForValuesAffectingLocalizedSummaryItems() -> Set<String> {
        [fitOnOnePageKey]
    }

    /// `fitOnOnePage`'s key path, as a string KVO can be handed off the main actor.
    private nonisolated static let fitOnOnePageKey = "fitOnOnePage"
}
