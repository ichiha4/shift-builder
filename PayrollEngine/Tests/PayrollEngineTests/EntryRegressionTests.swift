import XCTest
@testable import PayrollEngine

final class ShiftTemplateTests: XCTestCase {
    private func pattern(start: Int = 540, end: Int = 1020) -> Shift {
        Shift(id: "source", date: "2026-10-17", employer: "Cafe",
              segments: [WorkSegment(startMinute: start, endMinute: end, hourlyWage: 1250.5)],
              breakMinutes: 30, breakStartMinute: 720, transport: 250.5, otherAllowance: 100.25,
              isStatutoryHoliday: true)
    }

    func testSameEmployerCanHaveDifferentHoursWithoutCreatingShifts() {
        var snapshot = AccountSnapshot()
        snapshot.shiftTemplates = [ShiftTemplate(pattern: pattern()), ShiftTemplate(pattern: pattern(start: 1020, end: 1320))]
        XCTAssertEqual(snapshot.shiftTemplates.count, 2)
        XCTAssertNotEqual(snapshot.shiftTemplates[0].fingerprint, snapshot.shiftTemplates[1].fingerprint)
        XCTAssertTrue(snapshot.shifts.isEmpty)
        XCTAssertEqual(Aggregation.calculateMonthlyPay(snapshot.shifts, classifications: [:]).grossTotal, 0)
    }

    func testFingerprintIgnoresSourceDayIDAndHolidayButKeepsConditions() {
        let original = pattern()
        var anotherDay = original; anotherDay.id = "different"; anotherDay.date = "2026-11-03"; anotherDay.isStatutoryHoliday = false
        XCTAssertEqual(ShiftTemplate.fingerprint(original), ShiftTemplate.fingerprint(anotherDay))
        anotherDay.transport += 0.5
        XCTAssertNotEqual(ShiftTemplate.fingerprint(original), ShiftTemplate.fingerprint(anotherDay))
    }

