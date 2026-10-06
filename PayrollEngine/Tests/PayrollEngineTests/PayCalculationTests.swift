import XCTest
@testable import PayrollEngine

final class PayCalculationTests: XCTestCase {

    // MARK: - Basic pay

    func testPlainEightHourShift() {
        // 09:00–17:00 @ ¥1200/h, no break → 8h × ¥1200 = ¥9,600. Matches the figure verified
        // by hand against the shipped web app.
        let seg = WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1200)
        let shift = Shift(date: "2026-09-11", employer: "テストカフェ", segments: [seg])
        let estimate = PayCalculation.estimateShiftPay(shift)
        XCTAssertEqual(estimate.netMinutes, 480)
        XCTAssertEqual(estimate.totalMinutes, 480)
        XCTAssertEqual(estimate.netPay, 9600, accuracy: 0.001)
    }

    // MARK: - Break handling: totalMinutes must mean the same thing regardless of how the
    // break was entered (this was a real bug: precise vs. approximate break disagreed on
    // whether totalMinutes included the break, so the same real shift produced a different
    // legally-required-break hint depending on data entry method).

    func testPreciseBreakKeepsGrossTotalMinutesForBreakHintButNetsPayCorrectly() {
        // 09:00–17:30 (8.5h raw) with a precise 60-min break at 12:00–13:00 → net 7.5h.
        let seg = WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60 + 30, hourlyWage: 1200)
        let shift = Shift(date: "2026-09-11", employer: "テストカフェ", segments: [seg], breakMinutes: 60, breakStartMinute: 12 * 60)
        let estimate = PayCalculation.estimateShiftPay(shift)

        XCTAssertEqual(estimate.totalMinutes, 510, "raw span must include the break")
        XCTAssertEqual(estimate.netMinutes, 450, "pay basis must exclude the break")
        XCTAssertEqual(estimate.netPay, 9000, accuracy: 0.001)

        // The law uses 7.5 hours of actual work, not the 8.5-hour span.
        XCTAssertEqual(Validation.breakHint(netMinutes: estimate.netMinutes), "6時間超の勤務のため、法律上は休憩45分以上が必要です")
    }

    func testApproximateBreakAlsoReportsGrossTotalMinutes() {
        // Same real shift, but the break is only given as a minute count (no start time) —
        // totalMinutes must still be the gross 8.5h span, matching the precise-break case.
        let seg = WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60 + 30, hourlyWage: 1200)
        let shift = Shift(date: "2026-09-11", employer: "テストカフェ", segments: [seg], breakMinutes: 60, breakStartMinute: nil)
        let estimate = PayCalculation.estimateShiftPay(shift)

        XCTAssertEqual(estimate.totalMinutes, 510)
        XCTAssertEqual(estimate.netMinutes, 450)
        XCTAssertEqual(Validation.breakHint(netMinutes: estimate.netMinutes), "6時間超の勤務のため、法律上は休憩45分以上が必要です")
    }

    func testOvernightBreakStartResolvesPastMidnight() {
        // 22:00–06:00 shift with a 60-min break starting at 01:00 — the break must be found
        // at clock-minute 1500 (1440 + 60), not 60, or it would silently not exclude any
        // worked minutes from pay.
        let seg = WorkSegment(startMinute: 22 * 60, endMinute: 6 * 60, hourlyWage: 1000)
        let shift = Shift(date: "2026-09-11", employer: "夜勤先", segments: [seg], breakMinutes: 60, breakStartMinute: 1 * 60)
        let estimate = PayCalculation.estimateShiftPay(shift)
        // 8h raw - 1h break = 7h net.
        XCTAssertEqual(estimate.netMinutes, 420)
    }

    // MARK: - Late night premium

    func testLateNightPremiumAppliesWithinTheWindow() {
        // 20:00–23:00 @ ¥1000/h, 25% late-night premium for the 22:00–23:00 hour.
        let seg = WorkSegment(startMinute: 20 * 60, endMinute: 23 * 60, hourlyWage: 1000)
        let shift = Shift(date: "2026-09-11", employer: "夜勤先", segments: [seg], lateNightRate: 0.25)
        let estimate = PayCalculation.estimateShiftPay(shift)
        XCTAssertEqual(estimate.lateNightMinutes, 60)
        XCTAssertEqual(estimate.lateNightExtra, 250, accuracy: 0.001) // 1h × ¥1000 × 25%
    }

    // MARK: - Daily overtime classification (cross-shift)

    func testDailyOvertimeSplitsAcrossTwoShiftsSameEmployerSameDay() {
        // Two shifts for the same employer, same day: 09:00–13:00 (4h) and 14:00–20:00 (6h)
        // = 10h total → 2h over the legal 8h/day line, attributed to the LATEST-occurring
        // minutes (end of the second shift).
        let morning = Shift(id: "morning", date: "2026-09-11", employer: "カフェ", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 13 * 60, hourlyWage: 1000)])
        let evening = Shift(id: "evening", date: "2026-09-11", employer: "カフェ", segments: [WorkSegment(startMinute: 14 * 60, endMinute: 20 * 60, hourlyWage: 1000)])
        let classifications = PayCalculation.buildEmployerClassifications([morning, evening])

        let morningPay = PayCalculation.pay(for: morning, classifications: classifications)
        let eveningPay = PayCalculation.pay(for: evening, classifications: classifications)

        XCTAssertEqual(morningPay.overtimeMinutes, 0, "the earlier shift shouldn't carry the day's overtime")
        XCTAssertEqual(eveningPay.overtimeMinutes, 120, "the last 2h of the day, in the later shift, are the daily-legal overtime")
        XCTAssertEqual(eveningPay.overtimeExtra, (120.0 / 60) * 1000 * 0.25, accuracy: 0.001)
    }

    func testWeeklyOvertimeAppliesOnceFortyHoursExceededAcrossTheWeek() {
        // Five 9h days (Mon–Fri) at the same employer = 45h/week. Each day is under the 8h/
        // day line individually, so all 5h of excess must come from the WEEKLY 40h line —
        // never double-counted against the (here, zero) daily line.
        var shifts: [Shift] = []
        let mondayComponents: [(String)] = ["2026-09-07", "2026-09-08", "2026-09-09", "2026-09-10", "2026-09-11"]
        for date in mondayComponents {
            shifts.append(Shift(id: "s-\(date)", date: date, employer: "倉庫", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 18 * 60, hourlyWage: 1000)]))
        }
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        var totalOvertimeMinutes = 0
        for s in shifts {
            totalOvertimeMinutes += PayCalculation.pay(for: s, classifications: classifications).overtimeMinutes
        }
        XCTAssertEqual(totalOvertimeMinutes, 300, "45h - 40h = 5h of weekly overtime across the week")
    }

    // MARK: - Pay period / payday

    func testPayPeriodRollsIntoNextMonthPastClosingDay() {
        // closingDay = 15: a shift worked on the 20th belongs to the period ending the 15th
        // of the FOLLOWING month.
        let period = PayPeriod.period(forDate: "2026-09-20", closingDay: 15)
        XCTAssertEqual(period.periodStart, "2026-09-16")
        XCTAssertEqual(period.periodEnd, "2026-10-15")
    }

    func testPaymentDateHandlesYearRollover() {
        // A period ending in December, paid the following month, rolls into January of the
        // next year.
        let paydate = PayPeriod.paymentDate(periodEnd: "2026-12-15", paydayMonthOffset: 1, paydayDay: 25)
        XCTAssertEqual(paydate, "2027-01-25")
    }

    func testEndOfMonthClosingDayZero() {
        // closingDay = 0 means 末日 (last day of the month) — verify it resolves correctly
        // for a short month (February).
        let period = PayPeriod.period(forDate: "2026-02-10", closingDay: 0)
        XCTAssertEqual(period.periodEnd, "2026-02-28")
    }

    // MARK: - The scheduledHours-can't-be-zero bug (fixed in the web version; must not
    // regress here now that the type is Double, not a JS `x || 8` fallback).

    func testEmployerProfileAllowsZeroScheduledHours() {
        let profile = EmployerProfile(name: "オンコール先", scheduledHours: 0)
        XCTAssertEqual(profile.scheduledMinutes, 0)
        let defaults = PayCalculation.profileDefaults(employerName: "オンコール先", profiles: [profile])
        XCTAssertEqual(defaults.scheduledMinutes, 0)
    }

    // MARK: - Date utilities (the original JS bug this guards against: `Date().toISOString()`
    // is UTC, so late-evening JST timestamps rolled back to the PREVIOUS calendar day).

    func testYmdUsesLocalCalendarDate() {
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 11; components.hour = 23; components.minute = 30
        let date = DateUtils.calendar.date(from: components)!
        XCTAssertEqual(DateUtils.ymd(date), "2026-09-11")
    }

    func testMondayOfWeek() {
        // 2026-09-11 is a Friday.
        XCTAssertEqual(DateUtils.mondayOfWeek("2026-09-11"), "2026-09-07")
        // A Sunday should resolve to the Monday six days BEFORE it, not the next one.
        XCTAssertEqual(DateUtils.mondayOfWeek("2026-09-13"), "2026-09-07")
    }

    // MARK: - Validation

    func testOverlappingSegmentsAreRejected() {
        let segments = [
            WorkSegment(startMinute: 9 * 60, endMinute: 13 * 60, hourlyWage: 1000),
            WorkSegment(startMinute: 12 * 60, endMinute: 17 * 60, hourlyWage: 1200),
        ]
        let errors = Validation.validateShift(segments: segments, breakMinutes: 0, breakStartMinute: nil, lateNightRate: 0.25, overtimeRate: 0.25, holidayRate: 0.35)
        XCTAssertTrue(errors.contains { $0.contains("重複") })
    }

    func testZeroOrNegativeWageIsRejected() {
        let segments = [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 0)]
        let errors = Validation.validateShift(segments: segments, breakMinutes: 0, breakStartMinute: nil, lateNightRate: 0.25, overtimeRate: 0.25, holidayRate: 0.35)
        XCTAssertTrue(errors.contains { $0.contains("時給が0円以下") })
    }

    // MARK: - Income tax withholding (令和8年分 源泉徴収税額表, verified against the NTA's own
    // worked examples in the 月額表甲欄・電算機計算の特例 publication — these are not
    // approximations, they must match exactly.)

    func testKouWithholding_spouseAndOneDependent() {
        // (計算例) A=175,000, spouse + 1 dependent → 特例計算 210円
        let tax = IncomeTax.monthlyWithholding(grossPay: 175_000, column: .kou, dependentsCount: 1, hasSpouseAllowance: true, year: 2026)
        XCTAssertEqual(tax, 210)
    }

    func testKouWithholding_spouseAndSevenDependents() {
        // (計算例) A=446,000, spouse + 7 dependents → 特例計算 940円
        let tax = IncomeTax.monthlyWithholding(grossPay: 446_000, column: .kou, dependentsCount: 7, hasSpouseAllowance: true, year: 2026)
        XCTAssertEqual(tax, 940)
    }

    func testKouWithholding_spouseAndTwoDependentsHighIncome() {
        // (計算例) A=775,200, spouse + 2 dependents → 特例計算 59,470円
        let tax = IncomeTax.monthlyWithholding(grossPay: 775_200, column: .kou, dependentsCount: 2, hasSpouseAllowance: true, year: 2026)
        XCTAssertEqual(tax, 59_470)
    }

    func testKouWithholding_noDeductionsBelowThreshold() {
        // A well under 105,000 with no spouse/dependents: 甲欄0人 table shows 0 up to 105,000.
        let tax = IncomeTax.monthlyWithholding(grossPay: 90_000, column: .kou, year: 2026)
        XCTAssertEqual(tax, 0)
    }

    func testOtsuWithholding_belowFlatRateThreshold() {
        // Below 105,000, 乙欄 is a flat 3.063% of the amount — a common case for a small
        // secondary/second job.
        // 50,000 × 3.063% = 1,531.5 — fractions of a yen are dropped, not rounded.
        let tax = IncomeTax.monthlyWithholding(grossPay: 50_000, column: .otsu, year: 2026)
        XCTAssertEqual(tax, 1_531)
    }

    func testOtsuWithholding_tableLookupMatchesPublishedRow() {
        // Table row "175,000〜177,000円未満" → 乙欄 12,100円.
        let tax = IncomeTax.monthlyWithholding(grossPay: 176_000, column: .otsu, year: 2026)
        XCTAssertEqual(tax, 12_100)
    }

    func testOtsuWithholding_tableLastRowBeforeFormulaHandoff() {
        // Table row "737,000〜740,000円未満" → 乙欄 257,700円, and exactly at 740,000 the
        // formula's base value (259,200) takes over.
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 739_000, column: .otsu, year: 2026), 257_700)
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 740_000, column: .otsu, year: 2026), 259_200)
    }

    func testOtsuWithholding_aboveFormulaThreshold() {
        // Above 740,000: 259,200 + 40.84% of the excess.
        let tax = IncomeTax.monthlyWithholding(grossPay: 800_000, column: .otsu, year: 2026)
        XCTAssertEqual(tax, 283_704)
    }

    func testOtsuWithholding_topBandSwitchesTo45Percent() {
        // 1,710,000円以上: 655,400 + 45.945% of the excess (令和8年分).
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 2_000_000, column: .otsu, year: 2026), 788_640)
    }

    func testKouWithholding_salaryDeductionIsRoundedUp() {
        // 158,467 × 30% = 47,540.1 → 47,541 (切り上げ), so B = 55,925 and the tax is 2,854.97 → 2,850.
        // Without the round-up, B = 55,925.9 and the tax lands on 2,860.
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 158_467, column: .kou, year: 2026), 2_850)
    }

    func testFractionalPayJustBelowARowStillUsesThatRow() {
        // A pay total built from per-minute pay can be 124,999.99999…; it is ¥125,000 on the payslip.
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 124_999.999_999, column: .otsu, year: 2026), 4_700)
    }

    func testWithholdingFollowsThePaydayYearsTable() {
        // The same pay under 令和7年分 / 令和8年分 / 令和9年分 (deductions rose each year).
        // Expected values come from the NTA's 電算機計算の特例 for each year.
        let kou = [2025, 2026, 2027].map { IncomeTax.monthlyWithholding(grossPay: 175_000, column: .kou, dependentsCount: 1, hasSpouseAllowance: true, year: $0) }
        XCTAssertEqual(kou, [640, 210, 40])
        let kouSingle = [2025, 2026, 2027].map { IncomeTax.monthlyWithholding(grossPay: 120_000, column: .kou, year: $0) }
        XCTAssertEqual(kouSingle, [1_740, 890, 550])
        // 乙欄: 110,999 is inside the printed rows for 2025/2026 but below the 2027 table (3.063%).
        let otsu = [2025, 2026, 2027].map { IncomeTax.monthlyWithholding(grossPay: 110_999, column: .otsu, year: $0) }
        XCTAssertEqual(otsu, [3_900, 3_900, 3_399])
        let otsuAt740k = [2025, 2026, 2027].map { IncomeTax.monthlyWithholding(grossPay: 740_000, column: .otsu, year: $0) }
        XCTAssertEqual(otsuAt740k, [259_800, 259_200, 259_000])
    }

    func testYearsWithoutAPublishedTableUseTheNearestOne() {
        XCTAssertEqual(IncomeTax.tableYear(for: 2023), 2025)
        XCTAssertEqual(IncomeTax.tableYear(for: 2026), 2026)
        XCTAssertEqual(IncomeTax.tableYear(for: 2030), 2027)
        XCTAssertEqual(IncomeTax.monthlyWithholding(grossPay: 120_000, column: .kou, year: 2030),
                       IncomeTax.monthlyWithholding(grossPay: 120_000, column: .kou, year: 2027))
    }

    // MARK: - Break without a start time: payslip must agree with the shift's own pay

    func testMonthlyPayslipDeductsUntimedBreakLikeTheShiftDoes() {
        // 9:00–17:00, 60 min break with no start time, ¥1,100/h: the shift itself pays 7h, ¥7,700.
        // The payslip used to add up the pre-break components and report ¥8,800.
        let shift = Shift(date: "2026-09-11", employer: "カフェ",
                          segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1100)],
                          breakMinutes: 60, breakStartMinute: nil)
        let cls = PayCalculation.buildEmployerClassifications([shift])
        let shiftPay = PayCalculation.pay(for: shift, classifications: cls)
        XCTAssertEqual(shiftPay.netPay, 7_700, accuracy: 0.001)

        let slip = Aggregation.calculateMonthlyPay([shift], classifications: cls)
        XCTAssertEqual(slip.grossTotal, shiftPay.netPay, accuracy: 0.001)
        XCTAssertEqual(slip.breakDeduction, 1_100, accuracy: 0.001)
    }

    func testIncomeTaxBaseExcludesUntimedBreak() {
        // Same shift at 乙欄: the taxable gross is the ¥7,700 actually paid, not ¥8,800.
        let shift = Shift(date: "2026-09-11", employer: "カフェ",
                          segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1100)],
                          breakMinutes: 60, breakStartMinute: nil)
        let cls = PayCalculation.buildEmployerClassifications([shift])
        let rows = Aggregation.calculateIncomeTax([shift], classifications: cls,
                                                  profiles: [EmployerProfile(name: "カフェ", incomeTaxColumn: .otsu)], year: 2026)
        XCTAssertEqual(rows.first?.taxableGross ?? 0, 7_700, accuracy: 0.001)
    }

    func testTimedBreakIsUnaffected() {
        // A break with a start time already removes the minutes themselves — no extra deduction.
        let shift = Shift(date: "2026-09-11", employer: "カフェ",
                          segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1100)],
                          breakMinutes: 60, breakStartMinute: 12 * 60)
        let cls = PayCalculation.buildEmployerClassifications([shift])
        let slip = Aggregation.calculateMonthlyPay([shift], classifications: cls)
        XCTAssertEqual(slip.grossTotal, 7_700, accuracy: 0.001)
        XCTAssertEqual(slip.breakDeduction, 0, accuracy: 0.001)
    }

    // MARK: - 月60時間超の法定時間外労働 (5割増)

    /// 12h days, Mon–Sat, for four weeks: 4h of daily legal overtime each worked day. The first
    /// 60 hours of that stay at 2割増; everything past it must move to 5割増.
    private func heavyOvertimeMonth() -> [Shift] {
        var shifts: [Shift] = []
        // 2026-09-01 is a Tuesday; take 24 working days across the month, skipping Sundays.
        var day = 1
        while day <= 29 {
            let date = String(format: "2026-09-%02d", day)
            let weekday = DateUtils.calendar.component(.weekday, from: DateUtils.date(year: 2026, month: 9, day: day))
            if weekday != 1 { // skip Sunday
                shifts.append(Shift(date: date, employer: "工場",
                                    segments: [WorkSegment(startMinute: 8 * 60, endMinute: 20 * 60, hourlyWage: 1000)]))
            }
            day += 1
        }
        return shifts
    }

    func testOvertimeBeyondSixtyHoursAMonthMovesToFiftyPercent() {
        let shifts = heavyOvertimeMonth()
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let buckets = classifications["工場"]!.values.flatMap { $0.minutes.map(\.bucket) }

        let legalOT = buckets.filter { $0 == .dailyLegalOvertime || $0 == .weeklyLegalOvertime }.count
        let extended = buckets.filter { $0 == .extendedMonthlyOvertime }.count

        // The month's legal overtime is split at exactly the 60-hour line, not rounded or dropped.
        XCTAssertEqual(legalOT, PayrollConstants.monthlyOvertimeThresholdMinutes)
        XCTAssertGreaterThan(extended, 0)
    }

    func testPromotedOvertimeIsPaidAtTheHigherRate() {
        let shifts = heavyOvertimeMonth()
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        // The last worked day of the month is past the 60-hour line, so its overtime minutes are
        // all at 5割増 — double the extra that the same minutes earn earlier in the month.
        let last = shifts.max { $0.date < $1.date }!
        let first = shifts.min { $0.date < $1.date }!
        let lastPay = PayCalculation.pay(for: last, classifications: classifications)
        let firstPay = PayCalculation.pay(for: first, classifications: classifications)
        XCTAssertEqual(lastPay.overtimeMinutes, firstPay.overtimeMinutes)
        XCTAssertEqual(lastPay.overtimeExtra, firstPay.overtimeExtra * 2, accuracy: 0.01)
    }

    func testOrdinaryMonthNeverReachesTheSixtyHourTier() {
        // A normal part-time month: no minute should be promoted, so nobody sees a surprise 5割増.
        let shifts = (1...8).map { i in
            Shift(date: String(format: "2026-09-%02d", i), employer: "カフェ",
                  segments: [WorkSegment(startMinute: 9 * 60, endMinute: 18 * 60, hourlyWage: 1100)])
        }
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let promoted = classifications["カフェ"]!.values
            .flatMap { $0.minutes }
            .filter { $0.bucket == .extendedMonthlyOvertime }
        XCTAssertTrue(promoted.isEmpty)
    }

    // MARK: - Per-employer withholding (double-job / 掛け持ち)

    func testIncomeTaxIsComputedSeparatelyPerEmployerNotCombined() {
        // Two employers, each paying an amount that's tax-free alone (well under any
        // threshold) but would land in a much higher bracket if wrongly summed together.
        let mainJob = Shift(date: "2026-09-01", employer: "メイン", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1200)])
        let sideJob = Shift(date: "2026-09-02", employer: "サブ", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 13 * 60, hourlyWage: 1000)])
        let shifts = [mainJob, sideJob]
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let profiles = [
            EmployerProfile(name: "メイン", incomeTaxColumn: .kou),
            EmployerProfile(name: "サブ", incomeTaxColumn: .otsu),
        ]
        let results = Aggregation.calculateIncomeTax(shifts, classifications: classifications, profiles: profiles, year: 2026)
        XCTAssertEqual(results.count, 2)
        let main = results.first { $0.employer == "メイン" }
        let sub = results.first { $0.employer == "サブ" }
        XCTAssertEqual(main?.column, .kou)
        XCTAssertEqual(main?.tax, 0) // ¥9,600 gross, 甲欄 0人 table shows 0 well below 105,000
        XCTAssertEqual(sub?.column, .otsu)
        XCTAssertEqual(sub?.tax, 122) // ¥4,000 gross, 乙欄 3.063% = 122.52, fraction dropped
    }

    func testSocialInsuranceReducesWithholding() {
        // 乙欄 makes the effect checkable by hand: the flat 3.063% band applies to
        // (gross − 社会保険料), so premiums must move the tax, not be ignored. This used to fail —
        // Aggregation never forwarded the premiums, so every user paying 社会保険 was shown a
        // higher tax and a lower 手取り than they actually get.
        let shift = Shift(date: "2026-09-01", employer: "サブ", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1200)])
        let classifications = PayCalculation.buildEmployerClassifications([shift])
        let profiles = [EmployerProfile(name: "サブ", incomeTaxColumn: .otsu)]

        let withPremiums = Aggregation.calculateIncomeTax([shift], classifications: classifications, profiles: profiles, socialInsurance: 1_400, year: 2026)
        XCTAssertEqual(withPremiums.first?.tax, 251) // 8,200 × 3.063% = 251.17

        let withoutPremiums = Aggregation.calculateIncomeTax([shift], classifications: classifications, profiles: profiles, year: 2026)
        XCTAssertEqual(withoutPremiums.first?.tax, 294) // 9,600 × 3.063% = 294.05
        XCTAssertLessThan(withPremiums.first!.tax, withoutPremiums.first!.tax)
    }

    func testSocialInsuranceSplitsAcrossEmployersByPay() {
        // Premiums are recorded per month, not per employer, so a two-job month has to divide
        // them — by share of taxable pay, since that's what drove them.
        let big = Shift(date: "2026-09-01", employer: "A", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1000)])   // ¥8,000
        let small = Shift(date: "2026-09-02", employer: "B", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 13 * 60, hourlyWage: 1000)]) // ¥4,000
        let shifts = [big, small]
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let profiles = [
            EmployerProfile(name: "A", incomeTaxColumn: .otsu),
            EmployerProfile(name: "B", incomeTaxColumn: .otsu),
        ]
        let results = Aggregation.calculateIncomeTax(shifts, classifications: classifications, profiles: profiles, socialInsurance: 1_200, year: 2026)
        // A earns two thirds of the ¥12,000 total, so it absorbs ¥800 of the ¥1,200; B takes ¥400.
        XCTAssertEqual(results.first { $0.employer == "A" }?.tax, 220) // 7,200 × 3.063% = 220.54
        XCTAssertEqual(results.first { $0.employer == "B" }?.tax, 110) // 3,600 × 3.063% = 110.27
    }

    func testSocialInsuranceGoesToTheMainJobNotTheSideJob() {
        // Main job (甲欄) ¥200,000 with ¥30,000 of premiums; side job (乙欄) ¥50,000 with none.
        // The side job withheld no premiums, so it may not subtract any.
        let main = Shift(date: "2026-09-01", employer: "メイン", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 25_000)])
        let side = Shift(date: "2026-09-02", employer: "サブ", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 14 * 60, hourlyWage: 10_000)])
        let shifts = [main, side]
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let profiles = [EmployerProfile(name: "メイン", incomeTaxColumn: .kou), EmployerProfile(name: "サブ", incomeTaxColumn: .otsu)]
        let rows = Aggregation.calculateIncomeTax(shifts, classifications: classifications, profiles: profiles,
                                                  socialInsurance: 30_000, year: 2026)
        XCTAssertEqual(rows.first { $0.employer == "メイン" }?.tax, 3_270) // 甲欄 on 170,000
        XCTAssertEqual(rows.first { $0.employer == "サブ" }?.tax, 1_531)   // 乙欄 3.063% of 50,000
    }

    func testIncomeTaxDefaultsToKouWithNoSavedProfile() {
        // No EmployerProfile on file at all — still taxed (as 甲欄, the sane default for
        // someone's only job), not silently skipped.
        let shift = Shift(date: "2026-09-01", employer: "無登録", segments: [WorkSegment(startMinute: 9 * 60, endMinute: 17 * 60, hourlyWage: 1200)])
        let classifications = PayCalculation.buildEmployerClassifications([shift])
        let results = Aggregation.calculateIncomeTax([shift], classifications: classifications, profiles: [], year: 2026)
        XCTAssertEqual(results.first?.column, .kou)
    }

    // MARK: - Japanese national holidays

    func testPaydaysSkipTheYearEndBankHolidays() {
        // 銀行法施行令5条: banks are closed 12/31〜1/3, so no salary transfer happens then.
        // 末日払い・翌営業日: November's pay (due Thu 12/31) is paid Mon 2027-01-04 — next tax year.
        XCTAssertEqual(PayPeriod.paymentDate(periodEnd: "2026-11-30", paydayMonthOffset: 1, paydayDay: 31,
                                             adjustment: .afterBusinessDay), "2027-01-04")
        XCTAssertEqual(PayPeriod.paymentDate(periodEnd: "2026-11-30", paydayMonthOffset: 1, paydayDay: 31,
                                             adjustment: .beforeBusinessDay), "2026-12-30")
        // 翌々月5日払い due Sun 2025-01-05, paid early: past 1/4 (Sat), 1/3〜1/1 and 12/31 to Mon 12/30.
        XCTAssertEqual(PayPeriod.paymentDate(periodEnd: "2024-11-30", paydayMonthOffset: 2, paydayDay: 5,
                                             adjustment: .beforeBusinessDay), "2024-12-30")
        // The 祝日法 holiday calendar itself is unchanged.
        XCTAssertFalse(JapaneseHolidays.isHoliday("2026-12-31"))
    }

    func testCitizensHolidayBetweenTwoHolidays() {
        // 祝日法第3条第3項: 2026-09-22 sits between 敬老の日 (9/21) and 秋分の日 (9/23).
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-09-22"))
        XCTAssertFalse(JapaneseHolidays.isHoliday("2026-09-24"))
        // A payday on the 22nd rolls back past the whole run of holidays to Friday 9/18.
        XCTAssertEqual(PayPeriod.paymentDate(periodEnd: "2026-08-31", paydayMonthOffset: 1, paydayDay: 22,
                                             adjustment: .beforeBusinessDay), "2026-09-18")
    }

    func testFixedDateHolidays() {
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-01-01")) // 元日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-02-11")) // 建国記念の日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-02-23")) // 天皇誕生日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-04-29")) // 昭和の日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-05-03")) // 憲法記念日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-05-04")) // みどりの日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-05-05")) // こどもの日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-08-11")) // 山の日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-11-03")) // 文化の日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2026-11-23")) // 勤労感謝の日
        XCTAssertFalse(JapaneseHolidays.isHoliday("2026-06-15")) // an ordinary Monday
    }

    func testHappyMondayHolidays_2024() {
        // Verified against the actual 2024 Japanese holiday calendar.
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-01-08")) // 成人の日 (2nd Mon of Jan)
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-07-15")) // 海の日 (3rd Mon of Jul)
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-09-16")) // 敬老の日 (3rd Mon of Sep)
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-10-14")) // スポーツの日 (2nd Mon of Oct)
    }

    func testEquinoxHolidays_2024() {
        // Verified against the actual government-announced 2024 equinox dates.
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-03-20")) // 春分の日
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-09-22")) // 秋分の日
        XCTAssertFalse(JapaneseHolidays.isHoliday("2024-03-21"))
    }

    func testSubstituteHoliday_2024MountainDayOnSunday() {
        // 2024-08-11 (山の日) was a Sunday, so 2024-08-12 (Monday) is 振替休日.
        XCTAssertTrue(JapaneseHolidays.isWeekend("2024-08-11"))
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-08-11"))
        XCTAssertTrue(JapaneseHolidays.isHoliday("2024-08-12"))
        XCTAssertFalse(JapaneseHolidays.isBusinessDay("2024-08-12"))
    }

    func testNearestBusinessDayRollsBackPastWeekendAndHoliday() {
        // Backward from 2024-08-11 (Sun + holiday): 08-10 is Sat (weekend), 08-09 is the first
        // business day.
        XCTAssertEqual(JapaneseHolidays.nearestBusinessDay("2024-08-11", direction: .backward), "2024-08-09")
    }

    func testPaymentDateAdjustsForWeekendPayday() {
        // A raw payday of 2024-08-11 (Sunday + holiday), with the default "pay early" rule,
        // should move to the preceding business day.
        let adjusted = PayPeriod.paymentDate(periodEnd: "2024-08-01", paydayMonthOffset: 0, paydayDay: 11, adjustment: .beforeBusinessDay)
        XCTAssertEqual(adjusted, "2024-08-09")
    }

    func testPaymentDateUnadjustedWhenRequested() {
        let raw = PayPeriod.paymentDate(periodEnd: "2024-08-01", paydayMonthOffset: 0, paydayDay: 11, adjustment: .none)
        XCTAssertEqual(raw, "2024-08-11")
    }
}

