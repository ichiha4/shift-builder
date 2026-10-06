import Foundation

/// A replacement for a gross estimate, entered by the user as expected take-home pay.
/// It is a planning input, never written into the actual-payment history.
public struct ExpectedPayment: Equatable, Sendable {
    public var employer: String
    public var payDate: String
    public var amount: Double

    public init(employer: String, payDate: String, amount: Double) {
        self.employer = employer
        self.payDate = payDate
        self.amount = amount
    }
}

public struct CashFlowEvent: Equatable, Identifiable, Sendable {
    public enum Kind: String, Sendable {
        case grossEstimate, expectedTakeHome, actualIncome, expense, recurringExpense
    }
    public var id: String
    public var date: String
    public var title: String
    /// Positive for income, negative for spending.
    public var amount: Double
    public var kind: Kind
}

public struct CashFlowDay: Equatable, Identifiable, Sendable {
    public var date: String
    public var balance: Double
    public var id: String { date }
}

public struct CashFlowProjection: Equatable, Sendable {
    public var asOfDate: String
    public var openingBalance: Double
    public var days: [CashFlowDay]
    public var events: [CashFlowEvent]
    public var closingBalance: Double { days.last?.balance ?? openingBalance }
    public var minimumBalance: Double { min(openingBalance, days.map(\.balance).min() ?? openingBalance) }
    public var firstNegativeDate: String? {
        openingBalance < 0 ? asOfDate : days.first { $0.balance < 0 }?.date
    }
}

