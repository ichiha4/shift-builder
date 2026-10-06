import Foundation

/// A shift's calendar date and the month it's actually PAID in are not the same thing.
/// `closingDay` defines the cutoff (e.g. 15th → periods run 16th–15th); `paydayMonthOffset`/
/// `paydayDay` define when that period is paid out (e.g. offset=1, day=25 → the 25th of the
/// following month).
public enum PayPeriod {
    public struct Period: Equatable, Sendable {
        public var periodStart: String
        public var periodEnd: String
    }

    /// Given a worked date and an employer's closing day, returns the pay period it falls into.
    public static func period(forDate dateStr: String, closingDay: Int) -> Period {
        guard let (y, m, d) = DateUtils.parseYMD(dateStr) else { return Period(periodStart: dateStr, periodEnd: dateStr) }
        let thisMonthClose = DateUtils.resolveDay(year: y, month: m, day: closingDay)
        var endY = y, endM = m
        if d > thisMonthClose {
            endM += 1
            if endM > 12 { endM = 1; endY += 1 }
        }
        let endDay = DateUtils.resolveDay(year: endY, month: endM, day: closingDay)
        let periodEnd = String(format: "%04d-%02d-%02d", endY, endM, endDay)

        var startY = endY, startM = endM - 1
        if startM < 1 { startM = 12; startY -= 1 }
        let startCloseDay = DateUtils.resolveDay(year: startY, month: startM, day: closingDay)
        let startDate = DateUtils.calendar.date(byAdding: .day, value: 1, to: DateUtils.date(year: startY, month: startM, day: startCloseDay))!
        let periodStart = DateUtils.ymd(startDate)

        return Period(periodStart: periodStart, periodEnd: periodEnd)
    }

    /// All periods paid in a month. Holiday rolling can move two adjacent periods into
    /// the same month, so callers must retain every match rather than the first one.
    public static func periods(paidInMonth month: String, profile: EmployerProfile) -> [Period] {
        guard DateUtils.parseYMD(month + "-01") != nil else { return [] }
        return (-3...1).compactMap { offset in
            let candidate = DateUtils.shiftMonth(month, by: offset)
            guard let (y, m, _) = DateUtils.parseYMD(candidate + "-01") else { return nil }
            let close = DateUtils.resolveDay(year: y, month: m, day: profile.closingDay)
            let end = String(format: "%04d-%02d-%02d", y, m, close)
            let payday = paymentDate(periodEnd: end, paydayMonthOffset: profile.paydayMonthOffset,
                                     paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
            return payday.hasPrefix(month) ? period(forDate: end, closingDay: profile.closingDay) : nil
        }
    }

    public static func shifts(paidInMonth month: String, shifts: [Shift], profiles: [EmployerProfile]) -> [Shift] {
        let ranges = profiles.map { ($0.name, periods(paidInMonth: month, profile: $0)) }
        let names = Set(profiles.map(\.name))
        var seen = Set<String>()
        return shifts.filter { shift in
            let matches = names.contains(shift.employer)
                ? ranges.contains { name, periods in
                    name == shift.employer && periods.contains { shift.date >= $0.periodStart && shift.date <= $0.periodEnd }
                }
                : shift.date.hasPrefix(month)
            return matches && seen.insert(shift.id).inserted
        }
    }

    /// Given a pay period's end date, returns the date it's actually paid on — rolled to the
    /// nearest business day per `adjustment` if the raw payday lands on a weekend or Japanese
    /// national holiday, which is standard practice (most companies pay early rather than late).
    public static func paymentDate(periodEnd: String, paydayMonthOffset: Int, paydayDay: Int, adjustment: PaydayAdjustment = .beforeBusinessDay) -> String {
        guard let (y, m, _) = DateUtils.parseYMD(periodEnd) else { return periodEnd }
        var payY = y, payM = m + paydayMonthOffset
        while payM > 12 { payM -= 12; payY += 1 }
        let day = DateUtils.resolveDay(year: payY, month: payM, day: paydayDay)
        let raw = String(format: "%04d-%02d-%02d", payY, payM, day)
        switch adjustment {
        case .none:
            return raw
        case .beforeBusinessDay:
            return JapaneseHolidays.nearestBusinessDay(raw, direction: .backward)
        case .afterBusinessDay:
            return JapaneseHolidays.nearestBusinessDay(raw, direction: .forward)
        }
    }
}
