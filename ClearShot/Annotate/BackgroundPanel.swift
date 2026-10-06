import CSAnnotation
import SwiftUI

/// The background's style. SwiftUI has a `BackgroundStyle` of its own.
private typealias Style = CSAnnotation.BackgroundStyle

/// The Background tool's panel: a sidebar right of the canvas, shown while `AnnotationEditor.isBackgroundPanelOpen`.
/// Top to bottom: the header with the preset menu, the fills, the sliders with their fields and the inset color,
/// Auto-balance, alignment, ratio and Remove background.
///
/// Crop & Resize shows the content alone, so while it is on the panel only says so and nothing in it works. Without a
/// background (after ⌘Z, with the panel still open) only what sets a whole style works: the fills, the presets and Apply
/// Previous Settings.
struct BackgroundPanel: View {
    @Bindable var editor: AnnotationEditor
    let actions: EditorActions

    private var commands: BackgroundCommands {
        BackgroundCommands(editor: editor, actions: actions)
    }

    /// The background's style, or what a fill click would apply without one (the disabled controls show it).
    private var style: Style {
        editor.document.background?.style ?? editor.defaultBackgroundStyle
    }

    var body: some View {
        let isCropping = editor.crop != nil
        let hasBackground = editor.document.background != nil
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                header
                    .disabled(isCropping)
                if isCropping {
                    Text("Finish cropping to edit the background.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Everything that changes the background.
                VStack(alignment: .leading, spacing: 12) {
                    BackgroundFillPicker(editor: editor, actions: actions, commands: commands)
                    // What edits the style needs a style to edit.
                    VStack(alignment: .leading, spacing: 12) {
                        values
                        Toggle("Auto-balance", isOn: Binding(get: { style.autoBalance }, set: { on in
                            commands.perform { editor.updateBackgroundStyle("Change Auto-Balance") { $0.autoBalance = on } }
                        }))
                        .help("Trims even margins off the picture first, so the padding around it looks even")
                        alignment
                        ratio
                        Button("Remove background") {
                            commands.perform { editor.removeBackground() }
                        }
                    }
                    .disabled(!hasBackground)
                }
                .disabled(isCropping)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Background", the matching preset's name beneath (or "Custom"), and the preset menu.
    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Background")
                    .font(.headline)
                Text(presetCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            BackgroundPresetMenu(editor: editor, commands: commands)
        }
    }

    private var presetCaption: String {
        guard editor.document.background != nil else { return "No background" }
        return editor.matchingPreset?.name ?? "Custom"
    }

    // MARK: Sliders

    private var values: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundValueRow(title: "Padding", actionName: "Change Padding", range: Style.paddingRange,
                               value: \.padding, editor: editor, commands: commands)
            BackgroundValueRow(title: "Inset", actionName: "Change Inset", range: Style.insetRange,
                               value: \.inset, editor: editor, commands: commands)
            InsetColorRow(editor: editor, commands: commands)
            BackgroundValueRow(title: "Shadow", actionName: "Change Shadow", range: Style.shadowRange,
                               value: \.shadow, editor: editor, commands: commands)
            BackgroundValueRow(title: "Corners", actionName: "Change Corners", range: Style.cornersRange,
                               value: \.corners, editor: editor, commands: commands)
        }
    }

    // MARK: Alignment and ratio

