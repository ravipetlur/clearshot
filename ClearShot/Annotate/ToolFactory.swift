import CSAnnotation

/// The controller behind each tool.
enum ToolFactory {
    static func make(_ tool: EditorTool, canvas: AnnotationCanvasView) -> ToolController {
        let editor = canvas.editor
        return switch tool {
        case .select: canvas.selectTool
        case .text: TextTool(editor: editor, canvas: canvas)
        case .rectangle: ShapeTool(.rectangle, editor: editor, canvas: canvas)
        case .filledRectangle: ShapeTool(.filledRectangle, editor: editor, canvas: canvas)
        case .ellipse: ShapeTool(.ellipse, editor: editor, canvas: canvas)
        case .redact: ShapeTool(.redact, editor: editor, canvas: canvas)
        case .spotlight: ShapeTool(.spotlight, editor: editor, canvas: canvas)
        case .line: LineTool(arrow: false, editor: editor, canvas: canvas)
        case .arrow: LineTool(arrow: true, editor: editor, canvas: canvas)
        case .pen: PenTool(editor: editor, canvas: canvas)
        case .highlighter: HighlighterTool(editor: editor, canvas: canvas)
        case .counter: CounterTool(editor: editor)
        case .crop: CropTool(editor: editor, canvas: canvas)
        }
    }
}