final class ReleasePayPeriodTests: XCTestCase {
    func testHolidayRollingRetainsTwoPeriodsInJuly() {
        let profile = EmployerProfile(name: "Cafe", closingDay: 0, paydayMonthOffset: 1, paydayDay: 1, paydayAdjustment: .beforeBusinessDay)
        let periods = PayPeriod.periods(paidInMonth: "2026-07", profile: profile)
        XCTAssertEqual(periods.map(\.periodEnd), ["2026-06-30", "2026-07-31"])
        let segment = WorkSegment(startMinute: 540, endMinute: 600, hourlyWage: 1200)
        let december = Shift(date: "2026-06-15", employer: "Cafe", segments: [segment])
        let january = Shift(date: "2026-07-15", employer: "Cafe", segments: [segment])
        let february = Shift(date: "2026-08-15", employer: "Cafe", segments: [segment])
        let selected = PayPeriod.shifts(paidInMonth: "2026-07", shifts: [december, january, february, january], profiles: [profile])
        XCTAssertEqual(selected.map(\.id), [december.id, january.id])
    }
    func testTenthClosingTwentyFifthPaydayKeepsWorkInCorrectMonth() {
        let profile = EmployerProfile(name: "Cafe", closingDay: 10, paydayMonthOffset: 0, paydayDay: 25, paydayAdjustment: .none)
        let segment = WorkSegment(startMinute: 540, endMinute: 600, hourlyWage: 1200)
        let before = Shift(date: "2026-09-10", employer: "Cafe", segments: [segment])
        let after = Shift(date: "2026-09-11", employer: "Cafe", segments: [segment])
        XCTAssertEqual(PayPeriod.shifts(paidInMonth: "2026-09", shifts: [before, after], profiles: [profile]).map(\.id), [before.id])
        XCTAssertEqual(PayPeriod.shifts(paidInMonth: "2026-10", shifts: [before, after], profiles: [profile]).map(\.id), [after.id])
    }
}

