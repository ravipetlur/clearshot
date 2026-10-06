import AppKit
import CSAnnotation
import CSCore
import SwiftUI

/// What a color popover edits: the drawing color (the selection and the next shape), the canvas fill, or the
/// background's color fill or inset color.
struct ColorTarget {
    /// The color shown as current.
    var color: () -> RGBAColor
    /// One pick: a palette or My Colors swatch, the eyedropper, a typed hex.
    var pick: (RGBAColor) -> Void
    /// A stream of picks (the color panel's wheel), which coalesces into one undo step.
    var stream: (RGBAColor) -> Void
    /// Each step of the opacity slider.
    var slide: (RGBAColor) -> Void
    /// The opacity slider's drag began (true) or ended (false).
    var sliderEditingChanged: (Bool) -> Void

    /// The drawing color. A slider drag is one undo step through the editor's slider gate.
    static func drawing(_ editor: AnnotationEditor) -> ColorTarget {
        ColorTarget(color: { editor.settings.color },
                    pick: { editor.setColor($0) },
                    stream: { editor.setColor($0, coalescing: true) },
                    slide: { editor.setColor($0) },
                    sliderEditingChanged: { editor.sliderEditingChanged($0, actionName: "Change Color") })
    }

    /// The canvas fill. It is a canvas change, so a slider drag coalesces instead of using the live change.
    static func canvasFill(_ editor: AnnotationEditor) -> ColorTarget {
        ColorTarget(color: { editor.canvasFillColor },
                    pick: { editor.setCanvasFill(.color($0)) },
                    stream: { editor.setCanvasFill(.color($0), coalescing: true) },
                    slide: { editor.setCanvasFill(.color($0), coalescing: true) },
                    sliderEditingChanged: { _ in })
    }

    /// The background's color fill: the current color fill, else white. With a background a pick restyles it, and a stream
    /// or a slider drag coalesces into one undo step, as the canvas fill does. Without one (after ⌘Z, with the panel still
    /// open) a pick applies the color as a whole style, as a fill click does.
    static func backgroundColor(_ editor: AnnotationEditor) -> ColorTarget {
        func set(_ color: RGBAColor, coalescing: Bool) {
            if editor.document.background != nil {
                editor.updateBackgroundStyle("Change Background", coalescing: coalescing) { $0.fill = .color(color) }
            } else {
                Task { await editor.setBackgroundFill(.color(color), pictures: .none) }
            }
        }
        return ColorTarget(color: {
                               if case .color(let color) = editor.document.background?.style.fill { color } else { .white }
                           },
                           pick: { set($0, coalescing: false) },
                           stream: { set($0, coalescing: true) },
                           slide: { set($0, coalescing: true) },
                           sliderEditingChanged: { _ in })
    }

    /// The background's inset color: the current one, else white. A stream or a slider drag coalesces into one undo step.
    /// Nothing happens without a background (the panel's inset controls are off then).
    static func insetColor(_ editor: AnnotationEditor) -> ColorTarget {
        func set(_ color: RGBAColor, coalescing: Bool) {
            editor.updateBackgroundStyle("Change Inset Color", coalescing: coalescing) { $0.insetColor = .color(color) }
        }
        return ColorTarget(color: {
                               if case .color(let color) = editor.document.background?.style.insetColor { color } else { .white }
                           },
                           pick: { set($0, coalescing: false) },
                           stream: { set($0, coalescing: true) },
                           slide: { set($0, coalescing: true) },
                           sliderEditingChanged: { _ in })
    }
}

/// The current color as a swatch (with its name when "Show color names" is on), opening the color popover.
struct ColorButton: View {
    @Bindable var editor: AnnotationEditor
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            HStack(spacing: 8) {
                Swatch(color: editor.settings.color, size: 16)
                if editor.preferences[Prefs.annotateShowColorNames] {
                    Text(ColorPalette.name(for: editor.settings.color))
                }
            }
        }
        .buttonStyle(.borderless)
        .help("Color")
        .accessibilityLabel("Color: \(ColorPalette.name(for: editor.settings.color))")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ColorPopover(editor: editor, target: .drawing(editor))
        }
    }
}

