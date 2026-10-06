import SwiftUI
import UniformTypeIdentifiers

struct SyncStatusView: View {
    @EnvironmentObject var store: ShiftStore
    @State private var showConflict = false

    var body: some View {
        if store.hasSyncConflict || store.pendingSyncCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: store.hasSyncConflict ? "exclamationmark.triangle" : "icloud.and.arrow.up")
                Text(LocalizedStringKey(store.hasSyncConflict ? "別の端末と変更が重複しています" : "変更はこの端末に保存済みです。クラウドに同期しています。"))
                    .font(.caption)
                Spacer(minLength: 0)
                if store.hasSyncConflict {
                    Button("確認") { showConflict = true }
                } else if store.syncWriteFailed {
                    Button("再試行") { store.retryCloudSync() }
                } else { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.regularMaterial)
            .sheet(isPresented: $showConflict) {
                SyncConflictView().environmentObject(store)
            }
        }
    }
}

struct SyncConflictView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("同じ記録が別の端末でも変更されました。内容を確認して、今回の操作に使う変更を選んでください。関連する記録はまとめて反映されます。")
                }
                ForEach(Array(store.conflictChanges.enumerated()), id: \.offset) { _, change in
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("この端末の変更").font(.headline)
                            record(change.after, collection: change.collection)
                            Divider()
                            Text("クラウドの現在の記録").font(.headline)
                            record(store.remoteRecord(for: change), collection: change.collection)
                        }
                        .font(.subheadline).padding(.vertical, 4)
                    }
                }
                Section {
                    Button("この端末の変更を反映") { store.resolveSyncConflict(keepLocal: true); dismiss() }
                    Button("クラウドの記録を使う", role: .destructive) { store.resolveSyncConflict(keepLocal: false); dismiss() }
                    Text("「クラウドの記録を使う」を選ぶと、今回の操作によるこの端末の変更を取り消します。後に追加した操作は別に確認されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("変更の確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("後で確認") { dismiss() } }
        }
    }

    private func day(_ label: String, _ value: Int) -> some View {
        LabeledContent {
            if value == 0 { Text("末日") } else { Text(verbatim: value.formatted()) }
        } label: { Text(LocalizedStringKey(label)) }
    }

    @ViewBuilder private func record(_ record: SyncRecord?, collection: SyncCollection) -> some View {
        if let record {
            let decoder = JSONDecoder()
            switch collection {
            case .shifts:
                if let s = try? decoder.decode(Shift.self, from: record.data) {
                    Text(verbatim: "\(s.date) · \(s.employer)")
                    ForEach(Array(s.segments.enumerated()), id: \.offset) { _, segment in
                        Text(verbatim: "\(ClockUtils.formatClock(segment.startMinute))–\(ClockUtils.formatClock(segment.endMinute)) · ¥\(segment.hourlyWage.formatted())")
                    }
                    LabeledContent("休憩(分)", value: s.breakMinutes.formatted())
                    if let start = s.breakStartMinute { LabeledContent("休憩開始", value: ClockUtils.formatClock(start)) }
                    LabeledContent("交通費", value: s.transport.formatted())
                    LabeledContent("その他手当", value: s.otherAllowance.formatted())
                    LabeledContent("所定労働時間(分)", value: s.scheduledMinutes.formatted())
                    LabeledContent("深夜割増率", value: s.lateNightRate.formatted(.percent.precision(.fractionLength(0...3))))
                    LabeledContent("残業割増率", value: s.overtimeRate.formatted(.percent.precision(.fractionLength(0...3))))
                    LabeledContent("休日割増率", value: s.holidayRate.formatted(.percent.precision(.fractionLength(0...3))))
                    if s.isStatutoryHoliday { Text("法定休日") }
                }
            case .expenses:
                if let e = try? decoder.decode(Expense.self, from: record.data) {
                    Text(verbatim: "\(e.date) · \(e.category) · ¥\(e.amount.formatted())")
                    Text(verbatim: e.memo)
                }
            case .employerProfiles:
                if let p = try? decoder.decode(EmployerProfile.self, from: record.data) {
                    Text(verbatim: p.name)
                    LabeledContent("時給", value: p.defaultWage.formatted())
                    LabeledContent("所定労働時間", value: p.scheduledHours.formatted())
                    LabeledContent("交通費", value: p.defaultTransport.formatted())
                    LabeledContent("その他手当", value: p.otherAllowance.formatted())
                    day("締め日", p.closingDay)
                    LabeledContent {
                        if p.paydayMonthOffset == 0 { Text("当月") }
                        else if p.paydayMonthOffset == 1 { Text("翌月") }
                        else { Text("\(p.paydayMonthOffset)か月後") }
                    } label: { Text("支給月") }
                    day("支給日", p.paydayDay)
                    Text(LocalizedStringKey(p.paydayAdjustment == .none ? "休日調整なし" : p.paydayAdjustment == .beforeBusinessDay ? "前営業日に支給" : "翌営業日に支給"))
                    Text(verbatim: p.employmentType)
                    LabeledContent("深夜割増率", value: p.lateNightRate.formatted(.percent.precision(.fractionLength(0...3))))
                    LabeledContent("残業割増率", value: p.overtimeRate.formatted(.percent.precision(.fractionLength(0...3))))
                    LabeledContent("休日割増率", value: p.holidayRate.formatted(.percent.precision(.fractionLength(0...3))))
                    Text(verbatim: p.incomeTaxColumn.rawValue)
                    LabeledContent("扶養親族の人数", value: p.dependentsCount.formatted())
                    if p.hasSpouseAllowance { Text("配偶者控除あり") }
                }
            case .deductions:
                if let d = try? decoder.decode(Deduction.self, from: record.data) {
                    Text(verbatim: "\(d.month) · \(d.category) · ¥\(d.amount.formatted())")
                    Text(verbatim: d.note)
                }
            case .actualPayments:
                if let p = try? decoder.decode(ActualPayment.self, from: record.data) {
                    Text(verbatim: "\(p.payDate) · \(p.employer) · ¥\(p.amount.formatted())")
                }
            case .recurringExpenses:
                if let r = try? decoder.decode(RecurringExpense.self, from: record.data) {
                    Text(verbatim: "\(r.name) · \(r.category) · ¥\(r.amount.formatted())")
                    Text(verbatim: r.memo)
                    day("毎月の支払日", r.dayOfMonth)
                    Text(LocalizedStringKey(r.isActive ? "有効" : "停止中"))
                }
            }
        } else { Text("記録なし・削除済み").foregroundStyle(.secondary) }
    }
}

struct SyncRecoveryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
