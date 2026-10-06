import XCTest
import SwiftUI
import UIKit
@testable import ShiftManagerApp

@MainActor
private final class MemoryCloud: CloudSyncTransport {
    var accounts: [String: CloudAccountState] = [:]
    var observers: [String: [(UUID, (Result<CloudObservation, Error>) -> Void)]] = [:]
    var failWrites = false
    var writeDelay: Duration = .zero
    var nextCommitError: Error?
    var beforeMark: ((String) -> Void)?
    var commitCount = 0

    func state(_ uid: String) -> CloudAccountState { accounts[uid] ?? CloudAccountState(snapshot: AccountSnapshot(), exists: false) }
    func observe(uid: String, receive: @escaping (Result<CloudObservation, Error>) -> Void) -> () -> Void {
        let id = UUID(); observers[uid, default: []].append((id, receive))
        receive(.success(CloudObservation(state: state(uid), fromCache: false)))
        return { [weak self] in self?.observers[uid]?.removeAll { $0.0 == id } }
    }
    func emit(_ uid: String, cached: Bool = false) {
        for (_, callback) in observers[uid] ?? [] { callback(.success(CloudObservation(state: state(uid), fromCache: cached))) }
    }
    func commit(uid: String, batch: SyncBatch, allowCreate: Bool) async throws -> CloudCommit {
        commitCount += 1
        if writeDelay != .zero { try await Task.sleep(for: writeDelay) }
        if let error = nextCommitError { nextCommitError = nil; throw error }
        if failWrites { throw URLError(.notConnectedToInternet) }
        var current = state(uid)
        guard !current.deleted else { throw AccountSyncError.accountDeleted }
        guard current.exists || allowCreate else { throw CloudSyncFailure.documentRemoved }
        if current.receipts.contains(batch.id) { return .applied(current) }
        if try !batch.conflicts(with: current.snapshot).isEmpty { return .conflict(current) }
        current.snapshot = try batch.applying(to: current.snapshot)
        current.revision += 1; current.exists = true; current.receipts.append(batch.id)
        accounts[uid] = current; emit(uid)
        return .applied(current)
    }
    func readForDeletion(uid: String) async throws -> CloudAccountState { state(uid) }
    func markDeleted(uid: String, backup: AccountDeletionBackup) async throws {
        beforeMark?(uid); beforeMark = nil
        guard state(uid) == backup.state else { throw CloudSyncFailure.deletionChanged }
        accounts[uid] = CloudAccountState(snapshot: AccountSnapshot(), revision: backup.state.revision + 1,
                                           deleted: true, deletionToken: backup.token)
        emit(uid)
    }
    func rollbackDeletion(uid: String, backup: AccountDeletionBackup) async throws -> CloudAccountState {
        let current = state(uid)
        guard current.deleted else { return current }
        guard current.deletionToken == backup.token else { throw AccountSyncError.accountDeleted }
        var restored = backup.state; restored.revision = current.revision + 1; restored.exists = true
        accounts[uid] = restored; emit(uid); return restored
    }
}