    /// Where the picture sits when the frame has room to spare: nine positions, the chosen one filled.
    private var alignment: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundSectionTitle("Alignment")
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 4), count: 3), spacing: 4) {
                ForEach(BackgroundAlignment.allCases, id: \.self) { position in
                    let isSelected = style.alignment == position
                    Button {
                        commands.perform { editor.updateBackgroundStyle("Change Alignment") { $0.alignment = position } }
                    } label: {
                        Image(systemName: isSelected ? "circle.fill" : "circle")
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .help(position.title)
                    .accessibilityLabel(position.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .fixedSize()
            .padding(4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }

    /// The frame's shape.
    private var ratio: some View {
        VStack(alignment: .leading, spacing: 8) {
            BackgroundSectionTitle("Ratio")
            Picker("Ratio", selection: Binding(get: { style.ratio }, set: { ratio in
                commands.perform { editor.updateBackgroundStyle("Change Ratio") { $0.ratio = ratio } }
            })) {
                ForEach(BackgroundRatio.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// How the Background panel's controls change the background: inline text editing ends first, since its open live change
/// would ignore a background command, or take in a style edit as part of the text's. Like the Edit menu's canvas commands,
/// a change made in the same event as that end can share its undo step. (`AnnotationEditor.asOneUndoStep` would keep them
/// apart, but leaves a step that undoes nothing whenever the change turns out to be none, as a click on what is already
/// chosen is.)
struct BackgroundCommands {
    let editor: AnnotationEditor
    let actions: EditorActions

    func endTextEditing() {
        actions.endTextEditing()
    }

    /// A click or a typed value: `change`, once text editing has ended.
    func perform(_ change: () -> Void) {
        actions.endTextEditing()
        change()
    }

    /// A whole style (a fill, a preset, Previous Settings), applied by `apply` once its picture is had, from the pictures
    /// of the window's screen. Nothing shows meanwhile, the panel stays usable, and a newer click wins (the editor's request
    /// counter).
    func applyStyle(_ apply: @escaping @MainActor (AnnotationEditor, BackgroundPictureSource) async -> Void) {
        actions.endTextEditing()
        let pictures = actions.backgroundPictures()
        Task { await apply(editor, pictures) }
    }

    /// A fill tile's click.
    func setFill(_ fill: BackgroundFill) {
        applyStyle { await $0.setBackgroundFill(fill, pictures: $1) }
    }
}

/// A group's title in the Background panel.
struct BackgroundSectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }
}

/// The width of a slider's label, so the sliders line up.
private let valueLabelWidth: CGFloat = 56

/// One of the background's numbers: a slider, whose drag is one undo step, and a field for a whole number, which
/// commits on Return or when it loses focus, as one undo step, clamped. The field shows the value until something is
/// typed, and Esc takes back what was typed.
private struct BackgroundValueRow: View {
    let title: String
    let actionName: String
    let range: ClosedRange<Double>
    let value: WritableKeyPath<Style, Double>
    @Bindable var editor: AnnotationEditor
    let commands: BackgroundCommands
    /// What has been typed and not yet committed; nil while the field shows the value.
    @State private var typed: String?
    @FocusState private var isFocused: Bool
    @Environment(\.isEnabled) private var isEnabled

    private var current: Double {
        (editor.document.background?.style ?? editor.defaultBackgroundStyle)[keyPath: value]
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .frame(width: valueLabelWidth, alignment: .leading)
            // A drag is a live change the editor records as one step when it ends. Without one (the arrow keys) the
            // steps coalesce.
            Slider(value: Binding(get: { current }, set: { newValue in
                commands.endTextEditing()
                editor.updateBackgroundStyle(actionName, coalescing: true) { $0[keyPath: value] = newValue.rounded() }
            }), in: range, label: { Text(title) }, onEditingChanged: { began in
                if began {
                    commands.endTextEditing()
                    // The drag sets the value: text typed and not committed would otherwise undo it when the field
                    // loses focus.
                    typed = nil
                }
                editor.sliderEditingChanged(began, actionName: actionName)
            })
            .labelsHidden()
            TextField(title, text: Binding(get: { typed ?? Self.display(current) }, set: { typed = $0 }))
                .labelsHidden()
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 52)
                .focused($isFocused)
                .onSubmit(commit)
                .onExitCommand { typed = nil }
                .onChange(of: isFocused) {
                    if !isFocused { commit() }
                }
                .onDisappear(perform: commit)
        }
    }

    private static func display(_ value: Double) -> String {
        String(Int(value.rounded()))
    }

    /// The typed text as one undo step, clamped. Text that isn't a number, or says the value already there, changes
    /// nothing, and the field goes back to showing the value.
    private func commit() {
        guard let text = typed else { return }
        typed = nil
        guard let newValue = Style.typedValue(text, in: range), newValue != current else { return }
        commands.perform { editor.updateBackgroundStyle(actionName) { $0[keyPath: value] = newValue } }
    }
}

/// Under Inset: what fills it, the picture's own edge color (Auto) or a color of your own from the color popover.
private struct InsetColorRow: View {
    @Bindable var editor: AnnotationEditor
    let commands: BackgroundCommands
    @State private var showingColors = false

    private enum Mode: Hashable {
        case auto, color
    }

    private var insetColor: InsetColor {
        (editor.document.background?.style ?? editor.defaultBackgroundStyle).insetColor
    }

    private var mode: Binding<Mode> {
        Binding(get: {
            if case .color = insetColor { .color } else { .auto }
        }, set: { mode in
            // Color starts from white, as the canvas fill's does.
            let insetColor: InsetColor = mode == .auto ? .auto : .color(.white)
            commands.perform { editor.updateBackgroundStyle("Change Inset Color") { $0.insetColor = insetColor } }
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: valueLabelWidth, height: 1)
            Picker("Inset color", selection: mode) {
                Text("Auto").tag(Mode.auto)
                Text("Color").tag(Mode.color)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What fills the inset: the picture's edge color, or a color of your own")
            if case .color(let color) = insetColor {
                Button {
                    commands.endTextEditing()
                    showingColors.toggle()
                } label: {
                    Swatch(color: color, size: 16)
                }
                .buttonStyle(.borderless)
                .help("Inset color")
                .accessibilityLabel("Inset color: \(ColorPalette.name(for: color))")
                .popover(isPresented: $showingColors, arrowEdge: .leading) {
                    ColorPopover(editor: editor, target: .insetColor(editor))
                }
            }
        }
    }
}

private extension BackgroundAlignment {
    /// "Top left" … "Bottom right", for the alignment buttons' help.
    var title: String {
        switch self {
        case .topLeft: "Top left"
        case .top: "Top"
        case .topRight: "Top right"
        case .left: "Left"
        case .center: "Center"
        case .right: "Right"
        case .bottomLeft: "Bottom left"
        case .bottom: "Bottom"
        case .bottomRight: "Bottom right"
        }
    }
}