    func testAddingTemplateToDatesCreatesIndependentShiftsAndPreservesPrecision() {
        let template = ShiftTemplate(pattern: pattern())
        let first = template.shift(on: "2026-10-20"), second = template.shift(on: "2026-10-21")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.date, "2026-10-20")
        XCTAssertEqual(second.date, "2026-10-21")
        XCTAssertFalse(first.isStatutoryHoliday)
        XCTAssertEqual(first.segments, pattern().segments)
        XCTAssertEqual(first.breakStartMinute, 720)
        XCTAssertEqual(first.breakMinutes, 30)
        XCTAssertEqual(first.transport, 250.5)
        XCTAssertEqual(first.otherAllowance, 100.25)
        XCTAssertTrue(template.pattern.date.isEmpty)
    }

    func testOldAccountsWithoutTemplatesDecodeButMalformedTemplatesDoNot() throws {
        let legacy = Data(#"{"shifts":[],"expenses":[],"employerProfiles":[],"deductions":[]}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(AccountSnapshot.self, from: legacy).shiftTemplates.isEmpty)
        let malformed = Data(#"{"shifts":[],"expenses":[],"employerProfiles":[],"deductions":[],"shiftTemplates":"broken"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AccountSnapshot.self, from: malformed))
    }

    func testTemplateSyncRetainsUnrelatedRemoteShiftAndPay() throws {
        let before = AccountSnapshot()
        var local = before; local.shiftTemplates = [ShiftTemplate(pattern: pattern())]
        var remote = before; remote.shifts = [pattern()]
        let batch = try SyncBatch(from: before, to: local)
        XCTAssertEqual(Set(batch.changes.map(\.collection)), [.shiftTemplates])
        XCTAssertTrue(try batch.conflicts(with: remote).isEmpty)
        let merged = try batch.applying(to: remote)
        XCTAssertEqual(merged.shifts, remote.shifts)
        XCTAssertEqual(merged.shiftTemplates, local.shiftTemplates)
        XCTAssertEqual(Aggregation.calculateMonthlyPay(merged.shifts, classifications: PayCalculation.buildEmployerClassifications(merged.shifts)).grossTotal,
                       Aggregation.calculateMonthlyPay(remote.shifts, classifications: PayCalculation.buildEmployerClassifications(remote.shifts)).grossTotal)
    }

    func testTemplateQueueSurvivesRestartAndDeletionNeverDeletesActualShift() throws {
        var journal = SyncJournal()
        var snapshot = AccountSnapshot(); snapshot.shifts = [pattern()]
        snapshot.shiftTemplates = [ShiftTemplate(pattern: pattern())]
        try journal.recordEdit(to: snapshot)
        let reopened = try JSONDecoder().decode(SyncJournal.self, from: JSONEncoder().encode(journal))
        XCTAssertEqual(try reopened.workingSnapshot(), snapshot)
        var removed = snapshot; removed.shiftTemplates = []
        let deletion = try SyncBatch(from: snapshot, to: removed)
        XCTAssertEqual(try deletion.applying(to: snapshot).shifts, snapshot.shifts)
        XCTAssertTrue(try deletion.applying(to: snapshot).shiftTemplates.isEmpty)
        XCTAssertTrue(try deletion.conflicts(with: removed).isEmpty)
    }
}

final class EmployerChoiceTests: XCTestCase {
    private func shift(_ id: String, employer: String, date: String = "2026-10-20", wage: Double = 1200) -> Shift {
        Shift(id: id, date: date, employer: employer,
              segments: [WorkSegment(startMinute: 540, endMinute: 1020, hourlyWage: wage)])
    }

    func testMultipleTemplatesIncludeHistoryOnlyEmployersWithoutDuplicateWorkplaces() throws {
        let profile = EmployerProfile(name: "Cafe", defaultWage: 1300)
        let choices = ShiftEmployerChoice.available(profiles: [profile], shifts: [
            shift("cafe-1", employer: "Cafe"), shift("cafe-2", employer: "Cafe"),
            shift("shop-1", employer: "Shop"), shift("shop-2", employer: "Shop"),
            shift("hotel-1", employer: "Hotel")
        ])
        XCTAssertEqual(choices.map(\.name), ["Cafe", "Hotel", "Shop"])
        XCTAssertEqual(choices.first?.profile, profile)
        XCTAssertNil(try XCTUnwrap(choices.first { $0.name == "Shop" }).profile)
    }

    func testHistoryOnlyAndProfileOnlyWorkplacesRemainSelectable() {
        XCTAssertEqual(ShiftEmployerChoice.available(profiles: [], shifts: [
            shift("one", employer: "Cafe"), shift("two", employer: "Shop")
        ]).map(\.name), ["Cafe", "Shop"])
        XCTAssertEqual(ShiftEmployerChoice.available(profiles: [EmployerProfile(name: "New Cafe")], shifts: []).map(\.name), ["New Cafe"])
    }

    func testWhitespaceDoesNotHideOrDuplicateWorkplaces() {
        let choices = ShiftEmployerChoice.available(profiles: [EmployerProfile(name: "Cafe")], shifts: [
            shift("one", employer: " Cafe\n"), shift("two", employer: "\n ")
        ])
        XCTAssertEqual(choices.map(\.name), ["Cafe"])
        XCTAssertNotNil(choices.first?.latestShift)
    }

    func testSavedWageWinsAndUnsetWageDoesNotBorrowAnOldRate() {
        let history = [shift("one", employer: "Cafe", wage: 1100)]
        let configured = ShiftEmployerChoice.available(profiles: [EmployerProfile(name: "Cafe", defaultWage: 1300.5)], shifts: history)
        XCTAssertEqual(configured.first?.suggestedHourlyWage, 1300.5)
        let unset = ShiftEmployerChoice.available(profiles: [EmployerProfile(name: "Cafe", defaultWage: 0)], shifts: history)
        XCTAssertNil(unset.first?.suggestedHourlyWage)
    }

    func testHistoryUsesLatestWorkplaceConditionsRatherThanTemplateOrder() {
        let choices = ShiftEmployerChoice.available(profiles: [], shifts: [
            shift("old", employer: "Shop", date: "2026-10-01", wage: 1100),
            shift("recent", employer: "Shop", date: "2026-10-20", wage: 1450.75)
        ])
        XCTAssertEqual(choices.first?.latestShift?.id, "recent")
        XCTAssertEqual(choices.first?.suggestedHourlyWage, 1450.75)
    }

    func testMixedWageBandsRequireEntryInsteadOfGuessingOneRate() {
        var source = shift("split", employer: "Cafe")
        source.segments.append(WorkSegment(startMinute: 1020, endMinute: 1320, hourlyWage: 1500))
        XCTAssertNil(ShiftEmployerChoice.available(profiles: [], shifts: [source]).first?.suggestedHourlyWage)
    }
}

final class EntryRegressionTests: XCTestCase {
    private func shift(_ id: String = "new", date: String = "2026-10-20", employer: String = "Cafe",
                       start: Int = 540, end: Int = 780, wage: Double = 1200) -> Shift {
        Shift(id: id, date: date, employer: employer,
              segments: [WorkSegment(startMinute: start, endMinute: end, hourlyWage: wage)])
    }

    func testTemplateCannotDuplicateSameHoursAfterWageOrAllowanceChanges() {
        let existing = shift("existing", wage: 1000)
        var source = shift("source", date: "2026-10-19", wage: 1200)
        source.transport = 300
        source.otherAllowance = 50
        let repeated = source.repeated(on: existing.date)
        XCTAssertFalse(Validation.validateShift(repeated, existing: [existing]).isEmpty)
    }

    func testOverlapIsRejectedAcrossEmployersAndPartialTimeRanges() {
        let existing = shift("existing", employer: "Shop", start: 600, end: 840)
        XCTAssertFalse(Validation.validateShift(shift(), existing: [existing]).isEmpty)
    }

    func testPreviousNightAndFollowingDayBothBlockOverlappingEntry() {
        let night = shift("night", date: "2026-10-20", start: 1320, end: 180)
        let morning = shift("morning", date: "2026-10-21", start: 120, end: 360)
        XCTAssertFalse(Validation.validateShift(morning, existing: [night]).isEmpty)
        XCTAssertFalse(Validation.validateShift(night, existing: [morning]).isEmpty)
    }

    func testAdjacentShiftsAndDifferentDatesRemainAllowed() {
        let existing = shift("existing")
        XCTAssertTrue(Validation.validateShift(shift(start: 780, end: 960), existing: [existing]).isEmpty)
        XCTAssertTrue(Validation.validateShift(shift(date: "2026-10-21"), existing: [existing]).isEmpty)
    }

    func testEditIgnoresOwnIDButRejectsAnotherOverlappingRecord() {
        let current = shift("current")
        var edited = current
        edited.segments[0].hourlyWage = 1250.5
        XCTAssertTrue(Validation.validateShift(edited, existing: [current]).isEmpty)
        XCTAssertFalse(Validation.validateShift(edited, existing: [current, shift("other")]).isEmpty)
    }

    func testGapsBetweenSegmentsRemainAvailable() {
        var split = shift("split")
        split.segments = [WorkSegment(startMinute: 540, endMinute: 600, hourlyWage: 1200),
                          WorkSegment(startMinute: 720, endMinute: 780, hourlyWage: 1200)]
        XCTAssertTrue(Validation.validateShift(shift(start: 600, end: 720), existing: [split]).isEmpty)
    }

    func testImportRejectsOvernightAndOtherEmployerConflicts() {
        let profile = EmployerProfile(name: "Cafe", defaultWage: 1200)
        let candidate = ShiftImportCandidate(id: 0, date: "2026-10-21", startMinute: 120, endMinute: 360)
        let night = shift("night", date: "2026-10-20", employer: "Shop", start: 1320, end: 180)
        XCTAssertThrowsError(try ShiftImportPlanner.plan(candidates: [candidate], profile: profile, existing: [night])) {
            XCTAssertEqual($0 as? ShiftImportError, .overlappingShift("2026-10-21"))
        }
    }

    func testOptionalMonetaryFieldsAcceptEmptyAndZeroButRejectMalformedValues() {
        for input in ["", " ", "\n", "0", "0.0"] {
            XCTAssertEqual(FormNumber.nonnegative(input, allowEmpty: true), 0)
        }
        for input in ["-1", "abc", "NaN", "inf", "1.2.3"] {
            XCTAssertNil(FormNumber.nonnegative(input, allowEmpty: true), input)
        }
        XCTAssertNil(FormNumber.nonnegative(""))
        XCTAssertEqual(FormNumber.nonnegative("1200.5", allowEmpty: true), 1200.5)
    }

    func testReopeningZeroAllowanceValuesKeepsThemSaveable() {
        let profile = EmployerProfile(name: "Cafe", defaultWage: 1200)
        for amount in [profile.defaultTransport, profile.otherAllowance] {
            XCTAssertEqual(FormNumber.nonnegative(FormNumber.text(amount), allowEmpty: true), 0)
        }
    }

    func testEditableAmountsPreserveFractionsThroughRepeatedSaves() throws {
        for original in [0, 0.5, 0.01, 1200.5, 1234.56789, 1_000_000.75] {
            var value = original
            for _ in 0..<5 {
                value = try XCTUnwrap(FormNumber.nonnegative(FormNumber.text(value)))
            }
            XCTAssertEqual(value, original)
        }
        XCTAssertEqual(FormNumber.text(1200), "1200")
    }

    func testPercentagesPreserveNonIntegerRatesThroughRepeatedSaves() throws {
        for original in [0, 0.145, 0.255, 0.375, 0.250125, 1.005] {
            var value = original
            for _ in 0..<5 {
                value = try XCTUnwrap(FormNumber.nonnegative(FormNumber.percentageText(value))) / 100
            }
            XCTAssertEqual(value, original, accuracy: 0.000000000001)
        }
        XCTAssertEqual(FormNumber.percentageText(0.255), "25.5")
        XCTAssertEqual(FormNumber.percentageText(0.145), "14.5")
        XCTAssertEqual(FormNumber.percentageText(0.25), "25")
    }

    func testInvalidStoredNumbersDoNotCrashEditableFormatting() {
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(FormNumber.text(invalid), "")
            XCTAssertEqual(FormNumber.percentageText(invalid), "")
        }
    }
}

