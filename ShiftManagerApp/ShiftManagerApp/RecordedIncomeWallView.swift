import SwiftUI

/// The everyday view uses recorded payslips and one user-selected annual limit. It does not
/// claim that calendar-year receipts determine health-insurance dependency or predict safety.
struct RecordedIncomeWallCard: View {
    @EnvironmentObject var store: ShiftStore
    @AppStorage(IncomeWallSettings.annualTargetKey) private var annualTarget = 0.0
    @State private var showDetails = false
    let year: Int

    var body: some View {
        let summary = Aggregation.recordedIncome(year: year, through: DateUtils.todayYMD(), payments: store.actualPayments)
        Button { showDetails = true } label: {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader("年収の壁までの残り", systemImage: "chart.bar.fill") {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }
                if annualTarget > 0, annualTarget.isFinite {
                    Text(summary.taxableGross > annualTarget ? "設定した上限を超えた金額" : "設定した上限まであと")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(yen(abs(annualTarget - summary.taxableGross)))
                        .font(.system(size: 28, weight: .regular, design: .default))
                        .foregroundStyle(summary.taxableGross > annualTarget ? Color.orange : Color.accentColor)
                    ProgressView(value: min(summary.taxableGross, annualTarget), total: annualTarget)
                    HStack {
                        Text("記録済み \(yen(summary.taxableGross))")
                        Spacer()
                        Text("上限 \(yen(annualTarget))")
                    }.font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("今年の給与（入力済み）").font(.caption).foregroundStyle(.secondary)
                    Text(yen(summary.taxableGross)).font(.title2.weight(.regular)).foregroundStyle(.primary)
                    Text("自分の上限を設定する").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                Text("\(String(year))年の支給分・給与明細から入力した金額のみ")
                    .font(.caption2).foregroundStyle(.secondary)
                if summary.missingGrossCount > 0 {
                    Text("手取りだけの記録\(summary.missingGrossCount)件は、年収に未集計です。")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appCard()
        .sheet(isPresented: $showDetails) { RecordedIncomeWallDetailView(year: year).environmentObject(store) }
    }
}

struct RecordedIncomeWallDetailView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(IncomeWallSettings.annualTargetKey) private var annualTarget = 0.0
    @State private var targetText = ""
    @State private var paymentPrompt: PaydayPrompt?
    let year: Int

    private var enteredTarget: Double? {
        guard let value = FormNumber.nonnegative(targetText), value > 0 else { return nil }
        return value
    }
    private var payments: [ActualPayment] {
        store.actualPayments.filter { $0.payDate.hasPrefix("\(year)-") && $0.payDate <= DateUtils.todayYMD() }
            .sorted { $0.payDate > $1.payDate }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    let summary = Aggregation.recordedIncome(year: year, through: DateUtils.todayYMD(), payments: store.actualPayments)
                    LabeledContent("今年の給与（入力済み）", value: yen(summary.taxableGross))
                    if let target = enteredTarget {
                        LabeledContent(summary.taxableGross > target ? "上限を超えた金額" : "上限まであと", value: yen(abs(target - summary.taxableGross)))
                    }
                    Text("シフトからの見込みは含めず、支給済みの給与明細から入力した金額を合計します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    HStack {
                        Text("自分の上限")
                        TextField("金額", text: $targetText).keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing).accessibilityLabel("年収の上限")
                        Text("円")
                    }
                    Text("税金の扶養など、確認したい年間の給与上限を設定してください。年齢・年度・家族の条件で異なるため、金額は家族と確認して設定できます。")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("年収の壁の目安") }
                Section("入力した給与") {
                    if payments.isEmpty {
                        Text("給料日になったら、給与画面から実際の金額を入力しましょう。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(payments) { payment in
                        Button {
                            if let profile = store.employerProfiles.first(where: { $0.name == payment.employer }) {
                                paymentPrompt = PaydayPrompt(profile: profile, payDate: payment.payDate)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(payment.employer).foregroundStyle(.primary)
                                    Text(payment.payDate).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let gross = payment.taxableGross {
                                    Text(yen(gross)).foregroundStyle(.primary)
                                } else {
                                    Text("支給額を入力").font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                        .disabled(!store.employerProfiles.contains { $0.name == payment.employer })
                    }
                }
                Section {
                    Text("給与明細の課税支給額を1〜12月の支給日で合計します。健康保険の扶養は、将来の収入見込みなど別の基準です。この表示だけで扶養内かどうかは判定しません。")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("給与に含まれる金額について（国税庁）", destination: URL(string: "https://www.nta.go.jp/taxes/shiraberu/taxanswer/gensen/2508.htm")!)
                        .font(.caption)
                }
            }
            .navigationTitle("年収の壁")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let target = enteredTarget else { return }
                        annualTarget = target
                        dismiss()
                    }.disabled(enteredTarget == nil)
                }
            }
            .onAppear { if targetText.isEmpty, annualTarget > 0 { targetText = FormNumber.text(annualTarget) } }
            .sheet(item: $paymentPrompt) { prompt in ActualPaySheet(prompt: prompt).environmentObject(store) }
        }
    }
}
