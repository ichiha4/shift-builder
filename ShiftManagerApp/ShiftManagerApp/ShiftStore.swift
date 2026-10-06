import Foundation
import Combine

/// Persists a per-account local journal and syncs record-level changes in Firestore
/// transactions. Pending edits survive incoming snapshots, offline work and relaunch.
@MainActor
final class ShiftStore: ObservableObject {
    @Published private(set) var shifts: [Shift] = [] {
        didSet { classificationsCache = nil }
    }
    @Published private(set) var expenses: [Expense] = []
    @Published private(set) var employerProfiles: [EmployerProfile] = []
    @Published private(set) var deductions: [Deduction] = []
    @Published private(set) var actualPayments: [ActualPayment] = []
    @Published private(set) var recurringExpenses: [RecurringExpense] = []

    private enum Key {
        static let shifts = "shiftmgr.shifts"
        static let expenses = "shiftmgr.expenses"
        static let employerProfiles = "shiftmgr.employerProfiles"
        static let deductions = "shiftmgr.deductions"
        static let actualPayments = "shiftmgr.actualPayments"
        static let recurringExpenses = "shiftmgr.recurringExpenses"
        /// The uid whose data the local cache holds. See `attachUser`.
        static let cacheOwner = "shiftmgr.cacheOwnerUID"
        static let journal = "shiftmgr.syncJournal.v1"
        static let deletionBackup = "shiftmgr.deletionBackup.v1"
        static let legacyRecovery = "shiftmgr.legacyRecovery.v1"
        static let allData = [shifts, expenses, employerProfiles, deductions, actualPayments, recurringExpenses, journal, deletionBackup, legacyRecovery]
    }

    private let defaults: UserDefaults
    private let transport: any CloudSyncTransport
    private let remindersEnabled: Bool
    private var stopObserving: (() -> Void)?
    private var uid: String?
    private var generation = UUID()
    private var journal = SyncJournal()
    private var invalidJournal = false
    private var cloudSyncSuspended = false
    private var flushRunning = false
    private var retryTask: Task<Void, Never>?
    @Published private(set) var cloudDataReady = false
    @Published private(set) var cloudReadFailed = false
    @Published private(set) var pendingSyncCount = 0
    @Published private(set) var syncWriteFailed = false
    @Published private(set) var hasSyncConflict = false
    @Published private(set) var remoteDeletionPending = false
    var onLocalDataWiped: (() -> Void)?
    var onAccountDeleted: (() -> Void)?

    init(defaults: UserDefaults = .standard, transport: (any CloudSyncTransport)? = nil,
         remindersEnabled: Bool = true) {
        self.defaults = defaults
        #if LOCAL_DEVICE_TESTING
        self.transport = transport ?? LocalDeviceTestTransport(defaults: defaults)
        #else
        self.transport = transport ?? FirestoreSyncTransport()
        #endif
        self.remindersEnabled = remindersEnabled
        shifts = Self.decode([Shift].self, key: Key.shifts, defaults: defaults) ?? []
        expenses = Self.decode([Expense].self, key: Key.expenses, defaults: defaults) ?? []
        employerProfiles = Self.decode([EmployerProfile].self, key: Key.employerProfiles, defaults: defaults) ?? []
        deductions = Self.decode([Deduction].self, key: Key.deductions, defaults: defaults) ?? []
        actualPayments = Self.decode([ActualPayment].self, key: Key.actualPayments, defaults: defaults) ?? []
        recurringExpenses = Self.decode([RecurringExpense].self, key: Key.recurringExpenses, defaults: defaults) ?? []
        if let saved = defaults.data(forKey: Key.journal) {
            if let decoded = try? JSONDecoder().decode(SyncJournal.self, from: saved),
               let working = try? decoded.workingSnapshot() {
                journal = decoded
                apply(working)
            } else { invalidJournal = true }
        } else { journal = SyncJournal(snapshot: currentSnapshot) }
        pendingSyncCount = journal.pending.count
        // Recurring entries are generated only after the account attaches. Startup must not
        // modify an unknown account's cache or create work before its initial cloud read.
    }

    private var currentSnapshot: AccountSnapshot {
        var result = AccountSnapshot()
        result.shifts = shifts; result.expenses = expenses; result.employerProfiles = employerProfiles
        result.deductions = deductions; result.actualPayments = actualPayments; result.recurringExpenses = recurringExpenses
        return result
    }

    private func apply(_ snapshot: AccountSnapshot) {
        shifts = snapshot.shifts; expenses = snapshot.expenses; employerProfiles = snapshot.employerProfiles
        deductions = snapshot.deductions; actualPayments = snapshot.actualPayments; recurringExpenses = snapshot.recurringExpenses
    }

