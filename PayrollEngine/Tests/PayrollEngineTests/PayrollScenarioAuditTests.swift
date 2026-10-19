import XCTest
@testable import PayrollEngine

/// Hand-calculated user scenarios, including the period selection used by the home card.
final class PayrollScenarioAuditTests: XCTestCase {
    private func segment(_ start: Int, _ end: Int, _ wage: Double) -> WorkSegment {
        WorkSegment(startMinute: start, endMinute: end, hourlyWage: wage)
    }

    func testDifferentWagesAtTheSameWorkplaceAreAddedByTheirOwnDuration() {
        let shift = Shift(date: "2026-10-19", employer: "Cafe", segments: [
            segment(540, 780, 1100), segment(840, 1080, 1300)
        ])
        let pay = PayCalculation.estimateShiftPay(shift)
        XCTAssertEqual(pay.netMinutes, 480)
        XCTAssertEqual(pay.overtimeMinutes, 0)
        XCTAssertEqual(pay.netPay, 9600, accuracy: 0.001) // 4 × 1100 + 4 × 1300
    }

    func testOvernightPayExcludesThePreciseBreakFromBaseAndNightPremium() {
        let shift = Shift(date: "2026-10-19", employer: "Night", segments: [segment(1320, 360, 1200)],
                          breakMinutes: 60, breakStartMinute: 60)
        let pay = PayCalculation.estimateShiftPay(shift)
        XCTAssertEqual(pay.netMinutes, 420)
        XCTAssertEqual(pay.lateNightMinutes, 360)
        XCTAssertEqual(pay.netPay, 10200, accuracy: 0.001) // 7 × 1200 + 6 × 300
    }

    func testBreakCrossingMidnightUsesTheWageOfTheAffectedSegment() {
        let shift = Shift(date: "2026-10-19", employer: "Night", segments: [
            segment(1260, 1380, 1000), segment(1380, 120, 1200)
        ], breakMinutes: 30, breakStartMinute: 1410)
        let pay = PayCalculation.estimateShiftPay(shift)
        XCTAssertEqual(pay.netMinutes, 270)
        XCTAssertEqual(pay.lateNightMinutes, 210)
        XCTAssertEqual(pay.netPay, 6000, accuracy: 0.001) // 2 × 1000 + 2.5 × 1200 + 250 + 750
    }

    func testSeparateShiftsAtTheSameWorkplaceKeepTheirWagesAndShareOvertime() {
        let morning = Shift(date: "2026-10-19", employer: "Cafe", segments: [segment(540, 780, 1100)])
        let evening = Shift(date: "2026-10-19", employer: "Cafe", segments: [segment(840, 1200, 1300)])
        let shifts = [morning, evening]
        let classifications = PayCalculation.buildEmployerClassifications(shifts)
        let preview = PayCalculation.estimateShiftPay(evening, allShifts: shifts)
        let saved = PayCalculation.pay(for: evening, classifications: classifications)
        XCTAssertEqual(saved.overtimeMinutes, 120)
        XCTAssertEqual(saved.netPay, 8450, accuracy: 0.001) // 6 × 1300 + 2 × 325
        XCTAssertEqual(preview.netPay, saved.netPay, accuracy: 0.001)
        XCTAssertEqual(Aggregation.calculateMonthlyPay(shifts, classifications: classifications).grossTotal,
                       12850, accuracy: 0.001)
    }

    func testMonthlySelectionRetainsOvertimeEarnedInAWeekStartingLastMonth() {
        let dates = ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"]
        var shifts = dates.map { Shift(date: $0, employer: "Cafe", segments: [segment(540, 1020, 1200)]) }
        shifts.append(Shift(date: "2026-10-03", employer: "Cafe", segments: [segment(540, 780, 1200)]))
        let profile = EmployerProfile(name: "Cafe", closingDay: 0, paydayMonthOffset: 1,
                                      paydayDay: 25, paydayAdjustment: .none)
        let paid = PayPeriod.shifts(paidInMonth: "2026-11", shifts: shifts, profiles: [profile])
        let slip = Aggregation.calculateMonthlyPay(paid,
                    classifications: PayCalculation.buildEmployerClassifications(shifts))
        XCTAssertEqual(paid.count, 3)
        XCTAssertEqual(slip.overtimeMinutes, 240)
        XCTAssertEqual(slip.grossTotal, 25200, accuracy: 0.001) // 20 × 1200 + 4 × 300
    }

    func testTwoWorkplacesUseTheirOwnClosingDatesWithoutLosingAllowances() {
        let profiles = [
            EmployerProfile(name: "A", closingDay: 10, paydayMonthOffset: 1, paydayDay: 25, paydayAdjustment: .none),
            EmployerProfile(name: "B", closingDay: 0, paydayMonthOffset: 1, paydayDay: 25, paydayAdjustment: .none)
        ]
        let aBefore = Shift(date: "2026-10-10", employer: "A", segments: [segment(540, 660, 1200)])
        let aAfter = Shift(date: "2026-10-11", employer: "A", segments: [segment(540, 660, 1200)])
        let bBefore = Shift(date: "2026-10-31", employer: "B", segments: [segment(540, 600, 1200)],
                            transport: 500, otherAllowance: 300)
        let bAfter = Shift(date: "2026-11-01", employer: "B", segments: [segment(540, 600, 1200)])
        let all = [aBefore, aAfter, bBefore, bAfter]
        let paid = PayPeriod.shifts(paidInMonth: "2026-11", shifts: all, profiles: profiles)
        XCTAssertEqual(Set(paid.map(\.id)), Set([aBefore.id, bBefore.id]))
        let slip = Aggregation.calculateMonthlyPay(paid, classifications: PayCalculation.buildEmployerClassifications(all))
        XCTAssertEqual(slip.transport, 500, accuracy: 0.001)
        XCTAssertEqual(slip.otherAllowance, 300, accuracy: 0.001)
        XCTAssertEqual(slip.grossTotal, 4400, accuracy: 0.001)
    }
}