final class ReleaseShiftTemplateTests: XCTestCase {
    func testRepeatPreservesBreakAndPayConditionsWithoutCopyingHolidayStatus() {
        let source = Shift(date: "2026-09-01", employer: "Cafe",
            segments: [WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: 1200)],
            breakMinutes: 60, breakStartMinute: 720, transport: 500, otherAllowance: 100,
            isStatutoryHoliday: true, scheduledMinutes: 420, lateNightRate: 0.3, overtimeRate: 0.3, holidayRate: 0.4)
        let copy = source.repeated(on: "2026-10-01")
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.date, "2026-10-01")
        XCTAssertFalse(copy.isStatutoryHoliday)
        var expected = source
        expected.id = copy.id
        expected.date = copy.date
        expected.isStatutoryHoliday = false
        XCTAssertEqual(copy, expected)
        XCTAssertEqual(PayCalculation.estimateShiftPay(copy).netPay, 9000, accuracy: 0.001)
        XCTAssertEqual(source.breakMinutes, 60)
    }
}

final class AuditCalculationRegressionTests: XCTestCase {
    func testPreviewDoesNotPremiumScheduledOvertimeBelowEightHours() {
        let shift = Shift(date: "2026-10-01", employer: "A", segments: [WorkSegment(startMinute: 540, endMinute: 960, hourlyWage: 1200)], scheduledMinutes: 360)
        let saved = PayCalculation.pay(for: shift, classifications: PayCalculation.buildEmployerClassifications([shift]))
        XCTAssertEqual(saved.netPay, 8400, accuracy: 0.001)
        XCTAssertEqual(PayCalculation.estimateShiftPay(shift).netPay, saved.netPay, accuracy: 0.001)
    }
    func testUntimedBreakDoesNotReduceEarnedOvertimePremium() {
        let shift = Shift(date: "2026-10-01", employer: "A", segments: [WorkSegment(startMinute: 540, endMinute: 1140, hourlyWage: 1200)], breakMinutes: 60)
        let pay = PayCalculation.pay(for: shift, classifications: PayCalculation.buildEmployerClassifications([shift]))
        // Nine actual hours: 9 * 1200 + one hour's 25% premium.
        XCTAssertEqual(pay.overtimeMinutes, 60)
        XCTAssertEqual(pay.netPay, 11100, accuracy: 0.001)
        var precise = shift
        precise.breakStartMinute = 720
        let exact = PayCalculation.pay(for: precise, classifications: PayCalculation.buildEmployerClassifications([precise]))
        XCTAssertEqual(pay.netPay, exact.netPay, accuracy: 0.001)
    }
    func testEightHoursOfActualWorkNeedsFortyFiveNotSixtyMinutes() {
        XCTAssertNil(Validation.breakHint(netMinutes: 360))
        XCTAssertEqual(Validation.breakHint(netMinutes: 480), "6時間超の勤務のため、法律上は休憩45分以上が必要です")
        XCTAssertEqual(Validation.breakHint(netMinutes: 481), "8時間超の勤務のため、法律上は休憩60分以上が必要です")
    }
}