    private func saveJournal() throws {
        defaults.set(try JSONEncoder().encode(journal), forKey: Key.journal)
        pendingSyncCount = journal.pending.count
    }

    private func applyJournal() throws {
        apply(try journal.workingSnapshot())
        persistLocalOnly()
        if remindersEnabled {
            // Cancel deleted/changed reminders as well as scheduling incoming records.
            NotificationScheduler.cancelPendingForSync()
            for profile in employerProfiles { NotificationScheduler.reschedulePaydayReminders(for: profile) }
            let today = DateUtils.todayYMD()
            for shift in shifts where shift.date >= today { NotificationScheduler.scheduleReminder(for: shift) }
        }
    }

    func attachUser(uid: String) {
        guard self.uid != uid else { return }
        detachUser(clearLocalState: false)
        if let owner = defaults.string(forKey: Key.cacheOwner), owner != uid { forgetLocalAccountData() }
        defaults.set(uid, forKey: Key.cacheOwner)
        self.uid = uid
        guard !invalidJournal else { cloudReadFailed = true; return }
        // An authenticated account with a valid journal can keep working offline. A new
        // device / pre-journal legacy cache waits for a server-confirmed initial read.
        cloudDataReady = journal.serverDocumentKnown && !hasInterruptedAccountDeletion
        let token = generation
        stopObserving = transport.observe(uid: uid) { [weak self] result in
            guard let self, self.uid == uid, self.generation == token else { return }
            guard !self.cloudSyncSuspended || self.remoteDeletionPending else { return }
            do {
                let observation = try result.get()
                guard !observation.hasPendingWrites else { return }
                let remote = observation.state
                if remote.deleted {
                    self.cloudDataReady = false
                    self.cloudReadFailed = true
                    if !observation.fromCache && !self.hasInterruptedAccountDeletion {
                        if !self.remoteDeletionPending {
                            self.remoteDeletionPending = true
                            self.cloudSyncSuspended = true
                            self.onAccountDeleted?()
                        }
                    }
                    return
                }
                if self.remoteDeletionPending {
                    self.remoteDeletionPending = false
                    self.cloudSyncSuspended = false
                }
                if !remote.exists {
                    guard !observation.fromCache else { return }
                    guard !self.journal.serverDocumentKnown else { throw CloudSyncFailure.documentRemoved }
                    // First migration is a set of additions based on an empty account. If
                    // another device creates it concurrently, unrelated records are retained.
                    if self.journal.confirmed != AccountSnapshot() {
                        let local = try self.journal.workingSnapshot()
                        self.journal = SyncJournal()
                        try self.journal.recordEdit(to: local)
                    }
                } else {
                    // Keep an untouched legacy cache for recovery rather than silently
                    // destroying unsent pre-upgrade history or resurrecting remote deletions.
                    if self.defaults.data(forKey: Key.journal) == nil && self.journal.confirmed != remote.snapshot {
                        self.defaults.set(try JSONEncoder().encode(self.journal.confirmed), forKey: Key.legacyRecovery)
                    }
                    self.journal.observe(remote.snapshot, revision: remote.revision)
                }
                self.cloudDataReady = !self.hasInterruptedAccountDeletion
                self.cloudReadFailed = false
                try self.saveJournal()
                try self.applyJournal()
                self.generateDueRecurringExpenses()
                self.retryCloudSync()
            } catch {
                self.cloudReadFailed = true
                if error is DecodingError || (error as NSError).domain == AccountSyncError.errorDomain || (error as NSError).domain == CloudSyncFailure.errorDomain {
                    self.cloudDataReady = false
                }
                // A listener/network failure never discards an existing valid local journal.
            }
        }
    }

    func isAttached(to uid: String) -> Bool { self.uid == uid && defaults.string(forKey: Key.cacheOwner) == uid }

    func detachUser(clearLocalState: Bool = true) {
        stopObserving?(); stopObserving = nil
        retryTask?.cancel(); retryTask = nil
        uid = nil; generation = UUID(); flushRunning = false
        cloudDataReady = false; cloudReadFailed = false; cloudSyncSuspended = false
        hasSyncConflict = false; syncWriteFailed = false; remoteDeletionPending = false
        if clearLocalState { apply(AccountSnapshot()) }
    }

    func wipeLocalData() {
        detachUser()
        forgetLocalAccountData()
    }

