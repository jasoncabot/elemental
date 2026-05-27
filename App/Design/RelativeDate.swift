import Foundation

/// Human-first relative date formatting for the timeline ("2h ago", "Yesterday").
/// The brief asks the timeline to optimize for skim reading, so commits lead with
/// approximate recency; the exact timestamp is reserved for hover/expanded metadata.
enum RelativeDate {

    static func short(_ date: Date, now: Date = Date()) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 0 { return "just now" }
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86_400 {
            let cal = Calendar.current
            if cal.isDateInToday(date) { return "\(Int(seconds / 3600))h ago" }
        }
        let cal = Calendar.current
        if cal.isDateInYesterday(date) { return "Yesterday" }
        let days = Int(seconds / 86_400)
        if days < 7 { return "\(days)d ago" }
        if days < 365 { return weekdayMonthFormatter.string(from: date) }
        return yearFormatter.string(from: date)
    }

    static func exact(_ date: Date) -> String {
        exactFormatter.string(from: date)
    }

    private static let weekdayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static let yearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        return f
    }()

    private static let exactFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