final class AuditPaydayReceiptTests: XCTestCase {
    func testReceiptSurvivesProfileDeletionAndPaydayChanges() {
        let receipt = ActualPayment(employer: "A", payDate: "2026-10-25", amount: 123456)
        let deleted = Aggregation.paydayIncomeEntries(month: "2026-10", shifts: [], profiles: [], actualPayments: [receipt], classifications: [:])
        XCTAssertEqual(deleted.map(\.amount), [123456])
        let changed = EmployerProfile(name: "A", paydayDay: 15)
        XCTAssertEqual(Aggregation.paydayIncomeEntries(month: "2026-10", shifts: [], profiles: [changed], actualPayments: [receipt], classifications: [:]), deleted)
        XCTAssertTrue(Aggregation.paydayIncomeEntries(month: "2026-11", shifts: [], profiles: [], actualPayments: [receipt], classifications: [:]).isEmpty)
    }
    func testActualReceiptReplacesEstimateWithoutDoubleCounting() {
        let profile = EmployerProfile(name: "A", paydayDay: 25, paydayAdjustment: .none)
        let shift = Shift(date: "2026-09-10", employer: "A", segments: [WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: 1200)])
        let receipt = ActualPayment(employer: "A", payDate: "2026-10-25", amount: 9000)
        let entries = Aggregation.paydayIncomeEntries(month: "2026-10", shifts: [shift], profiles: [profile], actualPayments: [receipt], classifications: PayCalculation.buildEmployerClassifications([shift]))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].amount, 9000)
        XCTAssertTrue(entries[0].isActual)
    }
    func testPreviewIncludesExistingDailyWorkAndDoesNotDuplicateEditedShift() {
        let first = Shift(date: "2026-10-01", employer: "A", segments: [WorkSegment(startMinute: 540, endMinute: 780, hourlyWage: 1200)])
        let second = Shift(date: "2026-10-01", employer: "A", segments: [WorkSegment(startMinute: 840, endMinute: 1200, hourlyWage: 1200)])
        let preview = PayCalculation.estimateShiftPay(second, allShifts: [first, second])
        XCTAssertEqual(preview.overtimeMinutes, 120)
        XCTAssertEqual(preview.netPay, 7800, accuracy: 0.001)
    }
}