/// The palette, Hex, opacity, the system color panel with its wheel and eyedropper, and My Colors, for whatever
/// `target` edits.
struct ColorPopover: View {
    @Bindable var editor: AnnotationEditor
    let target: ColorTarget
    @State private var hex = ""

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(44), spacing: 8), count: 7)
    }

    private var myColors: [RGBAColor] {
        editor.preferences[Prefs.annotateMyColors].colors
    }

    var body: some View {
        let current = target.color()
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(ColorPalette.standard) { named in
                    Button {
                        target.pick(named.color)
                    } label: {
                        VStack(spacing: 4) {
                            Swatch(color: named.color, size: 22, selected: named.color == current)
                            if editor.preferences[Prefs.annotateShowColorNames] {
                                Text(named.name).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help(named.name)
                    .accessibilityLabel(named.name)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("My Colors").font(.callout).foregroundStyle(.secondary)
                // Laid out like the palette, so any number of saved colors wraps instead of running off the popover.
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Array(myColors.enumerated()), id: \.offset) { index, color in
                        Button {
                            target.pick(color)
                        } label: {
                            Swatch(color: color, size: 22, selected: color == current)
                        }
                        .buttonStyle(.plain)
                        .help(color.hex)
                        .accessibilityLabel(ColorPalette.name(for: color))
                        .contextMenu {
                            Button("Update to Current Color") { updateMyColor(at: index) }
                            Button("Delete", role: .destructive) { deleteMyColor(at: index) }
                        }
                    }
                    Button {
                        addMyColor()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Add the current color to My Colors")
                    .accessibilityLabel("Add the current color to My Colors")
                }
            }
            Divider()
            HStack(spacing: 8) {
                TextField("Hex", text: $hex)
                    .font(.body.monospaced())
                    .frame(width: 96)
                    .onSubmit { commitHex() }
                // The whole drag is one undo step, and for the drawing color one that starts while text is being typed
                // joins that edit.
                Slider(value: Binding(get: { target.color().alpha }, set: { target.slide(target.color().withAlpha($0)) }),
                       in: 0.05...1, label: { Text("Opacity") },
                       onEditingChanged: { target.sliderEditingChanged($0) })
                    .frame(width: 140)
                Button {
                    // The sampler keeps itself alive until the pick completes or is cancelled.
                    NSColorSampler().show { picked in
                        guard let picked, let color = RGBAColor(picked.cgColor) else { return }
                        Task { @MainActor in target.pick(color) }
                    }
                } label: {
                    Image(systemName: "eyedropper")
                }
                .buttonStyle(.borderless)
                .help("Pick a color from the screen")
                .accessibilityLabel("Pick a color from the screen")
                // The panel and its wheel send a change per step of a drag; they coalesce into one undo step.
                ColorPicker("More", selection: Binding(get: { Color(cgColor: target.color().cgColor) }, set: { picked in
                    if let color = RGBAColor(NSColor(picked).cgColor) { target.stream(color) }
                }), supportsOpacity: true)
                .labelsHidden()
                .help("Color wheel and more")
            }
        }
        .padding(16)
        .frame(width: 388)
        .onAppear { hex = current.hex }
        .onChange(of: current) { _, color in hex = color.hex }
        .onDisappear { commitHex() }
    }

    /// Applies the typed hex as submitting it would. A 6-digit hex keeps the current opacity, an 8-digit one sets its own.
    /// Text that isn't a color returns to the current color's hex. Text left as it was shown changes nothing: the hex
    /// rounds the opacity to a byte, and parsing it back would nudge it.
    private func commitHex() {
        let current = target.color()
        guard hex != current.hex else { return }
        if let color = RGBAColor(hex: hex, defaultAlpha: current.alpha) { target.pick(color) }
        hex = target.color().hex
    }

    private func addMyColor() {
        var saved = editor.preferences[Prefs.annotateMyColors]
        saved.add(target.color())
        editor.preferences[Prefs.annotateMyColors] = saved
    }

    private func updateMyColor(at index: Int) {
        var saved = editor.preferences[Prefs.annotateMyColors]
        saved.update(at: index, to: target.color())
        editor.preferences[Prefs.annotateMyColors] = saved
    }

    private func deleteMyColor(at index: Int) {
        var saved = editor.preferences[Prefs.annotateMyColors]
        saved.remove(at: index)
        editor.preferences[Prefs.annotateMyColors] = saved
    }
}

struct Swatch: View {
    let color: RGBAColor
    let size: CGFloat
    var selected = false

    var body: some View {
        Circle()
            .fill(Color(cgColor: color.cgColor))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25)))
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-4))
            .frame(width: size, height: size)
    }
}