final class ShiftEntryReviewTests: XCTestCase {
    private func shift(_ id: String, date: String = "2026-10-20", employer: String = "Cafe",
                       start: Int = 540, end: Int = 780, wage: Double = 1200) -> Shift {
        Shift(id: id, date: date, employer: employer,
              segments: [WorkSegment(startMinute: start, endMinute: end, hourlyWage: wage)])
    }

    func testValidOverlapIsAConfirmationWhileStrictImportsStillRejectIt() {
        let existing = shift("saved", employer: "Shop")
        let candidate = shift("new", start: 600, end: 840)
        let review = Validation.reviewShift(candidate, existing: [existing])
        XCTAssertTrue(review.errors.isEmpty)
        XCTAssertEqual(review.overlappingShifts, [existing])
        XCTAssertTrue(review.requiresOverlapConfirmation)
        XCTAssertFalse(Validation.validateShift(candidate, existing: [existing]).isEmpty)
    }

    func testInvalidInputCannotBeBypassedByConfirmingAnOverlap() {
        let existing = shift("saved")
        let review = Validation.reviewShift(shift("bad", wage: 0), existing: [existing])
        XCTAssertEqual(review.overlappingShifts, [existing])
        XCTAssertFalse(review.errors.isEmpty)
        XCTAssertFalse(review.requiresOverlapConfirmation)
    }

