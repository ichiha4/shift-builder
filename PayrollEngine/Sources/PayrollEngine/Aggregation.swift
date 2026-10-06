import Foundation

public struct PayContributor: Equatable, Sendable {
    public var shift: Shift
    public var amount: Double
    public var minutes: Int?
    public var ranges: [String]
    public var formula: [FormulaLine]
}

/// Aggregates a set of shifts (already filtered to one month) into the payslip totals shown
/// on the 給与 tab. Pure — no rounding until display.
public struct MonthlyPayslip: Equatable, Sendable {
    public var base = 0.0
    public var overtime = 0.0
    public var lateNight = 0.0
    public var holiday = 0.0
    public var transport = 0.0
    public var otherAllowance = 0.0
    /// Pay taken back out for breaks entered without a start time — see `ShiftPayResult.breakDeduction`.
    public var breakDeduction = 0.0
    public var grossTotal = 0.0
    public var baseMinutes = 0
    public var normalMinutes = 0
    public var overtimeMinutes = 0
    public var scheduledOvertimeMinutes = 0
    /// Of `overtimeMinutes`, the part past the month's 60th legal-overtime hour (5割増).
    public var extendedOvertimeMinutes = 0
    public var lateNightMinutes = 0
    public var holidayMinutes = 0
    public var overtimeContributors: [PayContributor] = []
    public var lateNightContributors: [PayContributor] = []
    public var holidayContributors: [PayContributor] = []
    public var transportContributors: [PayContributor] = []
    public var otherAllowanceContributors: [PayContributor] = []
}

public struct WeeklyItem: Equatable, Sendable {
    public var shift: Shift
    public var minutes: Int
}

public struct WeeklyBucket: Equatable, Sendable {
    public var totalMinutes = 0
    public var weeklyLegalOvertimeMinutes = 0
    public var items: [WeeklyItem] = []
}

public struct EmployerIncomeTax: Equatable, Sendable {
    public var employer: String
    /// Taxable gross for the month at this employer — everything but 交通費, which is
    /// non-taxable up to the statutory commuting-allowance limit and excluded here rather than
    /// modeling that limit for what's normally a small amount anyway.
    public var taxableGross: Double
    public var tax: Double
    public var column: IncomeTaxColumn
}

/// Payday-based home summary. Recorded receipts survive later profile edits/deletion.
public struct PaydayIncomeEntry: Identifiable, Equatable, Sendable {
    public var id: String
    public var employer: String
    public var amount: Double
    public var isActual: Bool
}

