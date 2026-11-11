import CSAnnotation
import SwiftUI

/// The magnifier's options in the property bar: its shape, its border and, with one magnifier selected, its zoom.
struct MagnifierControls: View {
    @Bindable var editor: AnnotationEditor

    var body: some View {
        Picker("Shape", selection: Binding(get: { editor.settings.magnifierShape }, set: { editor.setMagnifierShape($0) })) {
            ForEach(MagnifierShape.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .fixedSize()
        Toggle("Border", isOn: Binding(get: { editor.settings.magnifierBorder }, set: { editor.setMagnifierBorder($0) }))
            .toggleStyle(.checkbox)
        if let magnifier = editor.selectedMagnifier {
            let zoom = magnifier.zoom
            Stepper("Zoom \(zoom.formatted(.number.precision(.fractionLength(0...1))))×",
                    value: Binding(get: { zoom }, set: { editor.setMagnifierZoom($0) }),
                    in: MagnifierObject.zoomRange, step: 1)
                .fixedSize()
                .help("How much the callout magnifies, 2× to 8×")
        }
    }
}
