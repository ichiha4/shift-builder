import XCTest
@testable import PayrollEngine

final class IncomeWallsTests: XCTestCase {

    // MARK: - Limits: derived from 合計所得, checked against the published 給与収入 figures

    func testDerivedLimitsMatchPublishedFigures() {
        // 国税庁: 本人の所得税 — 基礎控除104万円 + 給与所得控除74万円.
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.basicDeduction), 1_780_000)
        // 扶養控除・配偶者控除: 合計所得62万円以下.
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.dependentIncomeCap), 1_360_000)
        // 特定親族特別控除: 満額は合計所得85万円まで; No.1177 本文「給与収入が197万円以下」.
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.specificRelativeFullCap), 1_590_000)
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.specificRelativeCap), 1_970_000)
        // 配偶者特別控除: 満額は合計所得95万円まで、133万円まで.
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.spouseSpecialFullCap), 1_690_000)
        XCTAssertEqual(IncomeWalls.salaryRevenue(forIncome: IncomeWalls.spouseSpecialCap), 2_070_000)
    }

    func testEveryDerivedLimitIsInsideTheBandWhereIncomeIsRevenueMinus740k() {
        // No.1410 注2: 給与所得 = 収入 − 74万円 holds for 74万1,000円 ≤ 収入 < 219万1,000円 only.
        let caps = [IncomeWalls.basicDeduction, IncomeWalls.dependentIncomeCap,
                    IncomeWalls.specificRelativeFullCap, IncomeWalls.specificRelativeCap,
                    IncomeWalls.spouseSpecialFullCap, IncomeWalls.spouseSpecialCap]
        for cap in caps {
            let revenue = IncomeWalls.salaryRevenue(forIncome: cap)
            XCTAssertGreaterThanOrEqual(revenue, 741_000, "\(cap)")
            XCTAssertLessThan(revenue, 2_191_000, "\(cap)")
        }
    }

    // MARK: - Ages (令和8年分 扶養控除等申告書 birth-date ranges)

    func testAgeAtYearEndMatchesTheNTABirthDateRanges() {
        // 特定扶養親族・特定親族: 平成16年1月2日〜平成20年1月1日生まれ = 19〜22歳.
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2008, birthMonth: 1, birthDay: 1, year: 2026), 19)
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2008, birthMonth: 1, birthDay: 2, year: 2026), 18)
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2004, birthMonth: 1, birthDay: 2, year: 2026), 22)
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2004, birthMonth: 1, birthDay: 1, year: 2026), 23)
        // 控除対象扶養親族: 平成23年1月1日以前 = 16歳以上.
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2011, birthMonth: 1, birthDay: 1, year: 2026), 16)
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 2011, birthMonth: 1, birthDay: 2, year: 2026), 15)
        // 老人: 昭和32年1月1日以前 = 70歳以上.
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 1957, birthMonth: 1, birthDay: 1, year: 2026), 70)
        XCTAssertEqual(IncomeWalls.ageAtYearEnd(birthYear: 1957, birthMonth: 1, birthDay: 2, year: 2026), 69)
    }

    func testAgeOnDateTurnsOnTheBirthday() {
        XCTAssertEqual(IncomeWalls.age(birthYear: 1966, birthMonth: 10, birthDay: 1, onYear: 2026, month: 9, day: 30), 59)
        XCTAssertEqual(IncomeWalls.age(birthYear: 1966, birthMonth: 10, birthDay: 1, onYear: 2026, month: 10, day: 1), 60)
    }

    // MARK: - Which walls apply

    private func limits(_ dependency: IncomeWalls.Dependency, born: String, year: Int = 2026,
                        today: String = "2026-09-26") -> [IncomeWalls.Kind: Int] {
        let walls = IncomeWalls.walls(year: year, dependency: dependency, birthDate: born, today: today)!
        return Dictionary(uniqueKeysWithValues: walls.map { ($0.kind, $0.limit) })
    }

    func testUniversityStudentSupportedByParents() {
        let w = limits(.parent, born: "2006-05-10") // 20 at year end
        XCTAssertEqual(w, [
            .healthInsuranceDependent: 1_500_000,
            .specificRelativeDeductionDecreases: 1_590_000,
            .ownIncomeTax: 1_780_000,
            .specificRelativeDeductionEnds: 1_970_000,
        ])
    }

    func testHighSchoolerSupportedByParents() {
        let w = limits(.parent, born: "2009-06-01") // 17
        XCTAssertEqual(w, [
            .healthInsuranceDependent: 1_300_000,
            .dependentDeductionEnds: 1_360_000,
            .ownIncomeTax: 1_780_000,
        ])
    }

    func testUnder16HasNoParentTaxWall() {
        // 年少扶養親族: the parent gets no 扶養控除 at any income, so there is nothing to lose.
        let w = limits(.parent, born: "2012-03-01") // 14
        XCTAssertEqual(w, [.healthInsuranceDependent: 1_300_000, .ownIncomeTax: 1_780_000])
    }

    func testSpouse() {
        let w = limits(.spouse, born: "1990-04-04")
        XCTAssertEqual(w, [
            .healthInsuranceDependent: 1_300_000,
            .spouseSpecialDeductionDecreases: 1_690_000,
            .ownIncomeTax: 1_780_000,
            .spouseSpecialDeductionEnds: 2_070_000,
        ])
    }

    func testSpouseAged19To22StillUses130NotThe150Rule() {
        // 日本年金機構: the 150万円 rule excludes spouses.
        XCTAssertEqual(limits(.spouse, born: "2005-07-07")[.healthInsuranceDependent], 1_300_000)
    }

    func testSpouse70PlusLosesTheElderlyPremiumAt136() {
        let w = limits(.spouse, born: "1955-02-02")
        XCTAssertEqual(w[.elderlySpouseDeductionReduced], 1_360_000)
        XCTAssertEqual(w[.healthInsuranceDependent], 1_800_000) // 60歳以上
    }

    func testSixtyPlusUses180ForHealthInsurance() {
        XCTAssertEqual(limits(.parent, born: "1960-01-15")[.healthInsuranceDependent], 1_800_000)
    }

    func testHealthLimitFollowsTodaysYearNotTheYearOnScreen() {
        // The 19〜22 test for 健康保険 reads the 12/31 age of the year that contains today.
        // 18 at the end of 2026, 19 at the end of 2027: the 2027 tax walls are the 19〜22 ones,
        // but today's health limit is still 130万円.
        let next = limits(.parent, born: "2008-06-01", year: 2027, today: "2026-09-28")
        XCTAssertEqual(next[.healthInsuranceDependent], 1_300_000)
        XCTAssertEqual(next[.specificRelativeDeductionDecreases], 1_590_000)
        // Looking back at 2026 from 2027, the year they turn 23: 130万円 now.
        XCTAssertEqual(limits(.parent, born: "2004-06-01", year: 2026, today: "2027-02-10")[.healthInsuranceDependent], 1_300_000)
        XCTAssertEqual(limits(.parent, born: "2004-06-01", year: 2027, today: "2026-09-28")[.healthInsuranceDependent], 1_500_000)
    }

    func testSocialInsuranceAgeRisesTheDayBeforeTheBirthday() {
        // 厚労省 Q&A: 「年齢は誕生日の前日において加算する」.
        XCTAssertEqual(IncomeWalls.socialInsuranceAge(birthDate: "1966-09-29", today: "2026-09-28"), 60)
        XCTAssertEqual(IncomeWalls.socialInsuranceAge(birthDate: "1966-09-30", today: "2026-09-28"), 59)
        XCTAssertEqual(limits(.spouse, born: "1966-09-29", today: "2026-09-28")[.healthInsuranceDependent], 1_800_000)
        XCTAssertEqual(limits(.spouse, born: "1966-09-30", today: "2026-09-28")[.healthInsuranceDependent], 1_300_000)
    }

    func testNoHealthInsuranceWallFromThe75thBirthday() {
        // 後期高齢者医療 starts on the 75th birthday itself — not the day before, unlike the other
        // age tests — and from then nobody can be a 被扶養者.
        XCTAssertNil(limits(.spouse, born: "1951-09-28", today: "2026-09-28")[.healthInsuranceDependent])
        XCTAssertEqual(limits(.spouse, born: "1951-09-29", today: "2026-09-28")[.healthInsuranceDependent], 1_800_000)
        XCTAssertNil(limits(.parent, born: "1950-01-15", today: "2026-09-28")[.healthInsuranceDependent])
    }

    func testNotADependentOnlyHasOwnIncomeTax() {
        XCTAssertEqual(limits(.none, born: "2000-01-01"), [.ownIncomeTax: 1_780_000])
    }

    func testUnsupportedYearsReturnNil() {
        XCTAssertNil(IncomeWalls.walls(year: 2025, dependency: .none, birthDate: nil, today: "2025-06-01"))
        XCTAssertNil(IncomeWalls.walls(year: 2028, dependency: .none, birthDate: nil, today: "2028-06-01"))
        XCTAssertNotNil(IncomeWalls.walls(year: 2027, dependency: .none, birthDate: nil, today: "2027-06-01"))
    }

    // MARK: - Boundaries: 以下 vs 未満

    func testTaxLimitIsInclusiveHealthLimitIsNot() {
        let tax = IncomeWalls.Wall(kind: .ownIncomeTax, basis: .taxYear, limit: 1_780_000, stayUnderInclusive: true)
        XCTAssertFalse(tax.isExceeded(by: 1_780_000))
        XCTAssertTrue(tax.isExceeded(by: 1_780_001))
        let health = IncomeWalls.Wall(kind: .healthInsuranceDependent, basis: .forwardYear, limit: 1_500_000, stayUnderInclusive: false)
        XCTAssertFalse(health.isExceeded(by: 1_499_999))
        XCTAssertTrue(health.isExceeded(by: 1_500_000))
    }

    func testMonthlyEquivalentMatchesTheOfficial108333() {
        // 日本年金機構: 130万円 ↔「月額108,333円以下」.
        let w130 = IncomeWalls.Wall(kind: .healthInsuranceDependent, basis: .forwardYear, limit: 1_300_000, stayUnderInclusive: false)
        XCTAssertEqual(w130.monthlyEquivalent, 108_333)
        let w150 = IncomeWalls.Wall(kind: .healthInsuranceDependent, basis: .forwardYear, limit: 1_500_000, stayUnderInclusive: false)
        XCTAssertEqual(w150.monthlyEquivalent, 124_999)
        XCTAssertLessThan(Double(w150.monthlyEquivalent * 12), 1_500_000)
    }

    // MARK: - Annual income

    private func shift(_ date: String, _ employer: String = "店", hours: Int = 1, wage: Double = 1000,
                       transport: Double = 0, breakMinutes: Int = 0) -> Shift {
        Shift(date: date, employer: employer,
              segments: [WorkSegment(startMinute: 9 * 60, endMinute: (9 + hours) * 60, hourlyWage: wage)],
              breakMinutes: breakMinutes, transport: transport)
    }

    private func income(_ shifts: [Shift], profiles: [EmployerProfile], year: Int = 2026, today: String) -> IncomeWalls.AnnualIncome {
        IncomeWalls.annualIncome(year: year, today: today, shifts: shifts, profiles: profiles,
                                 classifications: PayCalculation.buildEmployerClassifications(shifts))
    }

    /// 末締め翌月25日払い, no weekend shift so paydays stay put.
    private let monthEndNextMonth25 = EmployerProfile(name: "店", closingDay: 0, paydayMonthOffset: 1,
                                                      paydayDay: 25, paydayAdjustment: .none)

    func testTaxYearIsCountedByPaydayNotWorkDate() {
        // Worked 2025-12 → paid 2026-01-25: this year. Worked 2026-12 → paid 2027-01-25: next year.
        let shifts = [shift("2025-12-10", hours: 8), shift("2026-11-10", hours: 8), shift("2026-12-10", hours: 8)]
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-12-31")
        XCTAssertEqual(r.projectedTotal, 16_000, accuracy: 0.001)
        XCTAssertEqual(r.paidToDate, 16_000, accuracy: 0.001)
    }

    func testTransportIsLeftOutOfTaxYearButCountedForHealthInsurance() {
        let shifts = (1...30).map { shift(String(format: "2026-06-%02d", $0), transport: 500) }
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-06-30")
        // Tax: June's ¥30,000 is paid 2026-07-25 — the 交通費 is not in it.
        XCTAssertEqual(r.scheduled, 30_000, accuracy: 0.001)
        // Health insurance: ¥1,500 a day including 交通費, annualised.
        XCTAssertEqual(r.forwardAnnualEstimate!, 1_500 * 365, accuracy: 0.001)
        XCTAssertFalse(r.paceIsTentative)
    }

    func testUntimedBreakIsNotCountedAsIncome() {
        let s = shift("2026-06-10", hours: 8, wage: 1100, breakMinutes: 60)
        let r = income([s], profiles: [monthEndNextMonth25], today: "2026-12-31")
        XCTAssertEqual(r.projectedTotal, 7_700, accuracy: 0.001)
    }

    func testProjectionFillsTheUnenteredDaysAtTheRecentPace() {
        // Every day from 2026-04-02 to today 2026-06-30 (90 days): ¥1,000 a day.
        var shifts: [Shift] = []
        var day = "2026-04-02"
        while day <= "2026-06-30" { shifts.append(shift(day)); day = IncomeWalls.addDays(day, 1) }
        XCTAssertEqual(shifts.count, 90)
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-06-30")
        XCTAssertEqual(r.paidToDate, 29_000 + 31_000, accuracy: 0.001)   // April (paid 5/25), May (paid 6/25)
        XCTAssertEqual(r.scheduled, 30_000, accuracy: 0.001)              // June, paid 7/25
        XCTAssertEqual(r.projectedExtra, 153_000, accuracy: 0.001)        // July–November, paid by 12/25
        XCTAssertEqual(r.projectedTotal, 243_000, accuracy: 0.001)
        XCTAssertEqual(r.taxablePerHour!, 1_000, accuracy: 0.001)
    }

    func testAPaydayAlreadyPastIsNeverProjected() {
        // 末締め当月25日払い: September is paid 9/25, before September ends. On 9/28 the last two
        // days of September must not be projected into a payday that has already happened.
        let sameMonth25 = EmployerProfile(name: "店", closingDay: 0, paydayMonthOffset: 0,
                                          paydayDay: 25, paydayAdjustment: .none)
        var shifts: [Shift] = []
        var day = "2026-07-01"
        while day <= "2026-09-28" { shifts.append(shift(day)); day = IncomeWalls.addDays(day, 1) }
        XCTAssertEqual(shifts.count, 90)
        let r = income(shifts, profiles: [sameMonth25], today: "2026-09-28")
        XCTAssertEqual(r.projectedExtra, (31 + 30 + 31) * 1_000, accuracy: 0.001) // Oct, Nov, Dec only
    }

    func testEmployerWithoutPaydayIsFlaggedAndCountedByMonthWorked() {
        let r = income([shift("2026-12-10", "未設定", hours: 8)], profiles: [], today: "2026-12-31")
        XCTAssertTrue(r.hasEmployerWithoutPayday)
        XCTAssertEqual(r.projectedTotal, 8_000, accuracy: 0.001)
    }

    func testUnconfiguredEmployerWithNothingThisYearDoesNotRaiseTheWarning() {
        let shifts = [shift("2024-05-10", "昔のバイト", hours: 8), shift("2026-09-10", hours: 8)]
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-09-28")
        XCTAssertFalse(r.hasEmployerWithoutPayday)
    }

    private func everyDay(_ from: String, through: String, _ employer: String = "店", hours: Int = 1) -> [Shift] {
        var out: [Shift] = []
        var day = from
        while day <= through { out.append(shift(day, employer, hours: hours)); day = IncomeWalls.addDays(day, 1) }
        return out
    }

    func testASecondJobIsPacedFromItsOwnStart() {
        // ¥1,000 a day at A for 90 days, and at B since 9/15. Both run at ¥1,000 a day, so the
        // health estimate is ¥730,000 — not B's two weeks spread over A's 90 days (¥421,778).
        let shifts = everyDay("2026-07-01", through: "2026-09-28", "A") + everyDay("2026-09-15", through: "2026-09-28", "B")
        let r = income(shifts, profiles: [], today: "2026-09-28")
        XCTAssertEqual(r.forwardAnnualEstimate!, 730_000, accuracy: 0.001)
        XCTAssertTrue(r.paceIsTentative) // B has two weeks of history
    }

    func testAFirstShiftIsSpreadOverAWeekNotTakenAsADailyRate() {
        // One ¥8,000 shift today and nothing else: a week's pace of ¥8,000, not ¥8,000 every day.
        let r = income([shift("2026-09-28", hours: 8)], profiles: [monthEndNextMonth25], today: "2026-09-28")
        XCTAssertEqual(r.forwardAnnualEstimate!, 8_000.0 / 7 * 365, accuracy: 0.001)
        // Projected from 9/29 through 11/30 (the last period paid in 2026): 63 days.
        XCTAssertEqual(r.projectedExtra, 8_000.0 / 7 * 63, accuracy: 0.001)
        XCTAssertTrue(r.paceIsTentative)
    }

    func testShiftsAlreadyEnteredForTheFirstWeekCountTowardThePace() {
        let shifts = ["2026-09-28", "2026-09-30", "2026-10-02"].map { shift($0, hours: 8) }
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-09-28")
        XCTAssertEqual(r.forwardAnnualEstimate!, 24_000.0 / 7 * 365, accuracy: 0.001)
    }

    func testOnlyWorkNotYetDoneIsAdjustable() {
        // 末締め翌月25日払い, today 11/15, shifts entered through 11/30. October's work is paid 11/25
        // but already done; only 11/16〜11/30 can still change 2026. December's work is paid in 2027.
        let r = income(everyDay("2026-10-01", through: "2026-11-30"), profiles: [monthEndNextMonth25], today: "2026-11-15")
        XCTAssertEqual(r.scheduled, 61_000, accuracy: 0.001)
        XCTAssertEqual(r.projectedExtra, 0, accuracy: 0.001)
        XCTAssertEqual(r.adjustable, 15_000, accuracy: 0.001)
        XCTAssertEqual(r.lastCountingWorkDate, "2026-11-30")
        XCTAssertEqual(r.cutBackDeadline, "2026-11-30")
    }

    func testEachEmployerHasItsOwnLastCountingWorkDate() {
        // カフェ closes on the 10th (翌月25日), so 2026 takes its work through 11/10; コンビニ closes at
        // month end, so through 11/30. No single date is true for both, so none is quoted.
        let tenth = EmployerProfile(name: "カフェ", closingDay: 10, paydayMonthOffset: 1, paydayDay: 25, paydayAdjustment: .none)
        let monthEnd = EmployerProfile(name: "コンビニ", closingDay: 0, paydayMonthOffset: 1, paydayDay: 25, paydayAdjustment: .none)
        let shifts = everyDay("2026-07-01", through: "2026-09-28", "カフェ", hours: 2)
            + everyDay("2026-07-01", through: "2026-09-28", "コンビニ")
        let r = income(shifts, profiles: [tenth, monthEnd], today: "2026-09-28")
        XCTAssertEqual(r.countingWorkEnd, ["カフェ": "2026-11-10", "コンビニ": "2026-11-30"])
        XCTAssertEqual(r.lastCountingWorkDate, "2026-11-30")
        XCTAssertNil(r.cutBackDeadline)
        // Both pay ¥1,000/h here; the range is what keeps hour advice on the safe side.
        XCTAssertEqual(r.lowestTaxablePerHour!, 1_000, accuracy: 0.001)
        XCTAssertEqual(r.highestTaxablePerHour!, 1_000, accuracy: 0.001)
    }

    func testHourlyRangeSpansTheCheapestAndDearestJob() {
        let shifts = [shift("2026-09-20", "A", hours: 4, wage: 1_100), shift("2026-09-21", "B", hours: 4, wage: 1_400)]
        let r = income(shifts, profiles: [], today: "2026-09-28")
        XCTAssertEqual(r.lowestTaxablePerHour!, 1_100, accuracy: 0.001)
        XCTAssertEqual(r.highestTaxablePerHour!, 1_400, accuracy: 0.001)
    }

    func testAnEndedJobDoesNotKeepTheYearOpen() {
        // An old job with nothing paid this year has no counting date at all.
        let shifts = [shift("2024-05-10", "昔のバイト", hours: 8)] + everyDay("2026-10-01", through: "2026-11-30")
        let r = income(shifts, profiles: [monthEndNextMonth25], today: "2026-12-10")
        XCTAssertEqual(r.countingWorkEnd, ["店": "2026-11-30"])
    }

    func testAJobThatHasNotStartedDoesNotMakeEstimatesTentative() {
        // A: five hours a day since July — well established, and over 130万 for health insurance.
        // One future shift at new job B (paid next year) changes neither figure, so neither may
        // turn into a greyed-out 目安.
        let a = everyDay("2026-07-03", through: "2026-09-30", "店", hours: 5)
        let alone = income(a, profiles: [monthEndNextMonth25], today: "2026-09-30")
        let bProfile = EmployerProfile(name: "B", closingDay: 0, paydayMonthOffset: 1, paydayDay: 25, paydayAdjustment: .none)
        let withB = income(a + [shift("2026-12-20", "B", hours: 5)], profiles: [monthEndNextMonth25, bProfile], today: "2026-09-30")
        XCTAssertEqual(withB.forwardAnnualEstimate!, alone.forwardAnnualEstimate!, accuracy: 0.001)
        XCTAssertEqual(withB.projectedTotal, alone.projectedTotal, accuracy: 0.001)
        XCTAssertFalse(withB.taxPaceIsTentative)
        XCTAssertFalse(withB.healthPaceIsTentative)
    }

    func testHourRatesArePerShiftSoCheapHoursAreNotValuedAtTheAverage() {
        // Weekday day shifts at ¥1,000/h and weekend late-night shifts (+25%) at the same job.
        let day = ["2026-09-21", "2026-09-22", "2026-09-23"].map { shift($0, "店", hours: 4, wage: 1_000) }
        let night = ["2026-09-26", "2026-09-27"].map {
            Shift(date: $0, employer: "店", segments: [WorkSegment(startMinute: 22 * 60, endMinute: 27 * 60, hourlyWage: 1_000)])
        }
        let r = income(day + night, profiles: [], today: "2026-09-30")
        XCTAssertEqual(r.lowestTaxablePerHour!, 1_000, accuracy: 0.001)
        XCTAssertEqual(r.highestTaxablePerHour!, 1_250, accuracy: 0.001)
    }

    func testNothingIsAdjustableOnceTheLastCountingPeriodHasEnded() {
        let r = income(everyDay("2026-10-01", through: "2026-12-10"), profiles: [monthEndNextMonth25], today: "2026-12-10")
        XCTAssertEqual(r.adjustable, 0, accuracy: 0.001)
        XCTAssertNil(r.cutBackDeadline)
        XCTAssertEqual(r.lastCountingWorkDate, "2026-11-30")
    }

    func testCrossingPaydayFindsTheFirstPaydayOverTheLine() {
        var r = IncomeWalls.AnnualIncome()
        r.paydays = [
            .init(date: "2026-10-25", amount: 1_700_000, includesProjection: false),
            .init(date: "2026-11-25", amount: 80_000, includesProjection: true),   // 1,780,000 exactly: not over
            .init(date: "2026-12-25", amount: 1, includesProjection: true),        // 1,780,001: over
        ]
        let tax = IncomeWalls.Wall(kind: .ownIncomeTax, basis: .taxYear, limit: 1_780_000, stayUnderInclusive: true)
        XCTAssertEqual(IncomeWalls.crossingPayday(of: tax, in: r), "2026-12-25")
    }

    func testPayPeriodsIncludeAJanuaryPaydayForTheYear() {
        let periods = IncomeWalls.payPeriods(paidIn: 2026, profile: monthEndNextMonth25)
        XCTAssertEqual(periods.count, 12)
        XCTAssertEqual(periods.first, .init(start: "2025-12-01", end: "2025-12-31", payDate: "2026-01-25"))
        XCTAssertEqual(periods.last, .init(start: "2026-11-01", end: "2026-11-30", payDate: "2026-12-25"))
    }
}
