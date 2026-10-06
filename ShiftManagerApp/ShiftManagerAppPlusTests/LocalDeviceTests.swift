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
#endif