@MainActor
final class ShiftStoreSyncTests: XCTestCase {
    private var suites: [String] = []
    private func defaults() -> UserDefaults {
        let name = "ShiftBuilder.SyncTests." + UUID().uuidString; suites.append(name)
        return UserDefaults(suiteName: name)!
    }
    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        super.tearDown()
    }
    private func store(_ cloud: MemoryCloud, defaults: UserDefaults? = nil) -> ShiftStore {
        ShiftStore(defaults: defaults ?? self.defaults(), transport: cloud, remindersEnabled: false)
    }
    private func shift(_ id: String, wage: Double = 1200) -> Shift {
        Shift(id: id, date: "2026-10-03", employer: "Cafe", segments: [WorkSegment(startMinute: 600, endMinute: 900, hourlyWage: wage)])
    }
    private func seed(_ cloud: MemoryCloud) {
        var s = AccountSnapshot(); s.shifts = [shift("original")]
        cloud.accounts["a"] = CloudAccountState(snapshot: s, revision: 1)
    }
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition did not become true", file: file, line: line)
    }
    func testTwoStoresAddingDifferentRecordsRetainBoth() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        let a = store(cloud), b = store(cloud); a.attachUser(uid: "a"); b.attachUser(uid: "a")
        a.addShift(shift("device-a")); b.addShift(shift("device-b"))
        try await eventually { a.pendingSyncCount == 0 && b.pendingSyncCount == 0 }
        XCTAssertEqual(Set(cloud.state("a").snapshot.shifts.map(\.id)), ["original", "device-a", "device-b"])
        XCTAssertEqual(a.shifts, b.shifts); a.detachUser(); b.detachUser()
    }
    func testSameRecordConflictIsVisibleAndRemoteChoicePreservesOtherRecords() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        let a = store(cloud), b = store(cloud); a.attachUser(uid: "a"); b.attachUser(uid: "a")
        var x = a.shifts[0]; x.transport = 100; a.updateShift(x)
        var y = b.shifts[0]; y.transport = 200; b.updateShift(y)
        try await eventually { b.hasSyncConflict }
        XCTAssertEqual(b.conflictChanges.count, 1); XCTAssertEqual(b.shifts[0].transport, 200)
        b.resolveSyncConflict(keepLocal: false)
        XCTAssertEqual(b.shifts[0].transport, 100); XCTAssertEqual(b.pendingSyncCount, 0)
        a.detachUser(); b.detachUser()
    }
    func testExplicitLocalChoiceUploadsAfterRebase() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        let a = store(cloud), b = store(cloud); a.attachUser(uid: "a"); b.attachUser(uid: "a")
        var x = a.shifts[0]; x.transport = 100; a.updateShift(x)
        var y = b.shifts[0]; y.transport = 200; b.updateShift(y)
        try await eventually { b.hasSyncConflict }; b.resolveSyncConflict(keepLocal: true)
        try await eventually { b.pendingSyncCount == 0 }
        XCTAssertEqual(cloud.state("a").snapshot.shifts[0].transport, 200)
        a.detachUser(); b.detachUser()
    }
    func testOfflineFailureAndRelaunchKeepUnsentWork() async throws {
        let cloud = MemoryCloud(); seed(cloud); cloud.failWrites = true
        let d = defaults(); let old = store(cloud, defaults: d); old.attachUser(uid: "a"); old.addShift(shift("offline"))
        try await eventually { old.syncWriteFailed }; old.detachUser()
        let resumed = store(cloud, defaults: d); resumed.attachUser(uid: "a")
        XCTAssertTrue(resumed.shifts.contains { $0.id == "offline" }); XCTAssertEqual(resumed.pendingSyncCount, 1)
        // Finish the offline attempt before switching the network back on.
        try await eventually { resumed.syncWriteFailed }
        cloud.failWrites = false; resumed.retryCloudSync()
        try await eventually { resumed.pendingSyncCount == 0 }
        XCTAssertTrue(cloud.state("a").snapshot.shifts.contains { $0.id == "offline" }); resumed.detachUser()
    }
    func testSwitchingAccountsDoesNotUploadPreviousAccountJournal() async throws {
        let cloud = MemoryCloud(); seed(cloud); cloud.failWrites = true
        let s = store(cloud); s.attachUser(uid: "a"); s.addShift(shift("private"))
        try await eventually { s.syncWriteFailed }; s.attachUser(uid: "b")
        XCTAssertTrue(s.shifts.isEmpty); XCTAssertEqual(s.pendingSyncCount, 0)
        cloud.failWrites = false; s.addShift(shift("b-only")); try await eventually { s.pendingSyncCount == 0 }
        XCTAssertEqual(cloud.state("b").snapshot.shifts.map(\.id), ["b-only"]); s.detachUser()
    }
    func testDelayedOldWriteCannotReplaceNewAccountView() async throws {
        let cloud = MemoryCloud(); seed(cloud); cloud.writeDelay = .milliseconds(50)
        let s = store(cloud); s.attachUser(uid: "a"); s.addShift(shift("old"))
        try await eventually { cloud.commitCount > 0 }; s.attachUser(uid: "b"); s.addShift(shift("new"))
        try await eventually { s.pendingSyncCount == 0 }
        XCTAssertEqual(s.shifts.map(\.id), ["new"]); s.detachUser()
    }
    func testDeletedDocumentCannotBeRecreatedByStaleJournal() async throws {
        let cloud = MemoryCloud(); seed(cloud); cloud.failWrites = true
        let s = store(cloud); s.attachUser(uid: "a"); s.addShift(shift("unsent")); try await eventually { s.syncWriteFailed }
        cloud.accounts.removeValue(forKey: "a"); cloud.emit("a")
        XCTAssertFalse(s.cloudDataReady); cloud.failWrites = false; s.retryCloudSync()
        XCTAssertFalse(cloud.state("a").exists); s.detachUser()
    }
    func testDeletionBacksUpLatestServerCopyAndRollbackRestoresIt() async throws {
        let cloud = MemoryCloud(); seed(cloud); let s = store(cloud); s.attachUser(uid: "a")
        cloud.accounts["a"]?.snapshot.shifts.append(shift("not-yet-in-listener")); cloud.accounts["a"]?.revision += 1
        try await s.prepareAccountDeletion()
        XCTAssertTrue(cloud.state("a").deleted); XCTAssertTrue(cloud.state("a").snapshot.shifts.isEmpty)
        XCTAssertTrue(s.hasInterruptedAccountDeletion)
        try await s.recoverAccountDataAfterFailedDeletion()
        XCTAssertFalse(cloud.state("a").deleted); XCTAssertEqual(cloud.state("a").snapshot.shifts.count, 2)
        XCTAssertFalse(s.hasInterruptedAccountDeletion); s.detachUser()
    }
    func testConcurrentWriteDuringDeletionIsBackedUpBeforeRetry() async throws {
        let cloud = MemoryCloud(); seed(cloud); let s = store(cloud); s.attachUser(uid: "a")
        cloud.beforeMark = { uid in cloud.accounts[uid]?.snapshot.shifts.append(self.shift("raced")); cloud.accounts[uid]?.revision += 1 }
        try await s.prepareAccountDeletion(); try await s.recoverAccountDataAfterFailedDeletion()
        XCTAssertTrue(cloud.state("a").snapshot.shifts.contains { $0.id == "raced" }); s.detachUser()
    }
    func testInterruptedDeletionSurvivesRelaunchAndRequiresRecovery() async throws {
        let cloud = MemoryCloud(); seed(cloud); let d = defaults(); let old = store(cloud, defaults: d); old.attachUser(uid: "a")
        try await old.prepareAccountDeletion(); old.detachUser()
        let restarted = store(cloud, defaults: d); restarted.attachUser(uid: "a")
        XCTAssertTrue(restarted.hasInterruptedAccountDeletion); XCTAssertFalse(restarted.cloudDataReady)
        try await restarted.recoverAccountDataAfterFailedDeletion()
        XCTAssertEqual(restarted.shifts.map(\.id), ["original"]); XCTAssertTrue(restarted.cloudDataReady); restarted.detachUser()
    }
    func testRemoteDeletionPendingRetainsUnsentChangesAcrossRollback() async throws {
        let cloud = MemoryCloud(); seed(cloud); cloud.failWrites = true
        let d = defaults(); let s = store(cloud, defaults: d); s.attachUser(uid: "a")
        s.addShift(shift("offline")); try await eventually { s.syncWriteFailed }
        let before = cloud.state("a")
        var notified = false; s.onAccountDeleted = { notified = true }
        cloud.accounts["a"] = CloudAccountState(snapshot: AccountSnapshot(), revision: 2, deleted: true, deletionToken: "elsewhere")
        cloud.emit("a")
        XCTAssertTrue(notified); XCTAssertTrue(s.remoteDeletionPending); XCTAssertFalse(s.cloudDataReady)
        XCTAssertTrue(s.shifts.contains { $0.id == "offline" }); XCTAssertNotNil(d.data(forKey: "shiftmgr.syncJournal.v1"))
        var restored = before; restored.revision = 3; cloud.accounts["a"] = restored
        cloud.failWrites = false; cloud.emit("a")
        try await eventually { s.pendingSyncCount == 0 }
        XCTAssertFalse(s.remoteDeletionPending); XCTAssertTrue(s.cloudDataReady)
        XCTAssertTrue(cloud.state("a").snapshot.shifts.contains { $0.id == "offline" }); s.detachUser()
    }
    func testLegacyCacheIsRetainedForRecoveryInsteadOfOverwritingCloud() throws {
        let cloud = MemoryCloud(); seed(cloud); let d = defaults()
        d.set("a", forKey: "shiftmgr.cacheOwnerUID"); d.set(try JSONEncoder().encode([shift("legacy-unsent")]), forKey: "shiftmgr.shifts")
        let s = store(cloud, defaults: d); s.attachUser(uid: "a")
        XCTAssertEqual(s.shifts.map(\.id), ["original"])
        let recovered = try JSONDecoder().decode(AccountSnapshot.self, from: XCTUnwrap(s.legacyRecoveryData))
        XCTAssertEqual(recovered.shifts.map(\.id), ["legacy-unsent"]); s.detachUser()
    }
    func testRecurringChargeHasOneIDAcrossDevices() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        cloud.accounts["a"]?.snapshot.recurringExpenses = [RecurringExpense(id: "rent", name: "Rent", category: "家賃・光熱", amount: 50000, dayOfMonth: 1)]
        let a = store(cloud), b = store(cloud); a.attachUser(uid: "a"); b.attachUser(uid: "a")
        try await eventually { a.pendingSyncCount == 0 && b.pendingSyncCount == 0 }
        XCTAssertEqual(cloud.state("a").snapshot.expenses.filter { $0.recurringExpenseId == "rent" }.count, 1)
        a.detachUser(); b.detachUser()
    }
    func testCorruptJournalIsNotSilentlyReplaced() {
        let cloud = MemoryCloud(); seed(cloud); let d = defaults(); let damaged = Data("unreadable".utf8)
        d.set("a", forKey: "shiftmgr.cacheOwnerUID"); d.set(damaged, forKey: "shiftmgr.syncJournal.v1")
        let s = store(cloud, defaults: d); s.attachUser(uid: "a")
        XCTAssertFalse(s.cloudDataReady); XCTAssertTrue(s.cloudReadFailed)
        XCTAssertEqual(d.data(forKey: "shiftmgr.syncJournal.v1"), damaged); s.detachUser()
    }
    func testConflictScreenRendersForVisualReview() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        let a = store(cloud), b = store(cloud); a.attachUser(uid: "a"); b.attachUser(uid: "a")
        var x = a.shifts[0]; x.transport = 100; a.updateShift(x)
        var y = b.shifts[0]; y.transport = 200; b.updateShift(y)
        try await eventually { b.hasSyncConflict }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        for large in [false, true] {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            window.overrideUserInterfaceStyle = .light
            let view = SyncConflictView().environmentObject(b).environment(\.locale, Locale(identifier: "ja"))
                .environment(\.dynamicTypeSize, large ? .accessibility3 : .large)
            let controller = UIHostingController(rootView: view)
            window.rootViewController = controller; window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(300)); controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = large ? "Sync-conflict-ja-large" : "Sync-conflict-ja"
            attachment.lifetime = .keepAlways; add(attachment); window.isHidden = true
        }
        a.detachUser(); b.detachUser()
    }

    func testDelayedDeletionRejectionAfterRollbackDoesNotLockLiveAccount() async throws {
        let cloud = MemoryCloud(); seed(cloud)
        cloud.writeDelay = .milliseconds(100); cloud.nextCommitError = AccountSyncError.accountDeleted
        let s = store(cloud); s.attachUser(uid: "a"); s.addShift(shift("retained"))
        try await eventually { cloud.commitCount > 0 }
        let before = cloud.state("a")
        cloud.accounts["a"] = CloudAccountState(snapshot: AccountSnapshot(), revision: 2, deleted: true, deletionToken: "other")
        cloud.emit("a")
        var restored = before; restored.revision = 3; cloud.accounts["a"] = restored; cloud.emit("a")
        try await eventually { s.pendingSyncCount == 0 }
        XCTAssertTrue(s.cloudDataReady); XCTAssertTrue(cloud.state("a").snapshot.shifts.contains { $0.id == "retained" })
        s.detachUser()
    }

}



