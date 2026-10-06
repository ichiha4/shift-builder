import Foundation
import FirebaseFirestore

struct CloudAccountState: Codable, Equatable, Sendable {
    var snapshot: AccountSnapshot
    var revision: Int = 0
    var receipts: [String] = []
    var exists = true
    var deleted = false
    var deletionToken: String?
}

struct CloudObservation: Sendable {
    var state: CloudAccountState
    var fromCache: Bool
    var hasPendingWrites = false
}

enum CloudCommit: Sendable {
    case applied(CloudAccountState)
    case conflict(CloudAccountState)
}

struct AccountDeletionBackup: Codable, Sendable {
    var state: CloudAccountState
    var token = UUID().uuidString
}

enum CloudSyncFailure: Error, CustomNSError {
    case deletionChanged, documentRemoved
    static var errorDomain: String { "ShiftBuilder.CloudSync" }
    var errorCode: Int { self == .deletionChanged ? 1 : 2 }
}

@MainActor
protocol CloudSyncTransport {
    func observe(uid: String, receive: @escaping (Result<CloudObservation, Error>) -> Void) -> () -> Void
    func commit(uid: String, batch: SyncBatch, allowCreate: Bool) async throws -> CloudCommit
    func readForDeletion(uid: String) async throws -> CloudAccountState
    func markDeleted(uid: String, backup: AccountDeletionBackup) async throws
    func rollbackDeletion(uid: String, backup: AccountDeletionBackup) async throws -> CloudAccountState
}

/// Transactions read the current account, apply only the edited IDs and retain other fields.
/// Receipt IDs make retries safe when an app closes after the server committed a write.
@MainActor
final class FirestoreSyncTransport: CloudSyncTransport {
    private let db: Firestore
    init(db: Firestore? = nil) { self.db = db ?? Firestore.firestore() }

    nonisolated private static func decode(_ document: DocumentSnapshot) throws -> CloudAccountState {
        guard document.exists else { return CloudAccountState(snapshot: AccountSnapshot(), exists: false) }
        let fields = document.data() ?? [:]
        guard (fields["_syncSchema"] as? Int ?? 0) <= 1 else { throw AccountSyncError.unsupportedSchema }
        let snapshot = try document.data(as: AccountSnapshot.self)
        for collection in SyncCollection.allCases { _ = try snapshot.records(in: collection) }
        return CloudAccountState(
            snapshot: snapshot,
            revision: fields["_syncRevision"] as? Int ?? 0,
            receipts: fields["_recentMutations"] as? [String] ?? [],
            deleted: fields["_accountDeleted"] as? Bool ?? false,
            deletionToken: fields["_deletionToken"] as? String
        )
    }

    func observe(uid: String, receive: @escaping (Result<CloudObservation, Error>) -> Void) -> () -> Void {
        let listener = db.collection("users").document(uid).addSnapshotListener(includeMetadataChanges: true) { document, error in
            let result: Result<CloudObservation, Error>
            if let document {
                result = Result { CloudObservation(state: try Self.decode(document), fromCache: document.metadata.isFromCache, hasPendingWrites: document.metadata.hasPendingWrites) }
            } else { result = .failure(error ?? CloudSyncFailure.documentRemoved) }
            Task { @MainActor in receive(result) }
        }
        return { listener.remove() }
    }

    func commit(uid: String, batch: SyncBatch, allowCreate: Bool) async throws -> CloudCommit {
        let reference = db.collection("users").document(uid)
        let result = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let current = try Self.decode(transaction.getDocument(reference))
                guard !current.deleted else { throw AccountSyncError.accountDeleted }
                guard current.exists || allowCreate else { throw CloudSyncFailure.documentRemoved }
                if current.receipts.contains(batch.id) { return CloudCommit.applied(current) }
                guard try batch.conflicts(with: current.snapshot).isEmpty else { return CloudCommit.conflict(current) }
                var next = current
                next.snapshot = try batch.applying(to: current.snapshot)
                next.revision += 1
                next.exists = true
                next.receipts = Array((current.receipts + [batch.id]).suffix(200))
                var fields = try Firestore.Encoder().encode(next.snapshot)
                fields["_syncSchema"] = 1
                fields["_syncRevision"] = FieldValue.increment(Int64(1))
                fields["_recentMutations"] = next.receipts
                fields["_accountDeleted"] = false
                transaction.setData(fields, forDocument: reference, merge: true)
                return CloudCommit.applied(next)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil
            }
        }
        guard let result = result as? CloudCommit else { throw AccountSyncError.unsupportedSchema }
        return result
    }

    func readForDeletion(uid: String) async throws -> CloudAccountState {
        try Self.decode(await db.collection("users").document(uid).getDocument(source: .server))
    }

    func markDeleted(uid: String, backup: AccountDeletionBackup) async throws {
        let reference = db.collection("users").document(uid)
        _ = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let current = try Self.decode(transaction.getDocument(reference))
                // The latest cloud copy was saved locally BEFORE entering this transaction.
                // If another device changed it, take a fresh backup and retry, never clear it.
                guard current == backup.state, !current.deleted else { throw CloudSyncFailure.deletionChanged }
                var fields = try Firestore.Encoder().encode(AccountSnapshot())
                fields["_syncSchema"] = 1
                fields["_syncRevision"] = FieldValue.increment(Int64(1))
                fields["_recentMutations"] = [String]()
                fields["_accountDeleted"] = true
                fields["_deletionToken"] = backup.token
                transaction.setData(fields, forDocument: reference, merge: true)
                return true
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
    }

    func rollbackDeletion(uid: String, backup: AccountDeletionBackup) async throws -> CloudAccountState {
        let reference = db.collection("users").document(uid)
        let result = try await db.runTransaction { transaction, errorPointer -> Any? in
            do {
                let current = try Self.decode(transaction.getDocument(reference))
                guard current.deleted else { return current }
                guard current.deletionToken == backup.token else { throw AccountSyncError.accountDeleted }
                var restored = backup.state
                restored.revision = current.revision + 1
                restored.exists = true
                var fields = try Firestore.Encoder().encode(restored.snapshot)
                fields["_syncSchema"] = 1
                fields["_syncRevision"] = FieldValue.increment(Int64(1))
                fields["_recentMutations"] = restored.receipts
                fields["_accountDeleted"] = false
                fields["_deletionToken"] = backup.token
                transaction.setData(fields, forDocument: reference, merge: true)
                return restored
            } catch { errorPointer?.pointee = error as NSError; return nil }
        }
        guard let result = result as? CloudAccountState else { throw AccountSyncError.unsupportedSchema }
        return result
    }
}
