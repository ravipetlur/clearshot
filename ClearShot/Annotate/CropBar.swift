import CSAnnotation
import SwiftUI

/// Crop & Resize's bar: ratio, the crop's size, the canvas fill, rotate and flip, Resize…, Revert to Original, Cancel
/// and Apply. Return and Esc reach the canvas, which applies or cancels; in a Custom W:H field, Esc cancels too, and
/// Return applies the ratio and hands the keyboard back to the canvas.
struct CropBar: View {
    @Bindable var editor: AnnotationEditor
    let resize: () -> Void
    /// Hands the keyboard back to the canvas, where Return applies the crop and Esc cancels it.
    let focusCanvas: () -> Void
    @State private var customWidth = 16.0
    @State private var customHeight = 9.0

    var body: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(CropRatio.presets, id: \.self) { ratio in
                    Button(ratio.title) { editor.setCropRatio(ratio) }
                }
                Divider()
                Button("Custom") { applyCustomRatio() }
            } label: {
                Text(editor.crop?.ratio.title ?? CropRatio.freeform.title)
            }
            .fixedSize()
            .help("Aspect ratio")
            if case .some(.custom) = editor.crop?.ratio {
                HStack(spacing: 4) {
                    TextField("Width", value: $customWidth, format: .number)
                        .labelsHidden()
                        .frame(width: 48)
                        .onSubmit { submitCustomRatio() }
                        .onExitCommand { editor.cancelCrop() }
                    Text(":")
                    TextField("Height", value: $customHeight, format: .number)
                        .labelsHidden()
                        .frame(width: 48)
                        .onSubmit { submitCustomRatio() }
                        .onExitCommand { editor.cancelCrop() }
                }
            }
            if let rect = editor.crop?.rect {
                Text("\(Int(rect.width)) × \(Int(rect.height))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("The crop's size in pixels")
            }
            CanvasFillControl(editor: editor)
            HStack(spacing: 4) {
                Button { editor.rotateLeft() } label: { Image(systemName: "rotate.left") }
                    .help("Rotate Left (⌥⌘L)")
                    .accessibilityLabel("Rotate Left")
                Button { editor.rotateRight() } label: { Image(systemName: "rotate.right") }
                    .help("Rotate Right (⌥⌘R)")
                    .accessibilityLabel("Rotate Right")
                Button { editor.flipHorizontally() } label: {
                    Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                .help("Flip Horizontal")
                .accessibilityLabel("Flip Horizontal")
                Button { editor.flipVertically() } label: {
                    Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                }
                .help("Flip Vertical")
                .accessibilityLabel("Flip Vertical")
            }
            .buttonStyle(.borderless)
            Button("Resize…", action: resize)
                .help("Resize Image… (⌥⌘I)")
            Button("Revert to original") { editor.revertToOriginal() }
                .disabled(!editor.document.canRevertToOriginal)
            Spacer()
            Button("Cancel") { editor.cancelCrop() }
                .help("Cancel (Esc)")
            Button("Apply") { editor.applyCrop() }
                .buttonStyle(.borderedProminent)
                .help("Apply (Return)")
        }
    }

    /// Return in a Custom W:H field: the ratio applies, and the next Return (on the canvas) applies the crop.
    private func submitCustomRatio() {
        applyCustomRatio()
        focusCanvas()
    }

    /// Custom W:H. A side that isn't a positive number leaves the ratio as it is.
    private func applyCustomRatio() {
        guard customWidth.isFinite, customHeight.isFinite, customWidth > 0, customHeight > 0 else { return }
        editor.setCropRatio(.custom(width: customWidth, height: customHeight))
    }
}

/// What fills the canvas outside the picture: the picture's edge color (Auto), nothing (Transparent, shown as a
/// checkerboard), or a color of your own from the color popover.
struct CanvasFillControl: View {
    @Bindable var editor: AnnotationEditor
    @State private var showingColors = false

    private enum Choice: Hashable {
        case auto, transparent, color
    }

    private var choice: Binding<Choice> {
        Binding(get: {
            switch editor.document.canvasFill {
            case .auto: .auto
            case .transparent: .transparent
            case .color: .color
            }
        }, set: { choice in
            switch choice {
            case .auto: editor.setCanvasFill(.auto)
            case .transparent: editor.setCanvasFill(.transparent)
            case .color: editor.setCanvasFill(.color(editor.canvasFillColor))
            }
        })
    }

    var body: some View {
        HStack(spacing: 4) {
            Picker("Background", selection: choice) {
                Text("Auto").tag(Choice.auto)
                Text("Transparent").tag(Choice.transparent)
                Text("Color").tag(Choice.color)
            }
            .fixedSize()
            .help("What fills the canvas outside the picture")
            if case .color = editor.document.canvasFill {
                Button {
                    showingColors.toggle()
                } label: {
                    Swatch(color: editor.canvasFillColor, size: 16)
                }
                .buttonStyle(.borderless)
                .help("Background color")
                .accessibilityLabel("Background color: \(ColorPalette.name(for: editor.canvasFillColor))")
                .popover(isPresented: $showingColors, arrowEdge: .bottom) {
                    ColorPopover(editor: editor, target: .canvasFill(editor))
                }
            }
        }
    }
}
