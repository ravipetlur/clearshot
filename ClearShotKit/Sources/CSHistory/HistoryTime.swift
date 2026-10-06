import Foundation

/// The time label under a History cell.
public enum HistoryTime {
    /// "Just now" under a minute (a date in the future too, from a clock change), else the relative time in full words:
    /// "5 minutes ago", "3 hours ago", "1 day ago".
    public static func label(for date: Date, now: Date, locale: Locale = .current) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        formatter.locale = locale
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
