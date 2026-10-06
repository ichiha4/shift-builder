import XCTest
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore
@testable import ShiftManagerApp

@MainActor
final class FirestoreSyncTests: XCTestCase {
    private var users: [String: (FirebaseAuth.User, FirebaseAuth.User)] = [:]
    private func clients() async throws -> (FirestoreSyncTransport, FirestoreSyncTransport, String) {
        guard ProcessInfo.processInfo.environment["SHIFTBUILDER_EMULATOR_TESTS"] == "1" else {
            throw XCTSkip("Run release-tests/native_emulator_runner.py through Firebase emulators:exec")
        }
        func makeApp() -> FirebaseApp {
            let options = FirebaseOptions(googleAppID: "1:100000000000:ios:1111111111111111", gcmSenderID: "100000000000")
            options.apiKey = "fake-emulator-api-key"; options.projectID = "demo-shiftbuilder-sync"
            let name = "SyncEmulator-" + UUID().uuidString
            FirebaseApp.configure(name: name, options: options)
            return FirebaseApp.app(name: name)!
        }
        let appA = makeApp(), appB = makeApp()
        let authA = Auth.auth(app: appA), authB = Auth.auth(app: appB)
        authA.useEmulator(withHost: "127.0.0.1", port: 9095); authB.useEmulator(withHost: "127.0.0.1", port: 9095)
        let email = "sync-" + UUID().uuidString + "@example.test", password = "emulator-fixture-password"
        let user = try await authA.createUser(withEmail: email, password: password).user
        let secondUser = try await authB.signIn(withEmail: email, password: password).user
        XCTAssertEqual(user.uid, secondUser.uid)
        users[user.uid] = (user, secondUser)
        func database(_ app: FirebaseApp) -> Firestore {
            let db = Firestore.firestore(app: app)
            let settings = db.settings; settings.host = "127.0.0.1:8085"; settings.isSSLEnabled = false
            settings.isPersistenceEnabled = false; db.settings = settings
            return db
        }
        return (FirestoreSyncTransport(db: database(appA)), FirestoreSyncTransport(db: database(appB)), user.uid)
    }
    private func shift(_ id: String, transport: Double = 0) -> Shift {
        Shift(id: id, date: "2026-10-03", employer: "Cafe", segments: [WorkSegment(startMinute: 600, endMinute: 900, hourlyWage: 1200)], transport: transport)
    }
    func testSwiftSDKConcurrentDevicesRetainBothAdditions() async throws {
        let (a,b,uid) = try await clients(); let empty = AccountSnapshot()
        var first = empty; first.shifts = [shift("a")]; var second = empty; second.shifts = [shift("b")]
        let batchA = try SyncBatch(from: empty, to: first), batchB = try SyncBatch(from: empty, to: second)
        async let x = a.commit(uid: uid, batch: batchA, allowCreate: true)
        async let y = b.commit(uid: uid, batch: batchB, allowCreate: true)
        _ = try await (x,y)
        let state = try await a.readForDeletion(uid: uid)
        XCTAssertEqual(Set(state.snapshot.shifts.map(\.id)), ["a", "b"]); XCTAssertEqual(state.revision, 2)
    }
    func testSwiftSDKSameRecordConflictAndReceiptRetry() async throws {
        let (a,b,uid) = try await clients(); var original = AccountSnapshot(); original.shifts = [shift("one")]
        _ = try await a.commit(uid: uid, batch: SyncBatch(from: AccountSnapshot(), to: original), allowCreate: true)
        var localA = original; localA.shifts[0].transport = 100
        var localB = original; localB.shifts[0].transport = 200
        let editA = try SyncBatch(from: original, to: localA), editB = try SyncBatch(from: original, to: localB)
        _ = try await a.commit(uid: uid, batch: editA, allowCreate: false)
        guard case .conflict(let current) = try await b.commit(uid: uid, batch: editB, allowCreate: false) else {
            return XCTFail("Same-record edits must be held for a user choice")
        }
        XCTAssertEqual(current.snapshot.shifts[0].transport, 100)
        _ = try await b.commit(uid: uid, batch: editB.rebased(on: current.snapshot), allowCreate: false)
        guard case .applied(let replay) = try await a.commit(uid: uid, batch: editA, allowCreate: false) else { return XCTFail("Receipt not recognized") }
        XCTAssertEqual(replay.snapshot.shifts[0].transport, 200)
    }
    func testSwiftSDKDeletionMarkerBlocksStaleWriteAndMatchingRollbackRestores() async throws {
        let (a,b,uid) = try await clients(); var original = AccountSnapshot(); original.shifts = [shift("one")]
        _ = try await a.commit(uid: uid, batch: SyncBatch(from: AccountSnapshot(), to: original), allowCreate: true)
        let backup = AccountDeletionBackup(state: try await a.readForDeletion(uid: uid))
        try await a.markDeleted(uid: uid, backup: backup)
        var stale = original; stale.shifts.append(shift("stale"))
        do {
            _ = try await b.commit(uid: uid, batch: SyncBatch(from: original, to: stale), allowCreate: false)
            XCTFail("A deleted account must not accept old cached records")
        } catch {
            XCTAssertEqual((error as NSError).domain, AccountSyncError.errorDomain)
            XCTAssertEqual((error as NSError).code, AccountSyncError.accountDeleted.errorCode)
        }
        let deletedState = try await a.readForDeletion(uid: uid)
        XCTAssertTrue(deletedState.snapshot.shifts.isEmpty)
        let restored = try await a.rollbackDeletion(uid: uid, backup: backup)
        XCTAssertFalse(restored.deleted); XCTAssertEqual(restored.snapshot, original)
    }
    func testDeletedAuthAccountIsRecognizedBeforeClearingAnotherDevicesCache() async throws {
        let (_,_,uid) = try await clients()
        let pair = try XCTUnwrap(users[uid])
        try await pair.0.delete()
        do {
            try await pair.1.reload()
            XCTFail("The deleted Auth account must not remain a valid session")
        } catch let error as NSError {
            XCTAssertTrue(AuthManager.isDeletedAuthSession(error))
        }
    }

}
