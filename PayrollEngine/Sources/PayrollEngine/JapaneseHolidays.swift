import Foundation

/// Japan's national holidays (国民の祝日), computed rather than table-driven so paydays years
/// out still resolve correctly. Covers the "Happy Monday" holidays, the equinoxes (by the
/// standard astronomical approximation used throughout Japanese calendar software), and 振替休日
/// (a holiday landing on Sunday pushes the next non-holiday day into a holiday too). Valid for
/// the current holiday law's era — roughly 2000–2099; equinox dates in particular are only
/// approximated correctly within that range.
public enum JapaneseHolidays {
    public static func isHoliday(year: Int, month: Int, day: Int) -> Bool {
        isNamedHoliday(year: year, month: month, day: day)
            || isSubstituteHoliday(year: year, month: month, day: day)
            || isCitizensHoliday(year: year, month: month, day: day)
    }

    public static func isHoliday(_ dateStr: String) -> Bool {
        guard let (y, m, d) = DateUtils.parseYMD(dateStr) else { return false }
        return isHoliday(year: y, month: m, day: d)
    }

    public static func isWeekend(_ dateStr: String) -> Bool {
        guard let (y, m, d) = DateUtils.parseYMD(dateStr) else { return false }
        let weekday = DateUtils.calendar.component(.weekday, from: DateUtils.date(year: y, month: m, day: d)) // 1=Sun...7=Sat
        return weekday == 1 || weekday == 7
    }

    /// A day banks — and so salary transfers — are open: not a weekend, not a 祝日法 holiday, and
    /// not 12/31〜1/3 (銀行法施行令第5条第1項第2号). Used to roll paydays.
    public static func isBusinessDay(_ dateStr: String) -> Bool {
        !isWeekend(dateStr) && !isHoliday(dateStr) && !isYearEndBankHoliday(dateStr)
    }

    static func isYearEndBankHoliday(_ dateStr: String) -> Bool {
        guard let (_, m, d) = DateUtils.parseYMD(dateStr) else { return false }
        return (m == 12 && d == 31) || (m == 1 && d <= 3)
    }

    /// Steps backward (or forward) one day at a time to the nearest business day.
    public static func nearestBusinessDay(_ dateStr: String, direction: RollDirection) -> String {
        var current = dateStr
        var guardCount = 0
        while !isBusinessDay(current) && guardCount < 14 {
            guard let (y, m, d) = DateUtils.parseYMD(current) else { break }
            let delta = direction == .backward ? -1 : 1
            let next = DateUtils.calendar.date(byAdding: .day, value: delta, to: DateUtils.date(year: y, month: m, day: d))!
            current = DateUtils.ymd(next)
            guardCount += 1
        }
        return current
    }

    public enum RollDirection: Sendable { case backward, forward }

    // MARK: - Named holidays

    private static func isNamedHoliday(year: Int, month: Int, day: Int) -> Bool {
        switch (month, day) {
        case (1, 1): return true // 元日
        case (2, 11): return true // 建国記念の日
        case (2, 23): return year >= 2020 // 天皇誕生日 (令和)
        case (4, 29): return true // 昭和の日
        case (5, 3): return true // 憲法記念日
        case (5, 4): return true // みどりの日
        case (5, 5): return true // こどもの日
        case (8, 11): return year >= 2016 // 山の日
        case (11, 3): return true // 文化の日
        case (11, 23): return true // 勤労感謝の日
        default: break
        }
        if month == 1 && day == nthWeekdayOfMonth(year: year, month: 1, weekday: 2, n: 2) { return true } // 成人の日: 2nd Mon
        if month == 7 && day == nthWeekdayOfMonth(year: year, month: 7, weekday: 2, n: 3) { return true } // 海の日: 3rd Mon
        if month == 9 && day == nthWeekdayOfMonth(year: year, month: 9, weekday: 2, n: 3) { return true } // 敬老の日: 3rd Mon
        if month == 10 && day == nthWeekdayOfMonth(year: year, month: 10, weekday: 2, n: 2) { return true } // スポーツの日: 2nd Mon
        if month == 3 && day == vernalEquinoxDay(year: year) { return true }
        if month == 9 && day == autumnalEquinoxDay(year: year) { return true }
        return false
    }

    /// 国民の休日 (祝日法第3条第3項): a day that is not itself a 国民の祝日 but falls between two of
    /// them is a holiday too — e.g. 2026-09-22, between 敬老の日 and 秋分の日.
    private static func isCitizensHoliday(year: Int, month: Int, day: Int) -> Bool {
        guard !isNamedHoliday(year: year, month: month, day: day) else { return false }
        let date = DateUtils.date(year: year, month: month, day: day)
        func named(_ offset: Int) -> Bool {
            let c = DateUtils.calendar.dateComponents([.year, .month, .day],
                                                      from: DateUtils.calendar.date(byAdding: .day, value: offset, to: date)!)
            return isNamedHoliday(year: c.year!, month: c.month!, day: c.day!)
        }
        return named(-1) && named(1)
    }

    /// A holiday that lands on Sunday pushes the next day that isn't itself a named holiday
    /// into a holiday (振替休日) — checked separately from `isNamedHoliday` to avoid infinite
    /// recursion between the two.
    private static func isSubstituteHoliday(year: Int, month: Int, day: Int) -> Bool {
        let date = DateUtils.date(year: year, month: month, day: day)
        let weekday = DateUtils.calendar.component(.weekday, from: date) // 1=Sun
        guard weekday != 1 else { return false } // Sunday itself is never the substitute day
        var probe = DateUtils.calendar.date(byAdding: .day, value: -1, to: date)!
        while true {
            let probeComponents = DateUtils.calendar.dateComponents([.year, .month, .day, .weekday], from: probe)
            guard let py = probeComponents.year, let pm = probeComponents.month, let pd = probeComponents.day,
                  let pWeekday = probeComponents.weekday else { return false }
            guard isNamedHoliday(year: py, month: pm, day: pd) else { return false }
            if pWeekday == 1 { return true } // the holiday we walked back to was itself a Sunday
            probe = DateUtils.calendar.date(byAdding: .day, value: -1, to: probe)!
        }
    }

    private static func nthWeekdayOfMonth(year: Int, month: Int, weekday: Int, n: Int) -> Int {
        let first = DateUtils.date(year: year, month: month, day: 1)
        let firstWeekday = DateUtils.calendar.component(.weekday, from: first)
        let offset = (weekday - firstWeekday + 7) % 7
        return 1 + offset + (n - 1) * 7
    }

    /// Standard approximation formula used throughout Japanese calendar software; exact for
    /// 1980–2099 (drifts outside that range as leap-year accumulation shifts the equinox).
    private static func vernalEquinoxDay(year: Int) -> Int {
        Int(20.8431 + 0.242194 * Double(year - 1980) - Double((year - 1980) / 4))
    }

    private static func autumnalEquinoxDay(year: Int) -> Int {
        Int(23.2488 + 0.242194 * Double(year - 1980) - Double((year - 1980) / 4))
    }
}
