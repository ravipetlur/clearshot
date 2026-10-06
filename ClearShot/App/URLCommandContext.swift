import CSCore

/// The URL command a piece of work runs for, so a refusal deep in the capture flow ("A capture is already in progress")
/// or the modal gate names the command and its sender in the API log. The router binds it around a command's dispatch,
/// and the tasks the command starts inherit it; a capture that does start clears it for its own work
/// (`CaptureFlow.run`), so later refusals inside a recording or its thumbnails aren't put down to the URL.
enum URLCommandContext {
    @TaskLocal static var label: String?

    /// Logs a refusal against the URL command this work runs for; a hotkey's, the menu's and the like aren't logged here.
    static func logRefusal(_ message: String) {
        guard let label else { return }
        Log.api.info("\(label): refused, \(message)")
    }
}
