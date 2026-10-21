import SwiftUI

/// Enter one payslip figure for annual-income tracking. Take-home is optional and remains a
/// separate value, including when editing a legacy record that contained only take-home pay.
struct ActualPaySheet: View {
    let prompt: PaydayPrompt
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var amountText = ""
    @State private var grossText = ""
    @State private var showTakeHome = false
    @State private var showDeleteConfirmation = false
    @AppStorage(IncomeWallSettings.annualTargetKey) private var annualTarget = 0.0
    @FocusState private var amountFocused: Bool

    private var gross: Double? { FormNumber.nonnegative(grossText) }
    private var takeHome: Double? { amountText.isEmpty ? nil : FormNumber.nonnegative(amountText) }
    private var canSave: Bool { gross != nil && (amountText.isEmpty || takeHome != nil) }
    private var existingPayment: ActualPayment? {
        store.actualPayments.first { $0.employer == prompt.profile.name && $0.payDate == prompt.payDate }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("勤務先", value: prompt.profile.name)
                    LabeledContent("支給日", value: DateUtils.formatFullDate(prompt.payDate, locale: locale))
                }
                Section {
                    TextField("円", text: $grossText)
                        .keyboardType(.numberPad)
                        .focused($amountFocused)
                        .accessibilityLabel("給与明細の課税支給額")
                } header: { Text("給与明細の「課税支給額」") }
                  footer: { Text("税金や保険料が引かれる前の金額です。非課税の交通費は含めません。振込額や「課税対象額（社会保険料控除後）」とは異なります。") }
                Section {
                    DisclosureGroup("手取りも記録する（任意）", isExpanded: $showTakeHome) {
                        TextField("実際の振込額（円）", text: $amountText)
                            .keyboardType(.numberPad).accessibilityLabel("実際の振込額")
                    }
                }
                if annualTarget > 0, annualTarget.isFinite, let gross,
                   prompt.payDate <= DateUtils.todayYMD() {
                    Section("入力後の年収の目安") {
                        let year = Int(prompt.payDate.prefix(4)) ?? DateUtils.calendar.component(.year, from: Date())
                        let otherPayments = store.actualPayments.filter { !($0.employer == prompt.profile.name && $0.payDate == prompt.payDate) }
                        let total = Aggregation.recordedIncome(year: year, through: DateUtils.todayYMD(), payments: otherPayments).taxableGross + gross
                        LabeledContent("\(String(year))年の給与累計", value: yen(total))
                        LabeledContent(total > annualTarget ? "上限を超えた金額" : "上限まであと", value: yen(abs(annualTarget - total)))
                    }
                }
                if prompt.payDate > DateUtils.todayYMD() {
                    Text("年収の累計には、この支給日から反映されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if existingPayment != nil {
                    Section {
                        Button("この給与記録を削除", role: .destructive) { showDeleteConfirmation = true }
                    }
                }
            }
            .navigationTitle("給料を記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard canSave, let gross else { return }
                        store.recordActualPayment(employer: prompt.profile.name, payDate: prompt.payDate, amount: takeHome, taxableGross: gross)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let payment = existingPayment {
                    if let amount = payment.amount { amountText = FormNumber.text(amount) }
                    if let gross = payment.taxableGross { grossText = FormNumber.text(gross) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { amountFocused = true }
            }
            .confirmationDialog("この給与記録を削除しますか？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let payment = existingPayment { store.deleteActualPayment(id: payment.id) }
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }
}
