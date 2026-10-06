#if LOCAL_DEVICE_TESTING
#if !DEBUG
#error("Local device testing must never be enabled in a release build.")
#endif
import Foundation

/// Uses the same journal path as the app, but persists its second copy only on this device.
/// It cannot authenticate, upload data or connect to Firestore.
@MainActor
final class LocalDeviceTestTransport: CloudSyncTransport {
    static let accountID = "local-device-test"
    private static let storageKey = "shiftbuilder.localDeviceTest.snapshot.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func read(uid: String) throws -> CloudAccountState {
        guard uid == Self.accountID else { throw CloudSyncFailure.documentRemoved }
        guard let data = defaults.data(forKey: Self.storageKey) else {
            return CloudAccountState(snapshot: AccountSnapshot(), exists: false)
        }
        return try JSONDecoder().decode(CloudAccountState.self, from: data)
    }

    func observe(uid: String, receive: @escaping (Result<CloudObservation, Error>) -> Void) -> () -> Void {
        receive(Result { CloudObservation(state: try read(uid: uid), fromCache: false) })
        return {}
    }

    func commit(uid: String, batch: SyncBatch, allowCreate: Bool) async throws -> CloudCommit {
        var state = try read(uid: uid)
        guard state.exists || allowCreate else { throw CloudSyncFailure.documentRemoved }
        guard !state.deleted else { throw AccountSyncError.accountDeleted }
        if state.receipts.contains(batch.id) { return .applied(state) }
        guard try batch.conflicts(with: state.snapshot).isEmpty else { return .conflict(state) }
        state.snapshot = try batch.applying(to: state.snapshot)
        state.revision += 1
        state.exists = true
        state.receipts = Array((state.receipts + [batch.id]).suffix(200))
        defaults.set(try JSONEncoder().encode(state), forKey: Self.storageKey)
        return .applied(state)
    }

    // Account controls are hidden in this build. Refuse accidental deletion requests.
    func readForDeletion(uid: String) async throws -> CloudAccountState { throw CloudSyncFailure.documentRemoved }
    func markDeleted(uid: String, backup: AccountDeletionBackup) async throws { throw CloudSyncFailure.documentRemoved }
    func rollbackDeletion(uid: String, backup: AccountDeletionBackup) async throws -> CloudAccountState {
        throw CloudSyncFailure.documentRemoved
    }
}
#endif