    private func forgetLocalAccountData() {
        apply(AccountSnapshot())
        journal = SyncJournal(); invalidJournal = false; pendingSyncCount = 0
        for key in Key.allData + [Key.cacheOwner, IncomeWallSettings.dependencyKey, IncomeWallSettings.birthDateKey,
                                  "shiftmgr.dismissedShiftFormats"] { defaults.removeObject(forKey: key) }
        if remindersEnabled { NotificationScheduler.cancelAll() }
        onLocalDataWiped?()
    }

    func retryCloudSync() {
        guard let uid, cloudDataReady, !cloudSyncSuspended, !hasSyncConflict, !flushRunning,
              !journal.pending.isEmpty else { return }
        retryTask?.cancel(); retryTask = nil
        flushRunning = true
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.flushRunning = false } }
            do {
                while self.generation == token, self.uid == uid, !self.cloudSyncSuspended,
                      let batch = self.journal.pending.first {
                    let result = try await self.transport.commit(uid: uid, batch: batch,
                                                                 allowCreate: !self.journal.serverDocumentKnown)
                    guard self.generation == token, self.uid == uid, !self.cloudSyncSuspended else { return }
                    switch result {
                    case .applied(let state):
                        self.journal.acknowledge(id: batch.id, snapshot: state.snapshot, revision: state.revision)
                        self.syncWriteFailed = false
                    case .conflict(let state):
                        self.journal.observe(state.snapshot, revision: state.revision)
                        self.hasSyncConflict = true
                    }
                    try self.saveJournal()
                    try self.applyJournal()
                    if self.hasSyncConflict { return }
                }
            } catch {
                guard self.generation == token else { return }
                self.syncWriteFailed = true
                if (error as NSError).domain == AccountSyncError.errorDomain || (error as NSError).domain == CloudSyncFailure.errorDomain {
                    // A rejected write may arrive after a deletion marker has already been
                    // rolled back. Re-read under a new generation instead of locking a live
                    // account permanently based on that older transaction's response.
                    if self.cloudDataReady, !self.remoteDeletionPending, !self.cloudSyncSuspended,
                       !self.hasInterruptedAccountDeletion {
                        self.detachUser(clearLocalState: false)
                        self.attachUser(uid: uid)
                    } else {
                        self.cloudDataReady = false; self.cloudReadFailed = true
                    }
                    return
                }
                self.retryTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled, let self, self.generation == token else { return }
                    self.retryCloudSync()
                }
            }
        }
    }

    var conflictChanges: [SyncChange] {
        guard hasSyncConflict, let first = journal.pending.first else { return [] }
        return first.changes
    }

    func remoteRecord(for change: SyncChange) -> SyncRecord? {
        (try? journal.confirmed.records(in: change.collection))?.first { $0.id == change.id }
    }

    func resolveSyncConflict(keepLocal: Bool) {
        guard hasSyncConflict else { return }
        do {
            if keepLocal { try journal.keepLocalForFirstBatch() }
            else { journal.keepRemoteForFirstBatch() }
            try saveJournal(); try applyJournal()
            hasSyncConflict = false
            retryCloudSync()
        } catch { syncWriteFailed = true }
    }

    var legacyRecoveryData: Data? { defaults.data(forKey: Key.legacyRecovery) }

    var hasInterruptedAccountDeletion: Bool { defaults.data(forKey: Key.deletionBackup) != nil }

    /// Read the latest server copy and persist its backup BEFORE clearing cloud records.
    /// A concurrent change retries the read/backup; no stale local copy is used for recovery.
    func prepareAccountDeletion() async throws {
        guard let uid else { throw CloudSyncFailure.documentRemoved }
        let token = generation
        cloudSyncSuspended = true; cloudDataReady = false
        stopObserving?(); stopObserving = nil
        retryTask?.cancel()
        for _ in 0..<5 {
            let state = try await transport.readForDeletion(uid: uid)
            guard self.uid == uid, generation == token else { throw CloudSyncFailure.documentRemoved }
            guard !state.deleted else { throw AccountSyncError.accountDeleted }
            let backup = AccountDeletionBackup(state: state)
            defaults.set(try JSONEncoder().encode(backup), forKey: Key.deletionBackup)
            do {
                try await transport.markDeleted(uid: uid, backup: backup)
                return
            } catch {
                let failure = error as NSError
                if failure.domain == CloudSyncFailure.errorDomain && failure.code == CloudSyncFailure.deletionChanged.errorCode { continue }
                throw error
            }
        }
        throw CloudSyncFailure.deletionChanged
    }

    /// Call only after Firebase has confirmed this Auth account still exists. Also used
    /// after a failed deletion. The matching marker is required before restoring anything.
    func recoverAccountDataAfterFailedDeletion() async throws {
        guard let uid else { return }
        if let data = defaults.data(forKey: Key.deletionBackup) {
            let backup = try JSONDecoder().decode(AccountDeletionBackup.self, from: data)
            let state = try await transport.rollbackDeletion(uid: uid, backup: backup)
            journal.observe(state.snapshot, revision: state.revision)
            try saveJournal()
            defaults.removeObject(forKey: Key.deletionBackup)
        }
        self.uid = nil
        attachUser(uid: uid)
    }

    /// Every shift, grouped and classified once — pass this into `PayCalculation.pay(for:)`
    /// for any shift so overtime is judged with the full picture (not just the visible month).
    var classifications: [String: [String: ShiftClassification]] {
        if let classificationsCache { return classificationsCache }
        let built = PayCalculation.buildEmployerClassifications(shifts)
        classificationsCache = built
        return built
    }
    /// Classifying every shift is the expensive step behind every pay figure, and views ask for it
    /// on each render; it only changes when `shifts` does (cleared in its `didSet`).
    private var classificationsCache: [String: [String: ShiftClassification]]?

    // MARK: - Shifts

    func addShift(_ shift: Shift) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        shifts.append(shift)
        persist(shifts, key: Key.shifts)
    }

    /// Adds one validated selection as one journal edit. A failed row leaves all records intact.
    @discardableResult
    func importShiftCandidates(_ candidates: [ShiftImportCandidate], profile: EmployerProfile) throws -> ShiftImportPlan {
        guard cloudDataReady, !cloudSyncSuspended, !hasSyncConflict,
              !invalidJournal, !remoteDeletionPending, !hasInterruptedAccountDeletion else {
            throw ShiftImportError.storeUnavailable
        }
        let plan = try ShiftImportPlanner.plan(candidates: candidates, profile: profile, existing: shifts)
        guard !plan.shifts.isEmpty else { return plan }
        var proposed = currentSnapshot
        proposed.shifts.append(contentsOf: plan.shifts)
        var updatedJournal = journal
        try updatedJournal.recordEdit(to: proposed)
        let encoded = try JSONEncoder().encode(updatedJournal)
        defaults.set(encoded, forKey: Key.journal)
        journal = updatedJournal
        apply(proposed)
        pendingSyncCount = journal.pending.count
        persistLocalOnly()
        retryCloudSync()
        return plan
    }

    func updateShift(_ shift: Shift) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        guard let idx = shifts.firstIndex(where: { $0.id == shift.id }) else { return }
        shifts[idx] = shift
        persist(shifts, key: Key.shifts)
    }

    func deleteShift(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        shifts.removeAll { $0.id == id }
        persist(shifts, key: Key.shifts)
    }

    // MARK: - Employer profiles

    /// Upsert: matches an existing profile by id first (so editing and renaming one from the
    /// management screen replaces it in place), falling back to a name match (so shifts whose
    /// employer name happens to match an existing profile still merge into it, as in the web
    /// version) before appending a genuinely new profile.
    func saveEmployerProfile(_ profile: EmployerProfile) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        if let idx = employerProfiles.firstIndex(where: { $0.id == profile.id }) {
            let oldName = employerProfiles[idx].name
            if oldName != profile.name {
                // Names are the current relationship key: keep all linked history together.
                for i in shifts.indices where shifts[i].employer == oldName { shifts[i].employer = profile.name }
                for i in actualPayments.indices where actualPayments[i].employer == oldName { actualPayments[i].employer = profile.name }
                persistLocalOnly()
            }
            employerProfiles[idx] = profile
        } else if let idx = employerProfiles.firstIndex(where: { $0.name == profile.name }) {
            var updated = profile
            updated.id = employerProfiles[idx].id
            employerProfiles[idx] = updated
        } else {
            employerProfiles.append(profile)
        }
        persist(employerProfiles, key: Key.employerProfiles)
        if remindersEnabled { NotificationScheduler.reschedulePaydayReminders(for: profile) }
    }

    func deleteEmployerProfile(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        employerProfiles.removeAll { $0.id == id }
        persist(employerProfiles, key: Key.employerProfiles)
    }

    // MARK: - Expenses

    func addExpense(_ expense: Expense) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        expenses.append(expense)
        persist(expenses, key: Key.expenses)
    }

    func deleteExpense(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        expenses.removeAll { $0.id == id }
        persist(expenses, key: Key.expenses)
    }

    // MARK: - Recurring expenses (subscriptions, rent, etc.)

    func saveRecurringExpense(_ item: RecurringExpense) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        if let idx = recurringExpenses.firstIndex(where: { $0.id == item.id }) {
            recurringExpenses[idx] = item
        } else {
            recurringExpenses.append(item)
        }
        persist(recurringExpenses, key: Key.recurringExpenses)
        generateDueRecurringExpenses()
    }

    func deleteRecurringExpense(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        recurringExpenses.removeAll { $0.id == id }
        persist(recurringExpenses, key: Key.recurringExpenses)
    }

    /// Drops a matching `Expense` into the current month for every active recurring expense
    /// whose charge day has already been reached, exactly once per (item, month) — safe to call
    /// as often as needed (app launch, cloud sync, tab appearing) since it's a no-op once this
    /// month's charge already exists.
    func generateDueRecurringExpenses() {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        let today = DateUtils.todayYMD()
        guard let (y, m, d) = DateUtils.parseYMD(today) else { return }
        for item in recurringExpenses where item.isActive {
            let chargeDay = DateUtils.resolveDay(year: y, month: m, day: item.dayOfMonth)
            guard d >= chargeDay else { continue }
            let chargeDate = String(format: "%04d-%02d-%02d", y, m, chargeDay)
            let alreadyGenerated = expenses.contains {
                $0.recurringExpenseId == item.id && $0.date.hasPrefix(String(format: "%04d-%02d", y, m))
            }
            guard !alreadyGenerated else { continue }
            addExpense(Expense(id: "recurring:\(item.id):\(y)-\(m)", date: chargeDate, category: item.category, amount: item.amount, memo: item.memo.isEmpty ? item.name : item.memo, recurringExpenseId: item.id))
        }
    }

    // MARK: - Deductions

    func addOrReplaceDeduction(month: String, category: String, amount: Double, note: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        // Upsert by (month, category) — except "その他控除", where multiple free-form entries
        // make sense (two separate one-off deductions in the same month).
        if category != "その他控除", let idx = deductions.firstIndex(where: { $0.month == month && $0.category == category }) {
            deductions[idx].amount = amount
            deductions[idx].note = note
        } else {
            deductions.append(Deduction(id: category == "その他控除" ? UUID().uuidString : "deduction:" + Data((month + "\n" + category).utf8).base64EncodedString(), month: month, category: category, amount: amount, note: note))
        }
        persist(deductions, key: Key.deductions)
    }

    func deleteDeduction(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        deductions.removeAll { $0.id == id }
        persist(deductions, key: Key.deductions)
    }

    // MARK: - Actual payments (payday-banner "record what I actually got paid")

    /// Upsert by (employer, payDate) — recording the same payday twice corrects the figure
    /// rather than adding a duplicate entry.
    func recordActualPayment(employer: String, payDate: String, amount: Double) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        if let idx = actualPayments.firstIndex(where: { $0.employer == employer && $0.payDate == payDate }) {
            actualPayments[idx].amount = amount
        } else {
            actualPayments.append(ActualPayment(id: "payment:" + Data((employer + "\n" + payDate).utf8).base64EncodedString(), employer: employer, payDate: payDate, amount: amount))
        }
        persist(actualPayments, key: Key.actualPayments)
    }

    func deleteActualPayment(id: String) {
        guard cloudDataReady, !cloudSyncSuspended else { return }
        actualPayments.removeAll { $0.id == id }
        persist(actualPayments, key: Key.actualPayments)
    }

    // MARK: - Persistence

    private func persist<T: Encodable>(_ value: T, key: String) {
        do {
            try journal.recordEdit(to: currentSnapshot)
            try saveJournal()
            persistLocalOnly()
            retryCloudSync()
        } catch {
            // Refuse an invalid edit rather than erase a previously saved journal.
            if let previous = try? journal.workingSnapshot() { apply(previous) }
            syncWriteFailed = true
        }
    }

    /// Used only when applying an incoming Firestore snapshot — writes the local cache without
    /// re-triggering a push back to the cloud.
    private func persistLocalOnly() {
        for (value, key) in [(try? JSONEncoder().encode(shifts), Key.shifts),
                              (try? JSONEncoder().encode(expenses), Key.expenses),
                              (try? JSONEncoder().encode(employerProfiles), Key.employerProfiles),
                              (try? JSONEncoder().encode(deductions), Key.deductions),
                              (try? JSONEncoder().encode(actualPayments), Key.actualPayments),
                              (try? JSONEncoder().encode(recurringExpenses), Key.recurringExpenses)] {
            if let value { defaults.set(value, forKey: key) }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
