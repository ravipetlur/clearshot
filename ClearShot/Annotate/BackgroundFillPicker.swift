import AppKit
import CSAnnotation
import Observation
import SwiftUI

/// The Background panel's fills: None; the gradients, ten or all twenty; the wallpapers (the captured one, the desktop
/// sharp and blurred, the blurred screenshot, the system wallpapers and the user's own pictures, which Add background…
/// adds to); and the colors, with a color of your own. A click applies the fill as one undo step once its picture is
/// had, and a second click before then wins. The fill the background has is outlined.
struct BackgroundFillPicker: View {
    @Bindable var editor: AnnotationEditor
    let actions: EditorActions
    let commands: BackgroundCommands
    @State private var showsAllGradients = false
    @State private var systemWallpapers: [String] = []
    @State private var customPictures: [BackgroundLibrary.Entry] = []
    /// The desktop picture of the window's screen, for the Desktop tiles.
    @State private var desktopPicture: URL?
    /// Bumped when a picture is added or removed, so the lists are read again.
    @State private var libraryRevision = 0
    @State private var thumbnails = PictureThumbnails()
    @State private var showingColors = false

    /// The gradients shown before Show more.
    private static let shortGradientCount = 10
    /// Five tiles to a row, 40 pt wide, narrower if the panel is (a scroll bar that takes room).
    private static let columns = Array(repeating: GridItem(.flexible(minimum: 24, maximum: 40), spacing: 8), count: 5)

    /// The background's fill; nil without a background, when no tile is selected.
    private var currentFill: BackgroundFill? {
        editor.document.background?.style.fill
    }

    /// Whether the background's fill is None. (`currentFill == .none` would ask whether there is no background.)
    private var isNoneSelected: Bool {
        if case .some(.none) = currentFill { true } else { false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            none
            gradients
            wallpapers
            colors
        }
        .onAppear {
            // A gradient past the first ten shows when the panel opens on it.
            if case .gradient(let gradient)? = currentFill,
               let index = BackgroundGradient.catalog.firstIndex(of: gradient), index >= Self.shortGradientCount {
                showsAllGradients = true
            }
        }
        .task(id: libraryRevision) { await readPictureLists() }
    }

    // MARK: Groups

    private var none: some View {
        Button {
            commands.setFill(.none)
        } label: {
            HStack(spacing: 8) {
                FillTileFace(isSelected: isNoneSelected) { Checkerboard() }
                    .frame(width: 40)
                Text("None")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("No fill: transparent around the picture")
        .accessibilityAddTraits(isNoneSelected ? .isSelected : [])
    }

    private var gradients: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundSectionTitle("Gradients")
            let shown = showsAllGradients ? BackgroundGradient.catalog
                : Array(BackgroundGradient.catalog.prefix(Self.shortGradientCount))
            grid {
                ForEach(shown, id: \.self) { gradient in
                    tile(.gradient(gradient), title: gradient.title) { GradientPreview(gradient: gradient) }
                }
            }
            Button(showsAllGradients ? "Show less" : "Show more") {
                showsAllGradients.toggle()
            }
            .buttonStyle(.link)
        }
    }

