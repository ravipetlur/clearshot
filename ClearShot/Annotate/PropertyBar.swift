import CSAnnotation
import CSCore
import SwiftUI

/// Controls for the current tool, or for the selected object: color, size and the tool's own options. In Crop & Resize
/// it is the crop bar instead.
struct PropertyBar: View {
    @Bindable var editor: AnnotationEditor
    let actions: EditorActions

    var body: some View {
        Group {
            if editor.tool == .crop {
                CropBar(editor: editor, resize: actions.resize, focusCanvas: actions.focusCanvas)
            } else {
                styleControls
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: editor.selection) {
            if editor.selection.count == 1, let object = editor.selectedObjects.first { editor.adoptStyle(of: object) }
        }
    }

    /// Whether the one selected object is an image, which has no color or line size, and the Select tool is what is being
    /// used. Under a drawing tool an image can stay selected (after Add Image or ⌘V), and the next stroke still needs the
    /// color and size.
    private var selectionIsImage: Bool {
        guard editor.tool == .select, editor.selection.count == 1, let object = editor.selectedObjects.first,
              case .image = object.kind else { return false }
        return true
    }

    private var styleControls: some View {
        let context = editor.styleContext
        return HStack(spacing: 12) {
            // Redactions, spotlights and images have no color or line size, and redactions, spotlights and highlights cast
            // no shadow.
            if context != .redact, context != .spotlight, !selectionIsImage {
                ColorButton(editor: editor)
                SizePicker(level: editor.settings.sizeLevel) { editor.setSizeLevel($0) }
            }
            options
            Spacer()
            if context != .redact, context != .spotlight, context != .highlighter {
                Toggle("Shadow", isOn: Binding(get: { editor.preferences[Prefs.annotateObjectShadows] }, set: { editor.setShadows($0) }))
                    .toggleStyle(.checkbox)
            }
        }
    }

    /// A slider drag restyles the selection as one undo step (see `AnnotationEditor.sliderEditingChanged`).
    private func dragging(_ actionName: String) -> (Bool) -> Void {
        { editor.sliderEditingChanged($0, actionName: actionName) }
    }

    @ViewBuilder
    private var options: some View {
        switch editor.styleContext {
        case .arrow:
            Picker("Style", selection: Binding(get: { editor.settings.arrowStyle }, set: { editor.setArrowStyle($0) })) {
                ForEach(ArrowStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
        case .text:
            Picker("Style", selection: Binding(get: { editor.settings.textStyle }, set: { editor.setTextStyle($0) })) {
                ForEach(TextStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Button {
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "face.smiling")
            }
            .buttonStyle(.borderless)
            .help("Emoji & Symbols")
            .accessibilityLabel("Emoji & Symbols")
        case .redact:
            Picker("Style", selection: Binding(get: { editor.settings.redactStyle }, set: { editor.setRedactStyle($0) })) {
                ForEach(RedactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Slider(value: Binding(get: { Double(editor.settings.redactIntensity) }, set: { editor.setRedactIntensity(Int($0.rounded())) }),
                   in: 1...10, step: 1, label: { Text("Intensity") }, onEditingChanged: dragging("Change Intensity"))
                .frame(width: 120)
                .help("Intensity ([ and ])")
        case .spotlight:
            Picker("Shape", selection: Binding(get: { editor.settings.spotlightShape }, set: { editor.setSpotlightShape($0) })) {
                ForEach(SpotlightShape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Slider(value: Binding(get: { editor.settings.spotlightOpacity }, set: { editor.setSpotlightOpacity($0) }), in: 0.1...0.95,
                   label: { Text("Opacity") }, onEditingChanged: dragging("Change Spotlight"))
                .frame(width: 120)
        case .counter:
            Picker("Style", selection: Binding(get: { editor.settings.counterStyle }, set: { editor.setCounterStyle($0) })) {
                ForEach(CounterStyle.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Stepper("Starts at \(editor.settings.counterStart)",
                    value: Binding(get: { editor.settings.counterStart }, set: { editor.setCounterStart($0) }), in: 0...999)
                .fixedSize()
        case .highlighter:
            Toggle("Smart", isOn: Binding(get: { editor.settings.smartHighlighter }, set: { editor.setSmartHighlighter($0) }))
                .toggleStyle(.checkbox)
                .help("Snap to the words under the stroke. Hold ⌘ to draw freehand.")
            Slider(value: Binding(get: { editor.settings.highlightOpacity }, set: { editor.setHighlightOpacity($0) }), in: 0.1...0.9,
                   label: { Text("Opacity") }, onEditingChanged: dragging("Change Highlight"))
                .frame(width: 120)
        case .pen:
            Toggle("Smooth", isOn: Binding(get: { editor.preferences[Prefs.annotateSmoothDrawing] }, set: { editor.setSmoothDrawing($0) }))
                .toggleStyle(.checkbox)
        default:
            EmptyView()
        }
    }
}

/// Six sizes as dots of growing size (keys 1–6).
struct SizePicker: View {
    let level: Int
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(ToolSizes.levels), id: \.self) { candidate in
                Button {
                    select(candidate)
                } label: {
                    Circle()
                        .frame(width: CGFloat(3 + candidate * 2), height: CGFloat(3 + candidate * 2))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(candidate == level ? Color.accentColor : Color.secondary)
                .help("Size \(candidate)")
            }
        }
    }
}
