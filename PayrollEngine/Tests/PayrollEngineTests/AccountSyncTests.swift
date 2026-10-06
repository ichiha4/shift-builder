import XCTest
@testable import PayrollEngine

final class AccountSyncTests: XCTestCase {
    private func shift(_ id: String, wage: Double = 1200) -> Shift {
        Shift(id: id, date: "2026-10-03", employer: "Cafe", segments: [WorkSegment(startMinute: 600, endMinute: 900, hourlyWage: wage)])
    }
    private func base() -> AccountSnapshot { var s = AccountSnapshot(); s.shifts = [shift("a")]; return s }

    func testConcurrentAdditionsSurviveInEitherOrder() throws {
        let empty = AccountSnapshot(); var a = empty; a.shifts = [shift("a")]; var b = empty; b.shifts = [shift("b")]
        let x = try SyncBatch(from: empty, to: a), y = try SyncBatch(from: empty, to: b)
        XCTAssertTrue(try y.conflicts(with: a).isEmpty)
        XCTAssertEqual(Set(try y.applying(to: a).shifts.map(\.id)), ["a", "b"])
        XCTAssertEqual(Set(try x.applying(to: b).shifts.map(\.id)), ["a", "b"])
    }
    func testUnrelatedDeletionAndExpenseSurviveEdit() throws {
        var before = base(); before.shifts.append(shift("b")); var local = before; local.shifts[0].transport = 200
        var remote = before; remote.shifts.removeLast(); remote.expenses = [Expense(id: "e", date: "2026-10-03", category: "食費", amount: 500)]
        let batch = try SyncBatch(from: before, to: local); XCTAssertTrue(try batch.conflicts(with: remote).isEmpty)
        let result = try batch.applying(to: remote)
        XCTAssertEqual(result.shifts.map(\.id), ["a"]); XCTAssertEqual(result.expenses, remote.expenses); XCTAssertEqual(result.shifts[0].transport, 200)
    }
    func testSameShiftConcurrentEditConflicts() throws {
        let before = base(); var a = before; a.shifts[0].transport = 200; var b = before; b.shifts[0].transport = 300
        XCTAssertEqual(try SyncBatch(from: before, to: a).conflicts(with: b).count, 1)
    }
    func testStaleEditCannotSilentlyResurrectDeletion() throws {
        let before = base(); var local = before; local.shifts[0].transport = 200
        XCTAssertEqual(try SyncBatch(from: before, to: local).conflicts(with: AccountSnapshot()).count, 1)
    }
    func testDeletionVersusRemoteEditConflicts() throws {
        let before = base(); var remote = before; remote.shifts[0].transport = 200
        XCTAssertEqual(try SyncBatch(from: before, to: AccountSnapshot()).conflicts(with: remote).count, 1)
    }
    func testAddEditDeleteRetriesAreIdempotent() throws {
        let before = base(); var local = before; local.shifts[0].transport = 200; local.shifts.append(shift("b"))
        let batch = try SyncBatch(from: before, to: local)
        XCTAssertTrue(try batch.conflicts(with: local).isEmpty); XCTAssertEqual(try batch.applying(to: local), local)
        XCTAssertTrue(try SyncBatch(from: before, to: AccountSnapshot()).conflicts(with: AccountSnapshot()).isEmpty)
    }
    func testDurableOfflineQueueOverlaysRemoteWithoutDroppingEither() throws {
        let before = base(); var journal = SyncJournal(snapshot: before); journal.serverDocumentKnown = true
        var local = before; local.shifts[0].transport = 200; try journal.recordEdit(to: local)
        local.expenses = [Expense(id: "e", date: "2026-10-03", category: "食費", amount: 500)]; try journal.recordEdit(to: local)
        var restored = try JSONDecoder().decode(SyncJournal.self, from: JSONEncoder().encode(journal))
        var remote = before; remote.shifts.append(shift("b")); restored.observe(remote, revision: 1)
        let result = try restored.workingSnapshot()
        XCTAssertEqual(Set(result.shifts.map(\.id)), ["a", "b"]); XCTAssertEqual(result.shifts[0].transport, 200)
        XCTAssertEqual(result.expenses, local.expenses); XCTAssertEqual(restored.pending.count, 2)
    }
    func testAcknowledgementRetainsEditMadeDuringUpload() throws {
        var journal = SyncJournal(); let first = base(); try journal.recordEdit(to: first); let id = journal.pending[0].id
        var second = first; second.shifts[0].transport = 200; try journal.recordEdit(to: second)
        journal.acknowledge(id: id, snapshot: first, revision: 1)
        XCTAssertEqual(journal.pending.count, 1); XCTAssertEqual(try journal.workingSnapshot(), second)
    }
    func testOldAcknowledgementDoesNotRevertNewerListener() throws {
        var journal = SyncJournal(); let first = base(); try journal.recordEdit(to: first); let id = journal.pending[0].id
        var remote = first; remote.shifts[0].transport = 400; journal.observe(remote, revision: 2)
        journal.acknowledge(id: id, snapshot: first, revision: 1)
        XCTAssertEqual(try journal.workingSnapshot(), remote); XCTAssertEqual(journal.revision, 2)
    }
    func testEmployerRenameAndRelatedHistoryAreOneBatch() throws {
        var before = base(); before.employerProfiles = [EmployerProfile(id: "p", name: "Cafe")]
        before.actualPayments = [ActualPayment(id: "pay", employer: "Cafe", payDate: "2026-10-25", amount: 10000)]
        var local = before; local.employerProfiles[0].name = "New"; local.shifts[0].employer = "New"; local.actualPayments[0].employer = "New"
        let batch = try SyncBatch(from: before, to: local)
        XCTAssertEqual(Set(batch.changes.map(\.collection)), [.employerProfiles, .shifts, .actualPayments]); XCTAssertEqual(try batch.applying(to: before), local)
        var remote = before; remote.actualPayments[0].amount = 12000; XCTAssertFalse(try batch.conflicts(with: remote).isEmpty)
    }
    func testExplicitKeepLocalChecksAnotherConcurrentEdit() throws {
        let before = base(); var local = before; local.shifts[0].transport = 200; var remote = before; remote.shifts[0].transport = 300
        var journal = SyncJournal(snapshot: before); try journal.recordEdit(to: local); let oldID = journal.pending[0].id; journal.observe(remote, revision: 1)
        try journal.keepLocalForFirstBatch(); XCTAssertNotEqual(journal.pending[0].id, oldID)
        XCTAssertTrue(try journal.pending[0].conflicts(with: remote).isEmpty)
        remote.shifts[0].transport = 400; XCTAssertFalse(try journal.pending[0].conflicts(with: remote).isEmpty)
    }
    func testKeepRemoteRetainsLaterUnrelatedExpense() throws {
        let before = base(); var local = before; local.shifts[0].transport = 200
        var journal = SyncJournal(snapshot: before); try journal.recordEdit(to: local)
        local.expenses = [Expense(id: "e", date: "2026-10-03", category: "食費", amount: 500)]; try journal.recordEdit(to: local)
        var remote = before; remote.shifts[0].transport = 300; journal.observe(remote, revision: 1); journal.keepRemoteForFirstBatch()
        XCTAssertEqual(try journal.workingSnapshot().shifts, remote.shifts); XCTAssertEqual(try journal.workingSnapshot().expenses, local.expenses)
    }
    func testReorderingRecordsCreatesNoWrite() throws {
        var before = base(); before.shifts.append(shift("b")); var local = before; local.shifts.reverse()
        XCTAssertTrue(try SyncBatch(from: before, to: local).changes.isEmpty)
    }
    func testDuplicateIDsRefuseSync() throws {
        var bad = base(); bad.shifts.append(shift("a", wage: 1400)); XCTAssertThrowsError(try SyncBatch(from: AccountSnapshot(), to: bad))
    }
    func testLegacyOptionalArraysAndMalformedDocument() throws {
        XCTAssertEqual(try JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"shifts":[],"expenses":[],"employerProfiles":[],"deductions":[]}"#.utf8)), AccountSnapshot())
        XCTAssertThrowsError(try JSONDecoder().decode(AccountSnapshot.self, from: Data(#"{"shifts":[]}"#.utf8)))
    }
}