    private var wallpapers: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundSectionTitle("Wallpapers")
            grid {
                if let wallpaper = editor.capturedWallpaper.flatMap({ editor.images[$0] }) {
                    tile(.windowWallpaper, title: "Captured wallpaper") {
                        Image(decorative: wallpaper, scale: 1).resizable().scaledToFill()
                    }
                }
                tile(.desktop, title: "Desktop") {
                    PictureTileContent(url: desktopPicture, thumbnails: thumbnails, fallbackSymbol: "menubar.dock.rectangle")
                }
                tile(.blurredDesktop, title: "Blurred desktop") {
                    PictureTileContent(url: desktopPicture, thumbnails: thumbnails, fallbackSymbol: "menubar.dock.rectangle")
                        .blur(radius: 3, opaque: true)
                }
                tile(.blurredScreenshot, title: "Blurred screenshot") { SymbolTileContent(symbol: "camera.filters") }
                ForEach(systemWallpapers, id: \.self) { fileName in
                    tile(.systemWallpaper(fileName: fileName), title: Self.title(ofWallpaper: fileName)) {
                        PictureTileContent(url: SystemWallpapers.directory.appending(path: fileName), thumbnails: thumbnails,
                                           fallbackSymbol: "photo")
                    }
                }
                ForEach(customPictures) { entry in
                    tile(.custom(id: entry.id), title: "Your picture") {
                        PictureTileContent(url: entry.url, thumbnails: thumbnails, fallbackSymbol: "photo")
                    }
                    .contextMenu {
                        Button("Remove", role: .destructive) { remove(entry) }
                    }
                }
                Button(action: addPicture) {
                    FillTileFace(isSelected: false) { SymbolTileContent(symbol: "plus") }
                }
                .buttonStyle(.plain)
                .help("Add background…")
                .accessibilityLabel("Add background…")
            }
        }
    }

    private var colors: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundSectionTitle("Colors")
            grid {
                ForEach(BackgroundFill.colorSwatches, id: \.self) { color in
                    tile(.color(color), title: color.hex) { Color(cgColor: color.cgColor) }
                }
                customColor
            }
        }
    }

    /// A color of your own: the background's when it isn't a swatch's, picked in the color popover.
    private var customColor: some View {
        let isSelected = currentFill?.isCustomColor == true
        return Button {
            commands.endTextEditing()
            showingColors.toggle()
        } label: {
            FillTileFace(isSelected: isSelected) {
                if isSelected, case .color(let color)? = currentFill {
                    // A color can be see-through.
                    ZStack {
                        Checkerboard()
                        Color(cgColor: color.cgColor)
                    }
                } else {
                    SymbolTileContent(symbol: "paintpalette")
                }
            }
        }
        .buttonStyle(.plain)
        .help("Custom color")
        .accessibilityLabel("Custom color")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .popover(isPresented: $showingColors, arrowEdge: .leading) {
            ColorPopover(editor: editor, target: .backgroundColor(editor))
        }
    }

    // MARK: Tiles

    private func grid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 8, content: content)
    }

    /// A tile that applies `fill`, outlined while the background has it.
    private func tile<Content: View>(_ fill: BackgroundFill, title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        let isSelected = currentFill == fill
        return Button {
            commands.setFill(fill)
        } label: {
            FillTileFace(isSelected: isSelected, content: content)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// A system wallpaper's name without its extension ("Sequoia Sunrise").
    private static func title(ofWallpaper fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    // MARK: Pictures

    /// The desktop picture of the window's screen, then the system wallpapers and the user's pictures, read off the
    /// main actor: when the panel opens, and again when a picture is added or removed. Not in the body, which runs on
    /// every slider step.
    private func readPictureLists() async {
        desktopPicture = actions.desktopPictureURL()
        let library = actions.backgroundLibrary
        let lists = await Task.detached(priority: .userInitiated) {
            (wallpapers: SystemWallpapers.fileNames(), pictures: library.entries())
        }.value
        systemWallpapers = lists.wallpapers
        customPictures = lists.pictures
    }

    /// Add background…: the picture joins the library and becomes the fill.
    private func addPicture() {
        commands.endTextEditing()
        guard let id = actions.addBackgroundPicture() else { return }
        libraryRevision += 1
        commands.setFill(.custom(id: id))
    }

    /// Remove: the picture leaves the library. A document showing it keeps its own copy, so its tile just isn't outlined
    /// any more.
    private func remove(_ entry: BackgroundLibrary.Entry) {
        actions.removeBackgroundPicture(entry.id)
        libraryRevision += 1
    }
}

/// A fill tile: 40 × 28 pt (narrower when the panel is), corners of 6, a hairline edge so white shows on white, and a
/// 2 pt accent outline while selected.
private struct FillTileFace<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Color.clear
            .frame(height: 28)
            .frame(maxWidth: 40)
            .overlay { content }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
            .overlay {
                if isSelected { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
            }
            .contentShape(shape)
    }
}

/// A tile that is an SF Symbol on a quiet ground.
private struct SymbolTileContent: View {
    let symbol: String

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
    }
}

/// A picture file's thumbnail, made off the main actor once the tile appears; a quiet ground until then, and
/// `fallbackSymbol` when there is no file or it can't be read.
private struct PictureTileContent: View {
    let url: URL?
    let thumbnails: PictureThumbnails
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let url, let image = thumbnails.image(for: url) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else if let url, !thumbnails.hasFailed(url) {
                Rectangle().fill(.quaternary)
            } else {
                SymbolTileContent(symbol: fallbackSymbol)
            }
        }
        .task(id: url) {
            if let url { await thumbnails.load(url) }
        }
    }
}

/// The wallpaper tiles' small pictures, by file (`PictureThumbnail`): made off the main actor as the tiles appear, and kept
/// for as long as the panel is open. A file that can't be read isn't tried again.
@MainActor @Observable private final class PictureThumbnails {
    private var images: [URL: CGImage] = [:]
    private var failed: Set<URL> = []
    @ObservationIgnored private var requested: Set<URL> = []

    func image(for url: URL) -> CGImage? {
        images[url]
    }

    func hasFailed(_ url: URL) -> Bool {
        failed.contains(url)
    }

    func load(_ url: URL) async {
        guard requested.insert(url).inserted else { return }
        let image = await Task.detached(priority: .userInitiated) { PictureThumbnail.make(at: url) }.value
        if let image {
            images[url] = image
        } else {
            failed.insert(url)
        }
    }
}

/// A catalog gradient as its tile shows it: linear at its angle across the tile, radial from the centre to the corners,
/// as `Renderer.drawGradient` draws it across the frame.
private struct GradientPreview: View {
    let gradient: BackgroundGradient

    var body: some View {
        Canvas { context, size in
            let stops = gradient.stops.map { Gradient.Stop(color: Color(cgColor: $0.color.cgColor), location: $0.location) }
            let rect = CGRect(origin: .zero, size: size)
            let centre = CGPoint(x: rect.midX, y: rect.midY)
            let shading: GraphicsContext.Shading
            switch gradient.kind {
            case .linear(let angle):
                let radians = angle * .pi / 180
                let direction = CGPoint(x: cos(radians), y: sin(radians))
                let half = (abs(size.width * direction.x) + abs(size.height * direction.y)) / 2
                shading = .linearGradient(Gradient(stops: stops),
                                          startPoint: CGPoint(x: centre.x - half * direction.x, y: centre.y - half * direction.y),
                                          endPoint: CGPoint(x: centre.x + half * direction.x, y: centre.y + half * direction.y))
            case .radial:
                shading = .radialGradient(Gradient(stops: stops), center: centre, startRadius: 0,
                                          endRadius: hypot(size.width, size.height) / 2)
            }
            context.fill(Path(rect), with: shading)
        }
    }
}

/// Transparency, as the canvas shows it: white and light gray squares.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 4
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            var path = Path()
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in stride(from: row % 2, to: Int((size.width / square).rounded(.up)), by: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(Color(white: 0.85)))
        }
    }
}