public enum Aggregation {
    public static func paydayIncomeEntries(month: String, shifts: [Shift], profiles: [EmployerProfile], actualPayments: [ActualPayment], classifications: [String: [String: ShiftClassification]]) -> [PaydayIncomeEntry] {
        var results = actualPayments.filter { $0.payDate.hasPrefix(month) }.map {
            PaydayIncomeEntry(id: "actual:" + $0.id, employer: $0.employer, amount: $0.amount, isActual: true)
        }
        var seen = Set<String>()
        for profile in profiles {
            for period in PayPeriod.periods(paidInMonth: month, profile: profile) {
                let payDate = PayPeriod.paymentDate(periodEnd: period.periodEnd, paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
                // A receipt replaces an estimate only for the same employer and payday.
                let key = profile.name + "\u{0}" + payDate
                guard seen.insert(key).inserted,
                      !actualPayments.contains(where: { $0.employer == profile.name && $0.payDate == payDate }) else { continue }
                let paidShifts = shifts.filter { $0.employer == profile.name && $0.date >= period.periodStart && $0.date <= period.periodEnd }
                let amount = calculateMonthlyPay(paidShifts, classifications: classifications).grossTotal
                if amount > 0 {
                    results.append(PaydayIncomeEntry(id: "estimate:" + profile.id + payDate, employer: profile.name, amount: amount, isActual: false))
                }
            }
        }
        return results
    }

    /// One row per employer that had shifts this month, each taxed independently per
    /// `IncomeTax` — never combine employers before withholding, that's not how the 甲/乙 tables
    /// work. An employer with no saved `EmployerProfile` (so no column/dependents on file)
    /// defaults to 甲欄 with no dependents, matching a first/only job with nothing configured.
    /// `socialInsurance`: the month's employee-paid 健康保険・厚生年金・雇用保険 premiums. The
    /// official method subtracts these before reading the withholding table, so leaving them out
    /// overstates the tax — by roughly 5% of the premiums at the lowest bracket, and more above
    /// it. Each employer may only subtract the premiums withheld from its own pay. Deductions are
    /// recorded per month rather than per employer, so they are attributed to the job whose
    /// 社会保険 the worker is in — in practice the main job, 甲欄 (split by pay if several are
    /// marked 甲欄); only a month with no 甲欄 employer spreads them over every employer by pay.
    /// With the single employer that describes almost every user, it is just the whole amount.
    /// `year`: the payday's year, which decides the NTA table (see `IncomeTax`).
    public static func calculateIncomeTax(_ monthShifts: [Shift], classifications: [String: [String: ShiftClassification]], profiles: [EmployerProfile], socialInsurance: Double = 0, year: Int) -> [EmployerIncomeTax] {
        var grossByEmployer: [String: Double] = [:]
        for s in monthShifts {
            let t = PayCalculation.pay(for: s, classifications: classifications)
            // Everything actually paid except 交通費: the same figure as the shift's own pay, so an
            // untimed break is already taken out rather than taxed as if it were worked.
            grossByEmployer[s.employer, default: 0] += t.netPay - t.transport
        }
        func column(of employer: String) -> IncomeTaxColumn {
            profiles.first { $0.name == employer }?.incomeTaxColumn ?? .kou
        }
        let totalGross = grossByEmployer.values.reduce(0, +)
        let kouGross = grossByEmployer.filter { column(of: $0.key) == .kou }.values.reduce(0, +)
        return grossByEmployer.map { employer, gross in
            let profile = profiles.first { $0.name == employer }
            let column = column(of: employer)
            let share: Double
            if kouGross > 0 {
                share = column == .kou ? socialInsurance * (gross / kouGross) : 0
            } else {
                share = totalGross > 0 ? socialInsurance * (gross / totalGross) : 0
            }
            let tax = IncomeTax.monthlyWithholding(
                grossPay: gross,
                column: column,
                dependentsCount: profile?.dependentsCount ?? 0,
                hasSpouseAllowance: profile?.hasSpouseAllowance ?? false,
                socialInsurance: share,
                year: year
            )
            return EmployerIncomeTax(employer: employer, taxableGross: gross, tax: tax, column: column)
        }.sorted { $0.employer < $1.employer }
    }


    public static func calculateMonthlyPay(_ monthShifts: [Shift], classifications: [String: [String: ShiftClassification]]) -> MonthlyPayslip {
        var slip = MonthlyPayslip()
        for s in monthShifts {
            let t = PayCalculation.pay(for: s, classifications: classifications)
            slip.base += t.base
            slip.overtime += t.overtimeExtra
            slip.lateNight += t.lateNightExtra
            slip.holiday += t.holidayExtra
            slip.transport += t.transport
            slip.otherAllowance += t.otherAllowance
            slip.breakDeduction += t.breakDeduction
            slip.baseMinutes += t.netMinutes
            slip.normalMinutes += t.normalMinutes
            slip.overtimeMinutes += t.overtimeMinutes
            slip.scheduledOvertimeMinutes += t.scheduledOvertimeMinutes
            slip.extendedOvertimeMinutes += t.extendedOvertimeMinutes
            slip.lateNightMinutes += t.lateNightMinutes
            slip.holidayMinutes += t.holidayMinutes
            if t.overtimeExtra > 0 {
                slip.overtimeContributors.append(PayContributor(shift: s, amount: t.overtimeExtra, minutes: t.overtimeMinutes, ranges: t.overtimeRanges, formula: t.overtimeFormula))
            }
            if t.lateNightExtra > 0 {
                slip.lateNightContributors.append(PayContributor(shift: s, amount: t.lateNightExtra, minutes: t.lateNightMinutes, ranges: t.lateNightRanges, formula: t.lateNightFormula))
            }
            if t.holidayExtra > 0 {
                slip.holidayContributors.append(PayContributor(shift: s, amount: t.holidayExtra, minutes: t.holidayMinutes, ranges: t.holidayRanges, formula: t.holidayFormula))
            }
            if t.transport > 0 {
                slip.transportContributors.append(PayContributor(shift: s, amount: t.transport, minutes: nil, ranges: [], formula: []))
            }
            if t.otherAllowance > 0 {
                slip.otherAllowanceContributors.append(PayContributor(shift: s, amount: t.otherAllowance, minutes: nil, ranges: [], formula: []))
            }
        }
        slip.grossTotal = slip.base + slip.overtime + slip.lateNight + slip.holiday - slip.breakDeduction
            + slip.transport + slip.otherAllowance
        return slip
    }

    /// Groups shifts into Mon–Sun weeks and sums net worked minutes, plus how many of those
    /// minutes actually became weekly-legal-overtime (feeds back into pay via
    /// `classifyEmployerOvertime`, not merely informational).
    public static func calculateWeeklyHours(_ shifts: [Shift], classifications: [String: [String: ShiftClassification]]) -> [String: WeeklyBucket] {
        var map: [String: WeeklyBucket] = [:]
        for s in shifts {
            let wk = DateUtils.mondayOfWeek(s.date)
            let t = PayCalculation.pay(for: s, classifications: classifications)
            var bucket = map[wk] ?? WeeklyBucket()
            bucket.totalMinutes += t.netMinutes
            if !s.isStatutoryHoliday, let shiftCls = classifications[s.employer]?[s.id] {
                bucket.weeklyLegalOvertimeMinutes += shiftCls.minutes.filter { $0.bucket == .weeklyLegalOvertime }.count
            }
            bucket.items.append(WeeklyItem(shift: s, minutes: t.netMinutes))
            map[wk] = bucket
        }
        return map
    }
}
