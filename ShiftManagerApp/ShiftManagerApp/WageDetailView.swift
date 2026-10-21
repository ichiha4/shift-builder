import SwiftUI

/// Everything the compact Wage tab tucks behind "詳細を見る": the hour-by-hour payslip
/// breakdown, weekly overtime accounting, and the per-employer income-tax withholding that
/// backs the headline 控除 figure.
struct WageDetailView: View {
    let payslip: MonthlyPayslip
    let weeklyBuckets: [(key: String, value: WeeklyBucket)]
    let incomeTaxRows: [EmployerIncomeTax]
    let paydayYear: Int
    let usesManualIncomeTax: Bool
    private var hasKou: Bool { incomeTaxRows.contains { $0.column == .kou } }
    private var hasOtsu: Bool { incomeTaxRows.contains { $0.column == .otsu } }
    @Environment(\.locale) private var locale

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                payslipCard
                if !incomeTaxRows.isEmpty { incomeTaxCard }
                weeklyHoursCard
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("給与明細の詳細")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Payslip breakdown

    private var payslipCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("給与明細(支給)", systemImage: "doc.text.fill")

            VStack(alignment: .leading, spacing: 4) {
                hoursRow("通常労働", payslip.normalMinutes)
                if payslip.scheduledOvertimeMinutes > 0 { hoursRow("所定内残業(割増なし)", payslip.scheduledOvertimeMinutes) }
                if payslip.overtimeMinutes > 0 { hoursRow("法定時間外労働", payslip.overtimeMinutes, accent: true) }
                if payslip.extendedOvertimeMinutes > 0 { hoursRow("うち月60時間超(5割増)", payslip.extendedOvertimeMinutes, accent: true) }
                if payslip.lateNightMinutes > 0 { hoursRow("深夜労働", payslip.lateNightMinutes, accent: true) }
                if payslip.holidayMinutes > 0 { hoursRow("法定休日労働", payslip.holidayMinutes, accent: true) }
            }
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            payAccordionRow(label: "基本給", amount: payslip.base, minutes: payslip.baseMinutes, contributors: [])
            payAccordionRow(label: "法定時間外(残業)割増", amount: payslip.overtime, minutes: payslip.overtimeMinutes, contributors: payslip.overtimeContributors, tone: .green)
            payAccordionRow(label: "深夜割増", amount: payslip.lateNight, minutes: payslip.lateNightMinutes, contributors: payslip.lateNightContributors, tone: .green)
            payAccordionRow(label: "法定休日割増", amount: payslip.holiday, minutes: payslip.holidayMinutes, contributors: payslip.holidayContributors, tone: .red)
            payAccordionRow(label: "交通費", amount: payslip.transport, minutes: nil, contributors: payslip.transportContributors, tone: .green)
            payAccordionRow(label: "その他手当", amount: payslip.otherAllowance, minutes: nil, contributors: payslip.otherAllowanceContributors, tone: .green)
            // Only shows when a break was entered without a start time: the rows above are then
            // computed over the whole span, and this is what brings them back to the pay the
            // shift actually earned — without it the rows wouldn't add up to the total below.
            if payslip.breakDeduction > 0.5 {
                HStack {
                    Text("休憩(開始時刻なし)の差し引き").font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text("−" + yen(payslip.breakDeduction)).font(.subheadline).foregroundStyle(.red)
                }
                .padding(.vertical, 4)
            }