final class AuditInputTests: XCTestCase {
    func testBreakAcrossMidnightAndEqualTimes() {
        XCTAssertEqual(Validation.breakDurationMinutes(start: 1410, end: 30), 60)
        XCTAssertEqual(Validation.breakDurationMinutes(start: 720, end: 780), 60)
        XCTAssertEqual(Validation.breakDurationMinutes(start: 720, end: 720), 0)
    }
    func testInvalidScheduledHoursCannotCrashIntegerConversion() {
        for hours in [Double.nan, Double.infinity, -1, 1e100, 25] {
            XCTAssertEqual(Validation.scheduledMinutes(hours: hours), 0)
        }
        XCTAssertEqual(Validation.scheduledMinutes(hours: 7.5), 450)
    }
    func testRejectInvalidWageBreakAndEmptySegments() {
        func errors(_ segments: [WorkSegment], _ minutes: Int = 0) -> [String] {
            Validation.validateShift(segments: segments, breakMinutes: minutes, breakStartMinute: nil, lateNightRate: 0.25, overtimeRate: 0.25, holidayRate: 0.35)
        }
        XCTAssertFalse(errors([]).isEmpty)
        XCTAssertFalse(errors([WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: .nan)]).isEmpty)
        XCTAssertFalse(errors([WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: 1200)], -1).isEmpty)
    }
}

final class AuditOvernightSegmentTests: XCTestCase {
    func testPostMidnightWageSegmentCarriesTheLatestOvertime() {
        let shift = Shift(date: "2026-10-01", employer: "A", segments: [
            WorkSegment(startMinute: 1320, endMinute: 120, hourlyWage: 1000),
            WorkSegment(startMinute: 120, endMinute: 480, hourlyWage: 2000)
        ], lateNightRate: 0)
        let pay = PayCalculation.pay(for: shift, classifications: PayCalculation.buildEmployerClassifications([shift]))
        XCTAssertEqual(pay.overtimeMinutes, 120)
        XCTAssertEqual(pay.netPay, 17000, accuracy: 0.001)
    }
    func testOverlappingPostMidnightSegmentsAreRejected() {
        let errors = Validation.validateShift(segments: [
            WorkSegment(startMinute: 1320, endMinute: 120, hourlyWage: 1000),
            WorkSegment(startMinute: 60, endMinute: 360, hourlyWage: 2000)
        ], breakMinutes: 0, breakStartMinute: nil, lateNightRate: 0.25, overtimeRate: 0.25, holidayRate: 0.35)
        XCTAssertFalse(errors.isEmpty)
    }
}
