import CSAnnotation
import CSCore
import SwiftUI

extension ColorTarget {
    /// The fill of rectangles and ellipses. Its opacity is the fill opacity (the popover's slider and the bar's are the
    /// same one), and the color it hands back is the fill's own, always opaque.
    static func fill(_ editor: AnnotationEditor) -> ColorTarget {
        ColorTarget(color: { (editor.settings.fillColor ?? editor.settings.color).withAlpha(editor.settings.fillOpacity) },
                    pick: { editor.setFillColor($0.withAlpha(1)) },
                    stream: { editor.setFillColor($0.withAlpha(1), coalescing: true) },
                    slide: { editor.setFillOpacity($0.alpha) },
                    sliderEditingChanged: { editor.sliderEditingChanged($0, actionName: "Change Fill") })
    }
}

/// The fill of a rectangle or an ellipse: a color well (the color popover) and an opacity slider, 0 being no fill.
struct FillControl: View {
    @Bindable var editor: AnnotationEditor
    @State private var showing = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showing.toggle()
            } label: {
                HStack(spacing: 6) {
                    Swatch(color: editor.settings.fillColor ?? editor.settings.color, size: 16)
                    Text("Fill")
                }
            }
            .buttonStyle(.borderless)
            .help("Fill color")
            .accessibilityLabel("Fill color")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                ColorPopover(editor: editor, target: .fill(editor))
            }
            Slider(value: Binding(get: { editor.settings.fillOpacity }, set: { editor.setFillOpacity($0) }), in: 0...1,
                   label: { Text("Fill opacity") },
                   onEditingChanged: { editor.sliderEditingChanged($0, actionName: "Change Fill") })
                .frame(width: 100)
                .help("Fill opacity (0 is no fill)")
        }
    }
}
