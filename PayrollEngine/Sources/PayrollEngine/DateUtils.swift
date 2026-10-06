import Foundation

/// Date helpers built on a fixed local calendar (never `Date.now`'s implicit UTC formatting)
/// so a calendar-date string never shifts by a day the way `Date().toISOString()` did in the
/// original JS version when run in JST — that was a real, since-fixed bug there.
public enum DateUtils {
    /// A calendar pinned to the current time zone — every date string in this engine goes
    /// through this, never through a UTC-based formatter.
    public static var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal
    }

    /// "YYYY-MM-DD" for `date`, in local time.
    public static func ymd(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func todayYMD() -> String { ymd(Date()) }

    /// Parses a "YYYY-MM-DD" string into (year, month, day), or nil if malformed.
    public static func parseYMD(_ s: String) -> (year: Int, month: Int, day: Int)? {
        let parts = s.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return (y, m, d)
    }

    public static func date(year: Int, month: Int, day: Int) -> Date {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return calendar.date(from: c)!
    }

    public static func lastDayOfMonth(year: Int, month: Int) -> Int {
        var c = DateComponents()
        c.year = year; c.month = month + 1; c.day = 0
        return calendar.date(from: c).map { calendar.component(.day, from: $0) } ?? 28
    }

    /// day: 1-31, or 0 meaning 末日 (end of month) — clamped to the month's real length.
    public static func resolveDay(year: Int, month: Int, day: Int) -> Int {
        let last = lastDayOfMonth(year: year, month: month)
        return day == 0 ? last : min(day, last)
    }

    /// Monday (as "YYYY-MM-DD") of the Mon–Sun week containing `dateStr`.
    public static func mondayOfWeek(_ dateStr: String) -> String {
        guard let (y, m, d) = parseYMD(dateStr) else { return dateStr }
        let base = date(year: y, month: m, day: d)
        let weekday = calendar.component(.weekday, from: base) // 1 = Sunday ... 7 = Saturday
        let diff = weekday == 1 ? -6 : 2 - weekday
        let monday = calendar.date(byAdding: .day, value: diff, to: base)!
        return ymd(monday)
    }

    public static func weekLabel(_ mondayStr: String, locale: Locale = .current) -> String {
        guard let (y, m, d) = parseYMD(mondayStr) else { return mondayStr }
        let monday = date(year: y, month: m, day: d)
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        let mc = calendar.dateComponents([.month, .day], from: monday)
        let sc = calendar.dateComponents([.month, .day], from: sunday)
        let separator = locale.language.languageCode?.identifier == "ja" ? "〜" : "–"
        return "\(mc.month!)/\(mc.day!)\(separator)\(sc.month!)/\(sc.day!)"
    }

    /// "September 2026" in English, "2026年9月" in Japanese — driven by the view's
    /// `\.locale` environment, not the device's system language, so the in-app language
    /// switcher (see SettingsView) controls it independent of the device's own Settings.
    public static func monthLabel(_ key: String, locale: Locale = .current) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return key }
        return date(year: y, month: m, day: 1)
            .formatted(.dateTime.year().month(.wide).locale(locale))
    }

    /// "YYYY-MM" shifted by `delta` months.
    public static func shiftMonth(_ key: String, by delta: Int) -> String {
        let parts = key.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]) else { return key }
        var c = DateComponents()
        c.year = y; c.month = m + delta; c.day = 1
        let d = calendar.date(from: c)!
        let rc = calendar.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", rc.year!, rc.month!)
    }

    public static func formatPeriodDate(_ dateStr: String) -> String {
        guard let (_, m, d) = parseYMD(dateStr) else { return dateStr }
        return "\(m)/\(d)"
    }

    public static func formatFullDate(_ dateStr: String, locale: Locale = .current) -> String {
        guard let (y, m, d) = parseYMD(dateStr) else { return dateStr }
        return date(year: y, month: m, day: d)
            .formatted(.dateTime.year().month(.wide).day().locale(locale))
    }
}

/// Clock-time helpers. Minutes are always "minutes since 00:00 of the shift's start day" —
/// a value >= 1440 means "the next calendar day", used throughout to represent overnight
/// shifts without ever needing a second date.
public enum ClockUtils {
    public static func formatClock(_ clockMinute: Int) -> String {
        let t = ((clockMinute % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", t / 60, t % 60)
    }

    public static func isLateNightMinute(_ clockMinute: Int) -> Bool {
        let t = ((clockMinute % 1440) + 1440) % 1440
        return t >= PayrollConstants.lateNightStartMinute || t < PayrollConstants.lateNightEndMinute
    }

    /// Merges a set of individual worked minutes into contiguous "HH:MM–HH:MM" ranges.
    public static func minutesToRanges(_ minuteList: [Int]) -> [String] {
        guard !minuteList.isEmpty else { return [] }
        let sorted = Array(Set(minuteList)).sorted()
        var ranges: [String] = []
        var start = sorted[0], prev = sorted[0]
        for cur in sorted.dropFirst() {
            if cur == prev + 1 { prev = cur; continue }
            ranges.append("\(formatClock(start))–\(formatClock(prev + 1))")
            start = cur; prev = cur
        }
        ranges.append("\(formatClock(start))–\(formatClock(prev + 1))")
        return ranges
    }
}