extension ShiftStoreSyncTests {
    private func importedCandidate(_ id: Int, date: String = "2026-10-06", pause: Int = 30) -> ShiftImportCandidate {
        .init(id:id,date:date,startMinute:1020,endMinute:1320,breakMinutes:pause)
    }
    func testPhotoImportRefusesUnreadAccount() {
        let s=store(MemoryCloud())
        XCTAssertThrowsError(try s.importShiftCandidates([importedCandidate(0)],profile:EmployerProfile(name:"Cafe",defaultWage:1200)))
        XCTAssertTrue(s.shifts.isEmpty)
    }
    func testPhotoImportInvalidRowLeavesAllRecordsAndJournalUntouched() {
        let cloud=MemoryCloud(); seed(cloud)
        let s=store(cloud); s.attachUser(uid:"a")
        let before=s.shifts
        XCTAssertThrowsError(try s.importShiftCandidates([importedCandidate(0),importedCandidate(1,date:"2026-10-08",pause:-1)],profile:EmployerProfile(name:"Cafe",defaultWage:1200)))
        XCTAssertEqual(s.shifts,before); XCTAssertEqual(s.pendingSyncCount,0)
        s.detachUser()
    }
    func testPhotoImportUsesOneBatchAndRepeatedImportAddsNothing() async throws {
        let cloud=MemoryCloud(); let s=store(cloud); s.attachUser(uid:"a")
        let profile=EmployerProfile(name:"Cafe",defaultWage:1200)
        let candidates=[importedCandidate(0),importedCandidate(1,date:"2026-10-08")]
        let first=try s.importShiftCandidates(candidates,profile:profile)
        XCTAssertEqual(first.shifts.count,2); XCTAssertEqual(s.pendingSyncCount,1)
        try await eventually { s.pendingSyncCount == 0 }
        let ids=s.shifts.map(\.id)
        let again=try s.importShiftCandidates(candidates,profile:profile)
        XCTAssertTrue(again.shifts.isEmpty); XCTAssertEqual(again.duplicateCount,2)
        XCTAssertEqual(s.shifts.map(\.id),ids); XCTAssertEqual(s.pendingSyncCount,0)
        s.detachUser()
    }
    func testPhotoImportOfflineJournalSurvivesRelaunch() async throws {
        let cloud=MemoryCloud(); cloud.failWrites=true
        let settings=defaults(); let old=store(cloud,defaults:settings); old.attachUser(uid:"a")
        _=try old.importShiftCandidates([importedCandidate(0),importedCandidate(1,date:"2026-10-08")],profile:EmployerProfile(name:"Cafe",defaultWage:1200))
        try await eventually { old.syncWriteFailed }; old.detachUser()
        let resumed=store(cloud,defaults:settings); resumed.attachUser(uid:"a")
        XCTAssertEqual(resumed.shifts.count,2); XCTAssertEqual(resumed.pendingSyncCount,1)
        try await eventually { resumed.syncWriteFailed }
        cloud.failWrites=false; resumed.retryCloudSync()
        try await eventually { resumed.pendingSyncCount == 0 }
        XCTAssertEqual(cloud.state("a").snapshot.shifts.count,2)
        resumed.detachUser()
    }
    func testPhotoImportReviewRendersForVisualCheck() async throws {
        let cloud=MemoryCloud(); let s=store(cloud); s.attachUser(uid:"a")
        s.saveEmployerProfile(EmployerProfile(name:"サンプルカフェ",defaultWage:1200))
        let preview=try await ShiftPhotoReader.read(ShiftPhotoSample.data())
        let subscriptions=SubscriptionManager()
        let root=NavigationStack { ShiftPhotoImportView(month:"2026-10",preview:preview) }
            .environmentObject(s).environmentObject(subscriptions).environmentObject(NotificationLogStore())
            .environment(\.locale,Locale(identifier:"ja"))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window=UIWindow(windowScene:scene); window.frame=CGRect(x:0,y:0,width:393,height:852)
        let controller=UIHostingController(rootView:root); window.rootViewController=controller; window.makeKeyAndVisible()
        defer { window.isHidden=true; s.detachUser() }
        try await Task.sleep(for:.milliseconds(400))
        controller.view.layoutIfNeeded()
        let screenshot=UIGraphicsImageRenderer(bounds:controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in:controller.view.bounds,afterScreenUpdates:true)
        }
        let attachment=XCTAttachment(image:screenshot); attachment.name="Photo-import-review-ja"; attachment.lifetime = .keepAlways
        add(attachment)
        let output=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("photo-import-review.png")
        try XCTUnwrap(screenshot.pngData()).write(to:output)
        print("PHOTO_IMPORT_SCREENSHOT="+output.path)
    }
}

