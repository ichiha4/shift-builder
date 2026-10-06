import Foundation

/// The legacy cloud document's six record arrays. Sync metadata lives beside these fields.
public struct AccountSnapshot: Codable, Equatable, Sendable {
    public var shifts: [Shift] = []
    public var expenses: [Expense] = []
    public var employerProfiles: [EmployerProfile] = []
    public var deductions: [Deduction] = []
    public var actualPayments: [ActualPayment] = []
    public var recurringExpenses: [RecurringExpense] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case shifts, expenses, employerProfiles, deductions, actualPayments, recurringExpenses
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // The original four fields are required: malformed/future documents must never
        // be interpreted as an empty account. The last two were added to older documents.
        shifts = try c.decode([Shift].self, forKey: .shifts)
        expenses = try c.decode([Expense].self, forKey: .expenses)
        employerProfiles = try c.decode([EmployerProfile].self, forKey: .employerProfiles)
        deductions = try c.decode([Deduction].self, forKey: .deductions)
        actualPayments = try c.decodeIfPresent([ActualPayment].self, forKey: .actualPayments) ?? []
        recurringExpenses = try c.decodeIfPresent([RecurringExpense].self, forKey: .recurringExpenses) ?? []
    }

    public func records(in collection: SyncCollection) throws -> [SyncRecord] {
        switch collection {
        case .shifts: return try Self.encode(shifts)
        case .expenses: return try Self.encode(expenses)
        case .employerProfiles: return try Self.encode(employerProfiles)
        case .deductions: return try Self.encode(deductions)
        case .actualPayments: return try Self.encode(actualPayments)
        case .recurringExpenses: return try Self.encode(recurringExpenses)
        }
    }

    private static func encode<T: Encodable & Identifiable>(_ values: [T]) throws -> [SyncRecord] where T.ID == String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var ids = Set<String>()
        return try values.map {
            guard ids.insert($0.id).inserted else { throw AccountSyncError.duplicateRecord }
            return SyncRecord(id: $0.id, data: try encoder.encode($0))
        }
    }

    fileprivate mutating func setRecords(_ records: [SyncRecord], in collection: SyncCollection) throws {
        let decoder = JSONDecoder()
        switch collection {
        case .shifts: shifts = try records.map { try decoder.decode(Shift.self, from: $0.data) }
        case .expenses: expenses = try records.map { try decoder.decode(Expense.self, from: $0.data) }
        case .employerProfiles: employerProfiles = try records.map { try decoder.decode(EmployerProfile.self, from: $0.data) }
        case .deductions: deductions = try records.map { try decoder.decode(Deduction.self, from: $0.data) }
        case .actualPayments: actualPayments = try records.map { try decoder.decode(ActualPayment.self, from: $0.data) }
        case .recurringExpenses: recurringExpenses = try records.map { try decoder.decode(RecurringExpense.self, from: $0.data) }
        }
    }
}

public enum AccountSyncError: Error, CustomNSError {
    case duplicateRecord, accountDeleted, unsupportedSchema
    public static var errorDomain: String { "ShiftBuilder.AccountSync" }
    public var errorCode: Int {
        switch self { case .duplicateRecord: return 1; case .accountDeleted: return 2; case .unsupportedSchema: return 3 }
    }
}

public enum SyncCollection: String, Codable, CaseIterable, Sendable {
    case shifts, expenses, employerProfiles, deductions, actualPayments, recurringExpenses
}

public struct SyncRecord: Codable, Equatable, Sendable {
    public var id: String
    public var data: Data
}

public struct SyncChange: Codable, Equatable, Sendable {
    public var collection: SyncCollection
    public var id: String
    public var before: SyncRecord?
    public var after: SyncRecord?
}

/// One user action, including linked edits (e.g. renaming an employer and its shifts).
/// All changes in this batch are committed together, or held for an explicit conflict choice.
public struct SyncBatch: Codable, Equatable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var changes: [SyncChange]

    public init(from before: AccountSnapshot, to after: AccountSnapshot) throws {
        changes = []
        for collection in SyncCollection.allCases {
            let old = try before.records(in: collection)
            let new = try after.records(in: collection)
            let oldMap = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
            let newMap = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
            for id in Set(oldMap.keys).union(newMap.keys).sorted() where oldMap[id] != newMap[id] {
                changes.append(SyncChange(collection: collection, id: id, before: oldMap[id], after: newMap[id]))
            }
        }
    }

    public func conflicts(with remote: AccountSnapshot) throws -> [SyncChange] {
        try changes.filter { change in
            let current = try remote.records(in: change.collection).first { $0.id == change.id }
            return current != change.before && current != change.after
        }
    }

    /// Overlay only this action's records. Unrelated records, and unrelated deletions,
    /// from other devices survive. The caller checks conflicts inside its transaction.
    public func applying(to remote: AccountSnapshot) throws -> AccountSnapshot {
        var result = remote
        for collection in SyncCollection.allCases {
            let edits = changes.filter { $0.collection == collection }
            guard !edits.isEmpty else { continue }
            var records = try result.records(in: collection)
            for edit in edits {
                if let index = records.firstIndex(where: { $0.id == edit.id }) {
                    if let after = edit.after { records[index] = after }
                    else { records.remove(at: index) }
                } else if let after = edit.after { records.append(after) }
            }
            try result.setRecords(records, in: collection)
        }
        return result
    }

    public func rebased(on remote: AccountSnapshot) throws -> SyncBatch {
        var result = self
        result.id = UUID().uuidString
        for index in result.changes.indices {
            let change = result.changes[index]
            result.changes[index].before = try remote.records(in: change.collection).first { $0.id == change.id }
        }
        return result
    }
}

/// Written atomically as one local blob before uploading. Pending work survives relaunch,
/// network failures and a transaction whose acknowledgement never reached the device.
public struct SyncJournal: Codable, Equatable, Sendable {
    public var confirmed: AccountSnapshot
    public var revision: Int = 0
    public var serverDocumentKnown = false
    public var pending: [SyncBatch] = []

    public init(snapshot: AccountSnapshot = AccountSnapshot()) { confirmed = snapshot }

    public func workingSnapshot() throws -> AccountSnapshot {
        try pending.reduce(confirmed) { try $1.applying(to: $0) }
    }

    public mutating func recordEdit(to snapshot: AccountSnapshot) throws {
        let batch = try SyncBatch(from: workingSnapshot(), to: snapshot)
        if !batch.changes.isEmpty { pending.append(batch) }
    }

    public mutating func observe(_ snapshot: AccountSnapshot, revision: Int) {
        guard revision >= self.revision else { return }
        confirmed = snapshot
        self.revision = revision
        serverDocumentKnown = true
    }

    public mutating func acknowledge(id: String, snapshot: AccountSnapshot, revision: Int) {
        pending.removeAll { $0.id == id }
        observe(snapshot, revision: revision)
    }

    public mutating func keepRemoteForFirstBatch() { if !pending.isEmpty { pending.removeFirst() } }

    public mutating func keepLocalForFirstBatch() throws {
        guard let first = pending.first else { return }
        pending[0] = try first.rebased(on: confirmed)
    }
}
