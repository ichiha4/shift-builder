#if LOCAL_DEVICE_TESTING
import XCTest
import FirebaseCore
@testable import ShiftManagerApp

@MainActor
final class LocalDeviceTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ShiftBuilder.LocalDeviceTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func waitForSaved(_ store: ShiftStore) async throws {
        for _ in 0..<200 {
            if store.pendingSyncCount == 0 && !store.syncWriteFailed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local records were not committed")
    }

    func testLocalDeviceBuildStartsWithoutFirebaseOrAppleSignIn() {
        XCTAssertNil(FirebaseApp.app())
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.example.shiftbuilder.localdevice")
        XCTAssertNil(AuthManager(restoreSession: false).user)
        let store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertTrue(store.cloudDataReady)
        store.detachUser()
    }

    func testImportedShiftsSurviveClosingAndReopeningWithoutNetwork() async throws {
        let old = ShiftStore(defaults: defaults, remindersEnabled: false)
        old.attachUser(uid: LocalDeviceTestTransport.accountID)
        let profile = EmployerProfile(name: "テストカフェ", defaultWage: 1200)
        old.saveEmployerProfile(profile)
        try await waitForSaved(old)
        let candidates = try ShiftImportParser.parse(lines: ["2026/10/06 17:00-22:00 休憩30分"], month: "2026-10").candidates
        let plan = try old.importShiftCandidates(candidates, profile: profile)
        XCTAssertEqual(plan.shifts.count, 1)
        try await waitForSaved(old)
        let expected = old.shifts
        old.detachUser()
        let resumed = ShiftStore(defaults: defaults, remindersEnabled: false)
        resumed.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertTrue(resumed.cloudDataReady)
        XCTAssertEqual(resumed.shifts, expected)
        XCTAssertEqual(resumed.employerProfiles, [profile])
        let duplicate = try resumed.importShiftCandidates(candidates, profile: profile)
        XCTAssertTrue(duplicate.shifts.isEmpty)
        XCTAssertEqual(resumed.shifts.count, 1)
        resumed.detachUser()
    }

    func testPayslipCorrectionKeepsTakeHomeAndGrossSeparateAfterReopening() async throws {
        let first = ShiftStore(defaults: defaults, remindersEnabled: false)
        first.attachUser(uid: LocalDeviceTestTransport.accountID)
        first.recordActualPayment(employer: "Cafe", payDate: "2026-09-25", amount: 48000)
        try await waitForSaved(first)
        let id = try XCTUnwrap(first.actualPayments.first?.id)
        first.detachUser()

        let second = ShiftStore(defaults: defaults, remindersEnabled: false)
        second.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertEqual(second.actualPayments.first?.amount, 48000)
        XCTAssertNil(second.actualPayments.first?.taxableGross)
        second.recordActualPayment(employer: "Cafe", payDate: "2026-09-25", amount: 48000, taxableGross: 50000)
        second.recordActualPayment(employer: "Cafe", payDate: "2026-09-25", amount: 48000, taxableGross: 51000)
        try await waitForSaved(second)
        XCTAssertEqual(second.actualPayments.count, 1)
        XCTAssertEqual(second.actualPayments.first?.id, id)
        second.detachUser()

        let reopened = ShiftStore(defaults: defaults, remindersEnabled: false)
        reopened.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertEqual(reopened.actualPayments.first?.amount, 48000)
        XCTAssertEqual(reopened.actualPayments.first?.taxableGross, 51000)
        XCTAssertEqual(Aggregation.recordedIncome(year: 2026, through: "2026-10-16", payments: reopened.actualPayments).taxableGross, 51000)
        reopened.detachUser()
    }