    func testEditingExcludesOnlyItselfAndReportsAllOtherConflictingRecords() {
        let first = shift("first"), second = shift("second", employer: "Shop", start: 600, end: 720)
        let adjacent = shift("later", start: 780, end: 960)
        let review = Validation.reviewShift(first, existing: [first, second, adjacent])
        XCTAssertEqual(review.overlappingShifts, [second])
        XCTAssertTrue(review.requiresOverlapConfirmation)
    }

    func testAdjacentTimesGapsAndDifferentDatesDoNotNeedConfirmation() {
        var split = shift("split")
        split.segments = [WorkSegment(startMinute: 540, endMinute: 600, hourlyWage: 1200),
                          WorkSegment(startMinute: 720, endMinute: 780, hourlyWage: 1300)]
        for candidate in [shift("gap", start: 600, end: 720), shift("after", start: 780, end: 960),
                          shift("next-day", date: "2026-10-21")] {
            let review = Validation.reviewShift(candidate, existing: [split])
            XCTAssertTrue(review.errors.isEmpty)
            XCTAssertTrue(review.overlappingShifts.isEmpty)
            XCTAssertFalse(review.requiresOverlapConfirmation)
        }
    }

    func testOvernightReviewIdentifiesTheConflictingNeighbouringDay() {
        let night = shift("night", start: 1320, end: 180)
        let morning = shift("morning", date: "2026-10-21", start: 120, end: 360)
        let later = shift("later", date: "2026-10-21", start: 360, end: 480)
        XCTAssertEqual(Validation.reviewShift(morning, existing: [night, later]).overlappingShifts, [night])
        XCTAssertFalse(Validation.reviewShift(later, existing: [night]).requiresOverlapConfirmation)
    }
}