public enum CashFlowForecast {
    /// Starts AFTER asOfDate: the entered balance must already include that day's transactions.
    /// Only registered shifts and outgoings are included; this is not a bank balance or budget.
    public static func project(
        asOfDate: String, openingBalance: Double, days: Int,
        shifts: [Shift], profiles: [EmployerProfile], actualPayments: [ActualPayment],
        expenses: [Expense], recurringExpenses: [RecurringExpense],
        expectedPayments: [ExpectedPayment] = []
    ) -> CashFlowProjection? {
        guard let start = validDate(asOfDate), openingBalance.isFinite, (1...90).contains(days),
              let end = DateUtils.calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        let endDate = DateUtils.ymd(end)
        let inRange: (String) -> Bool = { $0 > asOfDate && $0 <= endDate && validDate($0) != nil }
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        var events: [CashFlowEvent] = []
        let key: (String, String) -> String = { $0 + "\u{0}" + $1 }
        var recordedKeys = Set<String>()
        for payment in actualPayments where inRange(payment.payDate) && validAmount(payment.amount) {
            let paymentKey = key(payment.employer, payment.payDate)
            guard recordedKeys.insert(paymentKey).inserted else { continue }
            events.append(CashFlowEvent(id: "actual:" + payment.id, date: payment.payDate,
                title: payment.employer, amount: payment.amount, kind: .actualIncome))
        }

        // Aggregate by employer + payday. Two periods can roll onto the same date; two copies
        // of a profile must not count the same shift twice.
        var incomeShifts: [String: [String: Shift]] = [:]
        var incomeDates: [String: (employer: String, date: String)] = [:]
        var month = String(asOfDate.prefix(7))
        while month <= String(endDate.prefix(7)) {
            for profile in profiles {
                for period in PayPeriod.periods(paidInMonth: month, profile: profile) {
                    let payday = PayPeriod.paymentDate(periodEnd: period.periodEnd,
                        paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay,
                        adjustment: profile.paydayAdjustment)
                    guard inRange(payday) else { continue }
                    let paymentKey = key(profile.name, payday)
                    guard !recordedKeys.contains(paymentKey) else { continue }
                    incomeDates[paymentKey] = (profile.name, payday)
                    for shift in shifts where shift.employer == profile.name &&
                        shift.date >= period.periodStart && shift.date <= period.periodEnd {
                        incomeShifts[paymentKey, default: [:]][shift.id] = shift
                    }
                }
            }
            month = DateUtils.shiftMonth(month, by: 1)
        }
        for (paymentKey, dated) in incomeDates {
            let paidShifts = Array((incomeShifts[paymentKey] ?? [:]).values)
            guard !paidShifts.isEmpty else { continue }
            let gross = Aggregation.calculateMonthlyPay(paidShifts, classifications: classifications).grossTotal
            guard validAmount(gross) else { continue }
            let replacement = expectedPayments.last {
                $0.employer == dated.employer && $0.payDate == dated.date && validAmount($0.amount)
            }
            events.append(CashFlowEvent(id: "income:" + paymentKey, date: dated.date,
                title: dated.employer, amount: replacement?.amount ?? gross,
                kind: replacement == nil ? .grossEstimate : .expectedTakeHome))
        }

        // A recorded charge wins over the virtual recurring charge for that item + month,
        // including when its date or amount was edited. Never persist forecast-only expenses.
        let recordedMonths = Set(expenses.compactMap { expense -> String? in
            guard let recurringID = expense.recurringExpenseId else { return nil }
            return key(recurringID, String(expense.date.prefix(7)))
        })
        for expense in expenses where inRange(expense.date) && validAmount(expense.amount) {
            events.append(CashFlowEvent(id: "expense:" + expense.id, date: expense.date,
                title: expense.memo.isEmpty ? expense.category : expense.memo,
                amount: -expense.amount, kind: .expense))
        }
        month = String(asOfDate.prefix(7))
        var generated = Set<String>()
        while month <= String(endDate.prefix(7)) {
            guard let (year, monthNumber, _) = DateUtils.parseYMD(month + "-01") else { return nil }
            for recurring in recurringExpenses where recurring.isActive && validAmount(recurring.amount) &&
                (0...31).contains(recurring.dayOfMonth) {
                let recurringKey = key(recurring.id, month)
                guard !recordedMonths.contains(recurringKey), generated.insert(recurringKey).inserted else { continue }
                let day = DateUtils.resolveDay(year: year, month: monthNumber, day: recurring.dayOfMonth)
                let date = String(format: "%04d-%02d-%02d", year, monthNumber, day)
                guard inRange(date) else { continue }
                events.append(CashFlowEvent(id: "recurring:" + recurringKey, date: date,
                    title: recurring.name, amount: -recurring.amount, kind: .recurringExpense))
            }
            month = DateUtils.shiftMonth(month, by: 1)
        }
        events.sort { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
        let byDay = Dictionary(grouping: events, by: \.date)
        var balance = openingBalance
        var timeline: [CashFlowDay] = []
        for offset in 1...days {
            let date = DateUtils.ymd(DateUtils.calendar.date(byAdding: .day, value: offset, to: start)!)
            balance += (byDay[date] ?? []).reduce(0) { $0 + $1.amount }
            guard balance.isFinite else { return nil }
            timeline.append(CashFlowDay(date: date, balance: balance))
        }
        return CashFlowProjection(asOfDate: asOfDate, openingBalance: openingBalance,
                                  days: timeline, events: events)
    }

    static func validDate(_ value: String) -> Date? {
        guard value.count == 10, let (y, m, d) = DateUtils.parseYMD(value),
              (1900...2200).contains(y), (1...12).contains(m),
              (1...DateUtils.lastDayOfMonth(year: y, month: m)).contains(d) else { return nil }
        let date = DateUtils.date(year: y, month: m, day: d)
        return DateUtils.ymd(date) == value ? date : nil
    }

    private static func validAmount(_ amount: Double) -> Bool { amount.isFinite && amount >= 0 }
}

public struct ShiftScenarioResult: Equatable, Sendable {
    public var baselineGross: Double
    public var scenarioGross: Double
    public var baselineMinutes: Int
    public var scenarioMinutes: Int
    public var difference: Double { scenarioGross - baselineGross }
}

public enum ShiftScenario {
    /// Work-month basis, before deductions. Reclassify ALL retained shifts in each case so
    /// weekly overtime, cross-month weeks and monthly premium thresholds remain correct.
    public static func compare(month: String, shifts: [Shift], adding: [Shift] = [],
                               removingIDs: Set<String> = []) -> ShiftScenarioResult? {
        guard CashFlowForecast.validDate(month + "-01") != nil else { return nil }
        let retained = shifts.filter { !removingIDs.contains($0.id) }
        let candidate = retained + adding
        guard Set(shifts.map(\.id)).count == shifts.count,
              Set(candidate.map(\.id)).count == candidate.count,
              adding.allSatisfy({ new in
                  CashFlowForecast.validDate(new.date) != nil &&
                  !hasOverlap(new, with: candidate.filter { $0.id != new.id })
              }) else { return nil }
        let before = Aggregation.calculateMonthlyPay(shifts.filter { $0.date.hasPrefix(month) },
            classifications: PayCalculation.buildEmployerClassifications(shifts))
        let after = Aggregation.calculateMonthlyPay(candidate.filter { $0.date.hasPrefix(month) },
            classifications: PayCalculation.buildEmployerClassifications(candidate))
        return ShiftScenarioResult(baselineGross: before.grossTotal, scenarioGross: after.grossTotal,
            baselineMinutes: before.baseMinutes, scenarioMinutes: after.baseMinutes)
    }

    /// Checks clock spans across adjacent dates too, including work crossing midnight.
    public static func hasOverlap(_ new: Shift, with shifts: [Shift]) -> Bool {
        guard let newDate = CashFlowForecast.validDate(new.date) else { return false }
        let newRanges = Validation.absoluteRanges(new.segments)
        return shifts.contains { saved in
            guard let savedDate = CashFlowForecast.validDate(saved.date),
                  let dayOffset = DateUtils.calendar.dateComponents([.day], from: newDate, to: savedDate).day,
                  abs(dayOffset) <= 2 else { return false }
            return Validation.absoluteRanges(saved.segments).contains { range in
                let start = range.start + dayOffset * 1440
                let end = range.end + dayOffset * 1440
                return newRanges.contains { $0.start < end && start < $0.end }
            }
        }
    }
}