            Divider()
            HStack {
                Text("総支給額").fontWeight(.heavy)
                Spacer()
                Text(yen(payslip.grossTotal)).fontWeight(.heavy).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    private func hoursRow(_ label: String, _ minutes: Int, accent: Bool = false) -> some View {
        HStack {
            Text(label).foregroundStyle(accent ? .primary : .secondary).fontWeight(accent ? .semibold : .regular)
            Spacer()
            Text(hoursLabel(minutes)).foregroundStyle(accent ? .primary : .secondary).fontWeight(accent ? .semibold : .regular)
        }
        .font(.subheadline)
    }

    private func payAccordionRow(label: String, amount: Double, minutes: Int?, contributors: [PayContributor], tone: Color = .primary) -> some View {
        Group {
            if amount == 0 && contributors.isEmpty {
                HStack {
                    Text(label).foregroundStyle(.secondary)
                    Spacer()
                    Text(yen(amount)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 4)
            } else {
                DisclosureGroup {
                    if contributors.isEmpty {
                        Text("対象のシフトはありません。").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                    } else {
                        ForEach(Array(contributors.enumerated()), id: \.offset) { _, item in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text("\(item.shift.date.suffix(5)) ・ \(item.shift.employer)").font(.caption)
                                    Spacer()
                                    Text((item.minutes != nil ? "\(hoursLabel(item.minutes!)) × " : "") + yen(item.amount)).font(.caption)
                                }
                                ForEach(Array(item.formula.enumerated()), id: \.offset) { _, f in
                                    Text("\(f.range)(\(String(format: "%.1f", f.hours))h) × ¥\(Int(f.wage)) × \(Int(f.rate * 100))% = \(yen(f.amount))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                } label: {
                    HStack {
                        Text(label + (minutes != nil && minutes! > 0 ? "(\(hoursLabel(minutes!)))" : ""))
                        Spacer()
                        Text(yen(amount)).foregroundStyle(tone).fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }
            }
        }
    }

    // MARK: - Income tax

    private var incomeTaxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("所得税(源泉徴収)の内訳", systemImage: "percent")
            Text("勤務先ごとに、その月の給与額(交通費を除く)に、支給日の年の国税庁の源泉徴収税額表を適用して計算しています。")
                .font(.caption).foregroundStyle(.secondary)
            if !IncomeTax.exactYears.contains(paydayYear) {
                Text("\(String(paydayYear))年分の税額表には対応していないため、\(String(IncomeTax.tableYear(for: paydayYear)))年分の税額表で計算した目安です。")
                    .font(.caption).foregroundStyle(.orange)
            }
            ForEach(incomeTaxRows, id: \.employer) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.employer).fontWeight(.semibold)
                        Group {
                            if row.column == .kou {
                                Text("甲欄・課税対象 \(yen(row.taxableGross))")
                            } else {
                                Text("乙欄・課税対象 \(yen(row.taxableGross))")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("−" + yen(row.tax)).foregroundStyle(usesManualIncomeTax ? Color.secondary : Color.red).fontWeight(.semibold)
                }
                .font(.subheadline)
            }
            Divider()
            HStack {
                Text("所得税合計").foregroundStyle(.secondary)
                Spacer()
                Text("−" + yen(incomeTaxRows.reduce(0) { $0 + $1.tax })).foregroundStyle(usesManualIncomeTax ? Color.secondary : Color.red)
            }
            .font(.subheadline)
            VStack(alignment: .leading, spacing: 4) {
                if usesManualIncomeTax {
                    Text("この月は給与明細の所得税(手入力)を使うため、この自動計算は控除合計に含めていません。")
                }
                if incomeTaxRows.count > 1 {
                    if hasKou {
                        Text("社会保険料は、甲欄の勤務先の給与から引かれたものとして計算しています。")
                    } else {
                        Text("甲欄の勤務先がないため、社会保険料は勤務先ごとの給与額に応じて分けて計算しています。")
                    }
                }
                if hasKou {
                    Text("甲欄の勤務先の毎月の源泉徴収は仮の税額で、1年分はその勤務先の年末調整(通常は12月の給与)で精算されます。年の途中で退職して年内に再就職しない場合などは、確定申告で精算します(給与が少ない場合は退職時に年末調整されることもあります)。")
                    if (2025...2027).contains(paydayYear) {
                        Text("2025〜2027年は、基礎控除などの引き上げが毎月の税額表に十分反映されておらず、その差は甲欄の勤務先の年末調整で精算されます(多くの場合は還付)。")
                    }
                    Text("甲欄は国税庁の電算機計算の特例で計算しています。勤務先が税額表で計算している場合は、百数十円程度(給与が高いと300円程度)の差が出ることがあります。")
                }
                if hasOtsu {
                    Text("乙欄の給与は年末調整されません。年末調整されなかった給与などが年20万円を超える場合は、原則として確定申告が必要です。申告が不要な場合も、確定申告で引かれすぎた税金が戻ることがあります。")
                }
                Text("交通費は非課税として除いています。車・自転車通勤の手当は、距離に応じた上限を超える分が課税されます。")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - Weekly hours

    private var weeklyHoursCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("週ごとの労働時間", systemImage: "clock.fill")
            Text("週40時間(法定)を超えた分は、勤務先ごとに集計して自動的に法定時間外として給与に反映されています。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if weeklyBuckets.isEmpty {
                Text("この月のシフト記録がありません。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(weeklyBuckets, id: \.key) { wk, bucket in
                    DisclosureGroup {
                        ForEach(Array(bucket.items.enumerated()), id: \.offset) { _, item in
                            HStack {
                                Text("\(item.shift.date.suffix(5)) ・ \(item.shift.employer)").font(.caption)
                                Spacer()
                                Text(hoursLabel(item.minutes)).font(.caption)
                            }
                            .padding(8)
                            .background(Color(.tertiarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    } label: {
                        HStack {
                            Text(DateUtils.weekLabel(wk, locale: locale))
                            Spacer()
                            Text(hoursLabel(bucket.totalMinutes) + (bucket.weeklyLegalOvertimeMinutes > 0 ? "(週次残業\(hoursLabel(bucket.weeklyLegalOvertimeMinutes)))" : ""))
                                .foregroundStyle(bucket.weeklyLegalOvertimeMinutes > 0 ? .red : .primary)
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}
