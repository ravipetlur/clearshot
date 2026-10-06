/// A recording's elapsed time as the control bar and the menu bar show it: "0:07", "12:34", "1:02:03".
public enum ElapsedText {
    /// Whole seconds, rounded down; a negative time reads as zero.
    public static func string(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let (hours, minutes, secs) = (total / 3600, total / 60 % 60, total % 60)
        let twoDigitSeconds = secs < 10 ? "0\(secs)" : "\(secs)"
        guard hours > 0 else { return "\(minutes):\(twoDigitSeconds)" }
        let twoDigitMinutes = minutes < 10 ? "0\(minutes)" : "\(minutes)"
        return "\(hours):\(twoDigitMinutes):\(twoDigitSeconds)"
    }
}
