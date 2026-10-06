import XCTest
@testable import PayrollEngine

final class PlanningTests: XCTestCase {
    private func shift(_ date: String, id: String = UUID().uuidString) -> Shift {
        Shift(id: id, date: date, employer: "Cafe",
              segments: [WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: 1000)])
    }

    private func forecast(date: String = "2026-10-01", balance: Double = 10000, days: Int = 30,
        shifts: [Shift] = [], profiles: [EmployerProfile] = [], payments: [ActualPayment] = [],
        expenses: [Expense] = [], recurring: [RecurringExpense] = [], expected: [ExpectedPayment] = []
    ) -> CashFlowProjection? {
        CashFlowForecast.project(asOfDate: date, openingBalance: balance, days: days,
            shifts: shifts, profiles: profiles, actualPayments: payments, expenses: expenses,
            recurringExpenses: recurring, expectedPayments: expected)
    }

    func testSalaryLandsOnPaydayRatherThanWorkDate() throws {
        let profile = EmployerProfile(name: "Cafe", paydayDay: 25, paydayAdjustment: .none)
        let result = try XCTUnwrap(forecast(shifts: [shift("2026-09-10"), shift("2026-10-10")], profiles: [profile]))
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].date, "2026-10-25")
        XCTAssertEqual(result.events[0].amount, 8000, accuracy: 0.001)
        XCTAssertEqual(result.days.first { $0.date == "2026-10-24" }?.balance, 10000)
        XCTAssertEqual(result.closingBalance, 18000, accuracy: 0.001)
    }

    func testActualReplacesGrossAndUserEstimateEvenAfterProfileDeletion() throws {
        let profile = EmployerProfile(name: "Cafe", paydayDay: 25, paydayAdjustment: .none)
        let actual = ActualPayment(employer: "Cafe", payDate: "2026-10-25", amount: 6500)
        let expected = ExpectedPayment(employer: "Cafe", payDate: "2026-10-25", amount: 7000)
        let result = try XCTUnwrap(forecast(shifts: [shift("2026-09-10")], profiles: [profile],
            payments: [actual], expected: [expected]))
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events[0].kind, .actualIncome)
        XCTAssertEqual(result.closingBalance, 16500)
        XCTAssertEqual(forecast(payments: [actual])?.closingBalance, 16500)
    }

    func testExpectedTakeHomeReplacesGrossIncludingZero() throws {
        let profile = EmployerProfile(name: "Cafe", paydayDay: 25, paydayAdjustment: .none)
        let result = try XCTUnwrap(forecast(shifts: [shift("2026-09-10")], profiles: [profile], expected: [
            ExpectedPayment(employer: "Cafe", payDate: "2026-10-25", amount: 0)]))
        XCTAssertEqual(result.events[0].kind, .expectedTakeHome)
        XCTAssertEqual(result.closingBalance, 10000)
    }

    func testOpeningBalanceAlreadyIncludesTodayAndPastTransactions() throws {
        let result = try XCTUnwrap(forecast(days: 7, payments: [
            ActualPayment(employer: "Cafe", payDate: "2026-10-01", amount: 5000)], expenses: [
            Expense(date: "2026-09-30", category: "x", amount: 4000),
            Expense(date: "2026-10-01", category: "x", amount: 3000),
            Expense(date: "2026-10-08", category: "x", amount: 2000),
            Expense(date: "2026-10-09", category: "x", amount: 9000)]))
        XCTAssertEqual(result.days.count, 7)
        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.closingBalance, 8000)
    }

    func testRecurringClampsEndOfMonthAndDoesNotDuplicateEditedRecord() throws {
        let rent = RecurringExpense(id: "rent", name: "Rent", category: "x", amount: 9000, dayOfMonth: 31)
        let result = try XCTUnwrap(forecast(date: "2027-02-01", days: 89, expenses: [
            Expense(date: "2027-02-15", category: "x", amount: 8500, recurringExpenseId: "rent")], recurring: [rent]))
        XCTAssertEqual(result.events.count, 3)
        XCTAssertEqual(result.events.map(\.date), ["2027-02-15", "2027-03-31", "2027-04-30"])
        XCTAssertEqual(result.events.map(\.amount), [-8500, -9000, -9000])
    }

    func testInactiveRuleAndAlreadyRecordedEarlierThisMonth() throws {
        let result = try XCTUnwrap(forecast(date: "2026-10-15", days: 30, expenses: [
            Expense(date: "2026-10-01", category: "x", amount: 9000, recurringExpenseId: "rent")], recurring: [
            RecurringExpense(id: "rent", name: "Rent", category: "x", amount: 9000, dayOfMonth: 31),
            RecurringExpense(name: "Paused", category: "x", amount: 3000, dayOfMonth: 20, isActive: false)]))
        XCTAssertTrue(result.events.isEmpty)
    }

    func testNegativeDateAndDailyIncomeExpenseNetting() throws {
        let result = try XCTUnwrap(forecast(balance: 1000, days: 7, payments: [
            ActualPayment(employer: "Cafe", payDate: "2026-10-03", amount: 4000)], expenses: [
            Expense(date: "2026-10-02", category: "x", amount: 2000),
            Expense(date: "2026-10-03", category: "x", amount: 500)]))
        XCTAssertEqual(result.firstNegativeDate, "2026-10-02")
        XCTAssertEqual(result.minimumBalance, -1000)
        XCTAssertEqual(result.closingBalance, 2500)
    }

    func testHolidayRollingRetainsBothPeriodsAndDuplicateProfilesDoNotDoublePay() throws {
        let profile = EmployerProfile(name: "Cafe", paydayMonthOffset: 1, paydayDay: 1,
                                      paydayAdjustment: .beforeBusinessDay)
        let shifts = [shift("2026-06-10"), shift("2026-07-10")]
        let result = try XCTUnwrap(forecast(date: "2026-06-30", days: 31, shifts: shifts, profiles: [profile, profile]))
        XCTAssertEqual(result.events.map(\.date), ["2026-07-01", "2026-07-31"])
        XCTAssertEqual(result.events.count, 2)
        for event in result.events { XCTAssertEqual(event.amount, 8000, accuracy: 0.001) }
    }

    func testScenarioPreventsDoubleBookingAcrossMidnightAndEmployers() {
        let night = Shift(date: "2026-10-01", employer: "Other",
            segments: [WorkSegment(startMinute: 1320, endMinute: 360, hourlyWage: 1000)])
        let conflict = Shift(date: "2026-10-02", employer: "Cafe",
            segments: [WorkSegment(startMinute: 300, endMinute: 600, hourlyWage: 1000)])
        XCTAssertTrue(ShiftScenario.hasOverlap(conflict, with: [night]))
        XCTAssertNil(ShiftScenario.compare(month: "2026-10", shifts: [night], adding: [conflict]))
        let touching = Shift(date: "2026-10-02", employer: "Cafe",
            segments: [WorkSegment(startMinute: 360, endMinute: 600, hourlyWage: 1000)])
        XCTAssertFalse(ShiftScenario.hasOverlap(touching, with: [night]))
    }

    func testRejectsInvalidInputsAndIgnoresOrphanReplacements() {
        XCTAssertNil(forecast(date: "2026-02-30"))
        XCTAssertNil(forecast(date: "2026-1-01"))
        XCTAssertNil(forecast(balance: .nan))
        XCTAssertNil(forecast(days: 0))
        XCTAssertNil(forecast(days: 91))
        XCTAssertEqual(forecast(expected: [ExpectedPayment(employer: "Cafe", payDate: "2026-10-25", amount: 999)])?.events.count, 0)
    }

    func testAddingSixthDayRecalculatesWeeklyOvertime() throws {
        let baseline = (5...9).map { shift(String(format: "2026-10-%02d", $0)) }
        let result = try XCTUnwrap(ShiftScenario.compare(month: "2026-10", shifts: baseline, adding: [shift("2026-10-10")]))
        XCTAssertEqual(result.baselineGross, 40000, accuracy: 0.001)
        XCTAssertEqual(result.scenarioGross, 50000, accuracy: 0.001)
        XCTAssertEqual(result.difference, 10000, accuracy: 0.001)
        XCTAssertEqual(result.scenarioMinutes, 2880)
        XCTAssertEqual(baseline.count, 5, "Saved data stays unchanged")
    }

    func testRemovingPriorMonthShiftChangesOvertimeInSelectedMonth() throws {
        let baseline = ["2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02", "2026-10-03"]
            .enumerated().map { shift($0.element, id: String($0.offset)) }
        let result = try XCTUnwrap(ShiftScenario.compare(month: "2026-10", shifts: baseline, removingIDs: ["0"]))
        XCTAssertEqual(result.baselineGross, 26000, accuracy: 0.001)
        XCTAssertEqual(result.scenarioGross, 24000, accuracy: 0.001)
        XCTAssertEqual(result.difference, -2000, accuracy: 0.001)
    }

    func testScenarioRejectsDuplicateIDsAndInvalidMonth() {
        let saved = shift("2026-10-05", id: "saved")
        XCTAssertNil(ShiftScenario.compare(month: "2026-10", shifts: [saved], adding: [saved]))
        XCTAssertNil(ShiftScenario.compare(month: "2026-13", shifts: [saved]))
    }
}