    func testCommitCanBeRetriedAfterAcknowledgementWasLost() async throws {
        let transport = LocalDeviceTestTransport(defaults: defaults)
        var snapshot = AccountSnapshot()
        snapshot.shifts = [Shift(id: "one", date: "2026-10-06", employer: "Cafe",
                                 segments: [WorkSegment(startMinute: 600, endMinute: 900, hourlyWage: 1200)])]
        let batch = try SyncBatch(from: AccountSnapshot(), to: snapshot)
        _ = try await transport.commit(uid: LocalDeviceTestTransport.accountID, batch: batch, allowCreate: true)
        let reopened = LocalDeviceTestTransport(defaults: defaults)
        guard case .applied(let state) = try await reopened.commit(uid: LocalDeviceTestTransport.accountID,
                                                                   batch: batch, allowCreate: false) else {
            return XCTFail("Retry should return the previous commit")
        }
        XCTAssertEqual(state.revision, 1)
        XCTAssertEqual(state.snapshot.shifts.count, 1)
    }

    func testUnreadableLocalSnapshotBlocksEditsAndKeepsOriginalBytes() {
        let invalid = Data("unreadable".utf8)
        defaults.set(invalid, forKey: "shiftbuilder.localDeviceTest.snapshot.v1")
        let store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertFalse(store.cloudDataReady)
        XCTAssertTrue(store.cloudReadFailed)
        store.saveEmployerProfile(EmployerProfile(name: "Should not save", defaultWage: 1200))
        XCTAssertTrue(store.employerProfiles.isEmpty)
        XCTAssertEqual(defaults.data(forKey: "shiftbuilder.localDeviceTest.snapshot.v1"), invalid)
        store.detachUser()
    }
}
@MainActor
final class ShiftDeletionUndoTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var stores: [ShiftStore] = []
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "ShiftBuilder.DeletionUndoTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        for store in stores { store.detachUser() }
        stores.removeAll()
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func openStore() -> ShiftStore {
        let store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        stores.append(store)
        return store
    }

    private func shift(_ id: String, date: String = "2026-10-03") -> Shift {
        Shift(id: id, date: date, employer: "Undo Cafe", segments: [
            WorkSegment(startMinute: 540, endMinute: 660, hourlyWage: 1150.5),
            WorkSegment(startMinute: 660, endMinute: 780, hourlyWage: 1250.75)
        ], breakMinutes: 15, breakStartMinute: 600, transport: 280.5, otherAllowance: 130.25,
           isStatutoryHoliday: true, scheduledMinutes: 360, lateNightRate: 0.225,
           overtimeRate: 0.275, holidayRate: 0.375)
    }

    private func waitForSaved(_ store: ShiftStore) async throws {
        for _ in 0..<200 {
            if store.pendingSyncCount == 0 && !store.syncWriteFailed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Undo edits were not committed")
    }

    func testImmediateDeletionAndUndoPreserveFullRecordAndPayAfterReopening() async throws {
        let store = openStore()
        let first = shift("first"), second = shift("second", date: "2026-10-05")
        store.addShift(first); store.addShift(second)
        try await waitForSaved(store)
        let original = store.shifts
        let originalPay = Aggregation.calculateMonthlyPay(original, classifications: store.classifications).grossTotal

        XCTAssertTrue(store.deleteShiftWithUndo(id: first.id, now: start))
        XCTAssertEqual(store.shifts, [second])
        XCTAssertEqual(store.pendingShiftDeletionCount, 1)
        XCTAssertEqual(store.shiftDeletionUndoDeadline, start.addingTimeInterval(5))
        XCTAssertEqual(store.undoableDeletedShifts, [first])
        XCTAssertLessThan(Aggregation.calculateMonthlyPay(store.shifts, classifications: store.classifications).grossTotal, originalPay)
        XCTAssertEqual(try store.undoShiftDeletions(now: start.addingTimeInterval(1)), [first])
        XCTAssertEqual(store.shifts, original)
        XCTAssertEqual(store.pendingShiftDeletionCount, 0)
        XCTAssertNil(store.shiftDeletionUndoDeadline)
        XCTAssertEqual(Aggregation.calculateMonthlyPay(store.shifts, classifications: store.classifications).grossTotal, originalPay)
        try await waitForSaved(store)
        store.detachUser()
        XCTAssertEqual(openStore().shifts.sorted { $0.id < $1.id }, original.sorted { $0.id < $1.id })
    }

    func testConsecutiveDeletionsRestartWindowAndRestoreWholeBatchInOriginalOrder() throws {
        let store = openStore()
        let first = shift("first"), second = shift("second", date: "2026-10-05")
        store.addShift(first); store.addShift(second)
        XCTAssertTrue(store.deleteShiftWithUndo(id: first.id, now: start))
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: start.addingTimeInterval(4)))
        XCTAssertEqual(store.shiftDeletionUndoDeadline, start.addingTimeInterval(9))
        store.expireShiftDeletionUndo(now: start.addingTimeInterval(5.5))
        XCTAssertTrue(store.shifts.isEmpty)
        XCTAssertEqual(store.pendingShiftDeletionCount, 2)
        XCTAssertEqual(store.shiftDeletionUndoDeadline, start.addingTimeInterval(9))
        XCTAssertEqual(Set(try store.undoShiftDeletions(now: start.addingTimeInterval(6)).map(\.id)), [first.id, second.id])
        XCTAssertEqual(store.shifts, [first, second])
    }

    func testUndoExpiresAtFiveSeconds() throws {
        let store = openStore()
        store.addShift(shift("first"))
        XCTAssertTrue(store.deleteShiftWithUndo(id: "first", now: start))
        XCTAssertTrue(try store.undoShiftDeletions(now: start.addingTimeInterval(5)).isEmpty)
        XCTAssertTrue(store.shifts.isEmpty)
        XCTAssertEqual(store.pendingShiftDeletionCount, 0)
        XCTAssertNil(store.shiftDeletionUndoDeadline)
    }

    func testUndoBannerExpiresWithoutAnotherAction() async throws {
        let store = openStore()
        store.addShift(shift("first"))
        XCTAssertTrue(store.deleteShiftWithUndo(id: "first"))
        try await Task.sleep(for: .milliseconds(5200))
        XCTAssertEqual(store.pendingShiftDeletionCount, 0)
        XCTAssertNil(store.shiftDeletionUndoDeadline)
        XCTAssertTrue(store.undoableDeletedShifts.isEmpty)
        XCTAssertTrue(store.shifts.isEmpty)
    }

    func testNewOverlappingShiftBlocksTheEntireUndoWithoutDuplicatingPay() {
        let store = openStore()
        let first = shift("first"), second = shift("second", date: "2026-10-05")
        store.addShift(first); store.addShift(second)
        XCTAssertTrue(store.deleteShiftWithUndo(id: first.id, now: start))
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: start))
        let replacement = shift("replacement")
        store.addShift(replacement)
        XCTAssertThrowsError(try store.undoShiftDeletions(now: start.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? ShiftDeletionUndoError, .overlappingShift)
        }
        XCTAssertEqual(store.shifts, [replacement])
        XCTAssertEqual(store.pendingShiftDeletionCount, 2)
    }

    func testDetachingAccountClearsUndo() throws {
        let store = openStore()
        store.addShift(shift("first"))
        XCTAssertTrue(store.deleteShiftWithUndo(id: "first", now: start))
        store.detachUser(clearLocalState: false)
        XCTAssertEqual(store.pendingShiftDeletionCount, 0)
        XCTAssertNil(store.shiftDeletionUndoDeadline)
        XCTAssertTrue(try store.undoShiftDeletions(now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(store.shifts.isEmpty)
    }

    func testUndoDoesNotOverwriteAnIncomingRecordWithTheSameID() throws {
        let store = openStore()
        let original = shift("first")
        store.addShift(original)
        XCTAssertTrue(store.deleteShiftWithUndo(id: original.id, now: start))
        var incoming = original
        incoming.transport = 999
        store.addShift(incoming)
        XCTAssertTrue(try store.undoShiftDeletions(now: start.addingTimeInterval(1)).isEmpty)
        XCTAssertEqual(store.shifts, [incoming])
        XCTAssertEqual(store.pendingShiftDeletionCount, 0)
    }

    func testNewDeletionAfterExpiryDoesNotReviveAnOlderBatch() throws {
        let store = openStore()
        let first = shift("first"), second = shift("second", date: "2026-10-05")
        store.addShift(first); store.addShift(second)
        XCTAssertTrue(store.deleteShiftWithUndo(id: first.id, now: start))
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: start.addingTimeInterval(6)))
        XCTAssertEqual(store.pendingShiftDeletionCount, 1)
        XCTAssertEqual(try store.undoShiftDeletions(now: start.addingTimeInterval(7)), [second])
        XCTAssertEqual(store.shifts, [second])
    }
}
@MainActor
final class ShiftTemplateStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var stores: [ShiftStore] = []

    override func setUp() {
        super.setUp()
        suiteName = "ShiftBuilder.TemplateStoreTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        for store in stores { store.detachUser() }
        defaults.removePersistentDomain(forName: suiteName)
        stores.removeAll(); defaults = nil
        super.tearDown()
    }

    private func openStore() -> ShiftStore {
        let store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        stores.append(store)
        return store
    }

    private func template(start: Int = 540, end: Int = 1020) -> ShiftTemplate {
        ShiftTemplate(pattern: Shift(date: "2026-10-17", employer: "Template Cafe",
                                      segments: [WorkSegment(startMinute: start, endMinute: end, hourlyWage: 1350.5)],
                                      transport: 250.25))
    }

    private func waitForSaved(_ store: ShiftStore) async throws {
        for _ in 0..<200 {
            if store.pendingSyncCount == 0 && !store.syncWriteFailed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Templates were not committed")
    }

    func testSameEmployerTemplatesSurviveReopeningWithoutSchedulingWork() async throws {
        let store = openStore()
        XCTAssertTrue(store.saveShiftTemplate(template()))
        XCTAssertTrue(store.saveShiftTemplate(template(start: 1020, end: 1320)))
        try await waitForSaved(store)
        let expected = store.shiftTemplates
        XCTAssertEqual(expected.count, 2)
        XCTAssertTrue(store.shifts.isEmpty)
        XCTAssertTrue(store.actualPayments.isEmpty)
        store.detachUser()
        let reopened = openStore()
        XCTAssertEqual(Set(reopened.shiftTemplates.map(\.id)), Set(expected.map(\.id)))
        XCTAssertTrue(reopened.shifts.isEmpty)
    }

    func testDuplicatePatternDoesNotAddAnotherTemplate() async throws {
        let store = openStore()
        let first = template()
        XCTAssertTrue(store.saveShiftTemplate(first))
        XCTAssertTrue(store.saveShiftTemplate(template()))
        try await waitForSaved(store)
        XCTAssertEqual(store.shiftTemplates.map(\.id), [first.id])
        XCTAssertTrue(store.shifts.isEmpty)
    }

    func testRemovingActualShiftKeepsTemplateAndRemovingTemplateKeepsOtherShift() async throws {
        let store = openStore(), saved = template()
        XCTAssertTrue(store.saveShiftTemplate(saved))
        let first = saved.shift(on: "2026-10-20"), second = saved.shift(on: "2026-10-21")
        store.addShift(first); store.addShift(second)
        store.deleteShift(id: first.id)
        XCTAssertEqual(store.shiftTemplates, [saved])
        store.deleteShiftTemplate(id: saved.id)
        try await waitForSaved(store)
        XCTAssertTrue(store.shiftTemplates.isEmpty)
        XCTAssertEqual(store.shifts, [second])
    }

    func testEditingTemplateKeepsItsIdentityAndRecordedShiftsAfterReopening() async throws {
        let store = openStore(), original = template()
        XCTAssertTrue(store.saveShiftTemplate(original))
        let recorded = original.shift(on: "2026-10-20")
        store.addShift(recorded)
        let recordedPay = PayCalculation.pay(for: recorded, classifications: store.classifications)
        var pattern = original.pattern
        pattern.segments[0] = WorkSegment(startMinute: 600, endMinute: 960, hourlyWage: 1400.75)
        pattern.breakMinutes = 15; pattern.breakStartMinute = 720
        pattern.transport = 300.5
        XCTAssertTrue(store.updateShiftTemplate(original, pattern: pattern))
        let expected = ShiftTemplate(id: original.id, pattern: pattern)
        XCTAssertEqual(store.shiftTemplates, [expected])
        XCTAssertEqual(store.shifts, [recorded])
        XCTAssertEqual(PayCalculation.pay(for: recorded, classifications: store.classifications), recordedPay)
        try await waitForSaved(store)
        store.detachUser()
        let reopened = openStore()
        XCTAssertEqual(reopened.shiftTemplates, [expected])
        XCTAssertEqual(reopened.shifts, [recorded])
    }

    func testEditingTemplateDoesNotOverwriteAnotherMatchingPattern() {
        let store = openStore(), original = template(), other = template(start: 1020, end: 1320)
        XCTAssertTrue(store.saveShiftTemplate(original))
        XCTAssertTrue(store.saveShiftTemplate(other))
        XCTAssertFalse(store.updateShiftTemplate(original, pattern: other.pattern))
        XCTAssertEqual(store.shiftTemplates, [original, other])
        XCTAssertTrue(store.shifts.isEmpty)
    }

    func testStaleTemplateEditCannotOverwriteChangesOrRecreateDeletedTemplate() {
        let store = openStore(), original = template()
        XCTAssertTrue(store.saveShiftTemplate(original))
        var changed = original.pattern
        changed.transport = 999
        XCTAssertTrue(store.updateShiftTemplate(original, pattern: changed))
        let updated = ShiftTemplate(id: original.id, pattern: changed)
        XCTAssertFalse(store.updateShiftTemplate(original, pattern: original.pattern))
        XCTAssertEqual(store.shiftTemplates, [updated])
        store.deleteShiftTemplate(id: original.id)
        XCTAssertFalse(store.updateShiftTemplate(updated, pattern: original.pattern))
        XCTAssertTrue(store.shiftTemplates.isEmpty)
    }

    func testEmployerRenameUpdatesTemplateAndAccountWipeClearsItsLocalCopy() async throws {
        let store = openStore()
        var profile = EmployerProfile(name: "Template Cafe", defaultWage: 1350.5)
        store.saveEmployerProfile(profile)
        XCTAssertTrue(store.saveShiftTemplate(template()))
        profile.name = "Renamed Cafe"
        store.saveEmployerProfile(profile)
        try await waitForSaved(store)
        XCTAssertEqual(store.shiftTemplates.first?.pattern.employer, "Renamed Cafe")
        XCTAssertNotNil(defaults.data(forKey: "shiftmgr.shiftTemplates"))
        store.wipeLocalData()
        XCTAssertTrue(store.shiftTemplates.isEmpty)
        XCTAssertNil(defaults.data(forKey: "shiftmgr.shiftTemplates"))
    }
}
@MainActor
final class ShiftSaveReviewTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var store: ShiftStore!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "ShiftBuilder.SaveReviewTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
        store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertTrue(store.cloudDataReady)
    }

    override func tearDown() {
        store.detachUser(clearLocalState: false)
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        super.tearDown()
    }

    private var payslip: MonthlyPayslip {
        Aggregation.calculateMonthlyPay(store.shifts, classifications: store.classifications)
    }

    private func shift(_ id: String, employer: String = "Cafe", start: Int = 540, end: Int = 780) -> Shift {
        Shift(id: id, date: "2026-10-20", employer: employer,
              segments: [WorkSegment(startMinute: start, endMinute: end, hourlyWage: 1200)])
    }

    private func save(_ shift: Shift, confirmingOverlap: Bool = false) throws {
        try store.saveReviewedShift(store.prepareShiftSave(shift), confirmingOverlap: confirmingOverlap)
    }

    private func waitForSaved() async throws {
        for _ in 0..<200 {
            if store.pendingSyncCount == 0 && !store.syncWriteFailed { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Local records were not committed")
    }

    func testPreparingAndCancellingConfirmationLeavesRecordsAndPayUnchanged() throws {
        try save(shift("existing"))
        let before = store.shifts
        let pay = payslip
        let request = try store.prepareShiftSave(shift("candidate", employer: "Shop", start: 600, end: 840))
        XCTAssertTrue(request.requiresOverlapConfirmation)
        XCTAssertEqual(request.overlappingShifts, before)
        XCTAssertEqual(store.shifts, before)
        XCTAssertEqual(payslip, pay)
        XCTAssertThrowsError(try store.saveReviewedShift(request)) {
            XCTAssertEqual($0 as? ShiftSaveError, .confirmationRequired)
        }
        XCTAssertEqual(store.shifts, before)
    }

    func testConfirmedOverlapPersistsExactlyOnceWithAllConditions() async throws {
        let first = shift("existing")
        try save(first)
        var candidate = shift("candidate", employer: "Shop", start: 600, end: 840)
        candidate.segments[0].hourlyWage = 1234.75
        candidate.breakMinutes = 15; candidate.breakStartMinute = 630
        candidate.transport = 250.5; candidate.otherAllowance = 12.25
        let request = try store.prepareShiftSave(candidate)
        try store.saveReviewedShift(request, confirmingOverlap: true)
        XCTAssertEqual(store.shifts, [first, candidate])
        XCTAssertThrowsError(try store.saveReviewedShift(request, confirmingOverlap: true)) {
            XCTAssertEqual($0 as? ShiftSaveError, .recordsChanged)
        }
        try await waitForSaved()
        store.detachUser(clearLocalState: false)
        store = ShiftStore(defaults: defaults, remindersEnabled: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertEqual(store.shifts.sorted { $0.id < $1.id }, [first, candidate].sorted { $0.id < $1.id })
        XCTAssertEqual(payslip.grossTotal, 4800 + 1234.75 * 3.75 + 250.5 + 12.25, accuracy: 0.01)
    }

    func testInvalidOverlappingCandidateIsRejectedBeforeConfirmation() throws {
        try save(shift("existing"))
        var candidate = shift("bad")
        candidate.segments[0].hourlyWage = 0
        XCTAssertThrowsError(try store.prepareShiftSave(candidate)) {
            guard let error = $0 as? ShiftSaveError, case .invalid(let errors) = error else { return XCTFail("Expected invalid input") }
            XCTAssertFalse(errors.isEmpty)
        }
        XCTAssertEqual(store.shifts.count, 1)
    }

    func testConsentDoesNotCoverAConflictAddedWhilePromptWasOpen() throws {
        try save(shift("existing"))
        let request = try store.prepareShiftSave(shift("candidate", start: 600, end: 840))
        store.addShift(shift("incoming", employer: "Another job", start: 780, end: 900))
        XCTAssertThrowsError(try store.saveReviewedShift(request, confirmingOverlap: true)) {
            XCTAssertEqual($0 as? ShiftSaveError, .recordsChanged)
        }
        XCTAssertEqual(Set(store.shifts.map(\.id)), ["existing", "incoming"])
    }

    func testConsentDoesNotCoverChangedConflictConditions() throws {
        var existing = shift("existing")
        try save(existing)
        let request = try store.prepareShiftSave(shift("candidate", start: 600, end: 840))
        existing.segments[0].hourlyWage = 1500
        store.updateShift(existing)
        XCTAssertThrowsError(try store.saveReviewedShift(request, confirmingOverlap: true)) {
            XCTAssertEqual($0 as? ShiftSaveError, .recordsChanged)
        }
        XCTAssertEqual(store.shifts, [existing])
    }

    func testConsentCannotCarryAcrossReattachedAccountSessions() async throws {
        try save(shift("existing"))
        try await waitForSaved()
        let request = try store.prepareShiftSave(shift("candidate"))
        store.detachUser(clearLocalState: false)
        store.attachUser(uid: LocalDeviceTestTransport.accountID)
        XCTAssertTrue(store.cloudDataReady)
        XCTAssertThrowsError(try store.saveReviewedShift(request, confirmingOverlap: true)) {
            XCTAssertEqual($0 as? ShiftSaveError, .unavailable)
        }
        XCTAssertEqual(store.shifts.map(\.id), ["existing"])
    }

    func testEditingAnOverlapUpdatesTheOriginalInsteadOfAddingAnotherRecord() throws {
        var first = shift("first")
        try save(first); try save(shift("second", start: 780, end: 1020))
        first.segments[0].hourlyWage = 1250
        let ownEdit = try store.prepareShiftSave(first, editing: true)
        XCTAssertFalse(ownEdit.requiresOverlapConfirmation)
        try store.saveReviewedShift(ownEdit)
        first.segments[0].endMinute = 840
        let overlapEdit = try store.prepareShiftSave(first, editing: true)
        XCTAssertTrue(overlapEdit.requiresOverlapConfirmation)
        try store.saveReviewedShift(overlapEdit, confirmingOverlap: true)
        XCTAssertEqual(store.shifts.count, 2)
        XCTAssertEqual(store.shifts.first, first)
    }

    func testEditConfirmationDoesNotOverwriteAnInterveningChange() throws {
        let first = shift("first")
        try save(first); try save(shift("second", start: 780, end: 1020))
        var edited = first; edited.segments[0].endMinute = 840
        let request = try store.prepareShiftSave(edited, editing: true)
        var incoming = first; incoming.transport = 999
        store.updateShift(incoming)
        XCTAssertThrowsError(try store.saveReviewedShift(request, confirmingOverlap: true)) {
            XCTAssertEqual($0 as? ShiftSaveError, .recordsChanged)
        }
        XCTAssertEqual(store.shifts.first, incoming)
    }

    func testUndoRestoresAPreviouslyConfirmedOverlappingShift() throws {
        let first = shift("first"), second = shift("second", employer: "Shop", start: 600, end: 840)
        try save(first); try save(second, confirmingOverlap: true)
        let expectedPay = payslip
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: now))
        XCTAssertEqual(try store.undoShiftDeletions(now: now.addingTimeInterval(1)), [second])
        XCTAssertEqual(store.shifts, [first, second])
        XCTAssertEqual(payslip, expectedPay)
    }

    func testUndoRestoresBothMembersOfAPreviouslyOverlappingBatch() throws {
        let first = shift("first"), second = shift("second", employer: "Shop", start: 600, end: 840)
        try save(first); try save(second, confirmingOverlap: true)
        XCTAssertTrue(store.deleteShiftWithUndo(id: first.id, now: now))
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: now.addingTimeInterval(0.1)))
        XCTAssertEqual(Set(try store.undoShiftDeletions(now: now.addingTimeInterval(1)).map(\.id)), [first.id, second.id])
        XCTAssertEqual(store.shifts, [first, second])
    }

    func testUndoRejectsAConflictThatChangedAfterDeletion() throws {
        var first = shift("first")
        let second = shift("second", employer: "Shop", start: 600, end: 840)
        try save(first); try save(second, confirmingOverlap: true)
        XCTAssertTrue(store.deleteShiftWithUndo(id: second.id, now: now))
        first.segments[0].endMinute = 900
        store.updateShift(first)
        XCTAssertThrowsError(try store.undoShiftDeletions(now: now.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? ShiftDeletionUndoError, .overlappingShift)
        }
        XCTAssertEqual(store.shifts, [first])
    }
}
#endif
