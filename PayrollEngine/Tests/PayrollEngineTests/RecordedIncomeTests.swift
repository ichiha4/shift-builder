import XCTest
@testable import PayrollEngine

final class RecordedIncomeTests: XCTestCase {
    private func summary(_ payments: [ActualPayment], year: Int = 2026, through: String = "2026-10-16") -> RecordedIncomeSummary {
        Aggregation.recordedIncome(year: year, through: through, payments: payments)
    }

    func testLegacyTakeHomeIsPreservedAndNeverCountedAsGross() throws {
        let oldJSON = #"{"id":"old","employer":"Cafe","payDate":"2026-09-25","amount":48000}"#
        let payment = try JSONDecoder().decode(ActualPayment.self, from: Data(oldJSON.utf8))
        XCTAssertEqual(payment.amount, 48000)
        XCTAssertNil(payment.taxableGross)
        XCTAssertEqual(summary([payment]).taxableGross, 0)
        XCTAssertEqual(summary([payment]).missingGrossCount, 1)
    }

    func testAddsGrossAcrossEmployersWithoutAddingTakeHomeAgain() {
        let result = summary([
            ActualPayment(employer: "Cafe", payDate: "2026-09-25", amount: 48000, taxableGross: 50000),
            ActualPayment(employer: "Shop", payDate: "2026-10-10", taxableGross: 65000)
        ])
        XCTAssertEqual(result.taxableGross, 115000)
        XCTAssertEqual(result.paymentCount, 2)
        XCTAssertEqual(result.missingGrossCount, 0)
    }

    func testUsesPaymentYearAndExcludesUnpaidFutureDates() {
        let payments = [
            ActualPayment(employer: "Cafe", payDate: "2025-12-25", taxableGross: 10000),
            ActualPayment(employer: "Cafe", payDate: "2026-01-25", taxableGross: 20000),
            ActualPayment(employer: "Cafe", payDate: "2026-10-16", taxableGross: 30000),
            ActualPayment(employer: "Cafe", payDate: "2026-10-25", taxableGross: 40000),
            ActualPayment(employer: "Cafe", payDate: "2027-01-25", taxableGross: 50000)
        ]
        XCTAssertEqual(summary(payments).taxableGross, 50000)
        XCTAssertEqual(summary(payments, year: 2027, through: "2027-01-25").taxableGross, 50000)
    }

    func testCorrectionReplacesSameEmployerPayday() {
        let result = summary([
            ActualPayment(employer: "Cafe", payDate: "2026-09-25", taxableGross: 50000),
            ActualPayment(employer: "Cafe", payDate: "2026-09-25", taxableGross: 55000)
        ])
        XCTAssertEqual(result.taxableGross, 55000)
        XCTAssertEqual(result.paymentCount, 1)
    }

    func testZeroGrossIsRecordedButInvalidAmountsAreNot() {
        let result = summary([
            ActualPayment(employer: "Zero", payDate: "2026-09-25", taxableGross: 0),
            ActualPayment(employer: "Negative", payDate: "2026-09-25", taxableGross: -1),
            ActualPayment(employer: "Invalid", payDate: "2026-09-25", taxableGross: .nan)
        ])
        XCTAssertEqual(result.taxableGross, 0)
        XCTAssertEqual(result.paymentCount, 1)
        XCTAssertEqual(result.missingGrossCount, 2)
    }

    func testGrossOnlyRecordSurvivesAccountSnapshotRoundTrip() throws {
        var snapshot = AccountSnapshot()
        snapshot.actualPayments = [ActualPayment(id: "p", employer: "Cafe", payDate: "2026-09-25", taxableGross: 50000)]
        let restored = try JSONDecoder().decode(AccountSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(restored, snapshot)
        XCTAssertNil(restored.actualPayments.first?.amount)
        XCTAssertEqual(summary(restored.actualPayments).taxableGross, 50000)
    }

    func testGrossOnlyRecordDoesNotBecomeAnActualBankDeposit() throws {
        let payment = ActualPayment(employer: "Cafe", payDate: "2026-10-25", taxableGross: 50000)
        let projection = try XCTUnwrap(CashFlowForecast.project(asOfDate: "2026-10-16", openingBalance: 1000,
            days: 30, shifts: [], profiles: [], actualPayments: [payment], expenses: [], recurringExpenses: []))
        XCTAssertTrue(projection.events.isEmpty)
        XCTAssertEqual(projection.closingBalance, 1000)
        XCTAssertTrue(Aggregation.paydayIncomeEntries(month: "2026-10", shifts: [], profiles: [],
            actualPayments: [payment], classifications: [:]).isEmpty)
    }
}
