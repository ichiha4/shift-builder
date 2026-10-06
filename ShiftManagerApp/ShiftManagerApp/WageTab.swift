import SwiftUI

struct WageTab: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.locale) private var locale
    @Binding var month: String

    @State private var showDeductionForm = false
    @State private var deductionCategory = PayrollConstants.deductionCategories[0]
    @State private var deductionNote = ""
    @State private var deductionAmountText = ""
    @State private var deductionError: String?
    @State private var showEmployerProfiles = false
    /// Held so any action that changes the deductions card's height (opening the manual-add
    /// form, tapping a preset) can re-anchor the scroll position — otherwise the ScrollView
    /// loses its place and jumps back to the top when that content reflows.
    @State private var scrollProxy: ScrollViewProxy?
    private static let deductionsAnchor = "deductionsCard"

    private func keepScrollAnchored() {
        withAnimation { scrollProxy?.scrollTo(Self.deductionsAnchor, anchor: .top) }
    }

    /// The shifts actually being paid out this month — for an employer with a saved profile,
    /// that's the shifts in whichever closing-day period's PAYDAY (not work date) lands in
    /// `month`, the same basis the Home tab's payday card already uses. A plain calendar-month
    /// filter is only correct when every employer's closing day is the last day of the month;
    /// for one that closes on, say, the 10th and pays on the 25th, the second half of a
    /// calendar month actually belongs to *next* month's payslip, and the old filter mixed the
    /// two periods together into a number that matched no real payday. An employer without a
    /// saved profile has no closing day to key off, so its shifts still use plain calendar-month
    /// grouping — unchanged from before.
    private var monthShifts: [Shift] {
        PayPeriod.shifts(paidInMonth: month, shifts: store.shifts, profiles: store.employerProfiles)
    }
    /// `month` is the payday month here, so its year picks the NTA withholding table.
    private var paydayYear: Int { Int(month.prefix(4)) ?? DateUtils.calendar.component(.year, from: Date()) }
    private var monthDeductions: [Deduction] { store.deductions.filter { $0.month == month } }
    private var payslip: MonthlyPayslip { Aggregation.calculateMonthlyPay(monthShifts, classifications: store.classifications) }
    /// One row per employer, taxed independently — never combine employers before withholding.
    private var incomeTaxRows: [EmployerIncomeTax] {
        Aggregation.calculateIncomeTax(monthShifts, classifications: store.classifications, profiles: store.employerProfiles, socialInsurance: socialInsuranceTotal, year: paydayYear)
    }
    /// Only the three 社会保険料 rows feed the withholding calculation — a manually entered 所得税
    /// row is that calculation's output, and 住民税 is assessed separately on last year's income.
    private var socialInsuranceTotal: Double {
        monthDeductions
            .filter { PayrollConstants.socialInsuranceCategories.contains($0.category) }
            .reduce(0) { $0 + $1.amount }
    }
    private var incomeTaxTotal: Double { incomeTaxRows.reduce(0) { $0 + $1.tax } }
    /// A 所得税 row typed in from the real payslip replaces the automatic estimate for the month —
    /// it is the same tax, so adding both would take it off twice.
    private var manualIncomeTax: Double? {
        let rows = monthDeductions.filter { $0.category == "所得税" }
        return rows.isEmpty ? nil : rows.reduce(0) { $0 + $1.amount }
    }
    private var manualDeductionsTotal: Double { monthDeductions.reduce(0) { $0 + $1.amount } }
    private var deductionsTotal: Double { manualDeductionsTotal + (manualIncomeTax == nil ? incomeTaxTotal : 0) }
    private var netIncome: Double { payslip.grossTotal - deductionsTotal }

    private var weeklyBuckets: [(key: String, value: WeeklyBucket)] {
        let map = Aggregation.calculateWeeklyHours(store.shifts, classifications: store.classifications)
        return map.filter { wk, _ in
            guard let (y, m, d) = DateUtils.parseYMD(wk) else { return false }
            let start = wk
            let end = DateUtils.ymd(DateUtils.calendar.date(byAdding: .day, value: 6, to: DateUtils.date(year: y, month: m, day: d))!)
            return start.hasPrefix(month) || end.hasPrefix(month)
        }.map { (key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 16) {
                        monthNav
                        flowSummary
                        detailsLinkCard
                        if !store.employerProfiles.isEmpty { paydayCard }
                        if store.actualPayments.contains(where: { $0.payDate.hasPrefix(month) }) { actualPaymentsCard }
                        deductionsCard
                            .id(Self.deductionsAnchor)
                    }
                    .padding(16)
                    .readableColumn()
                }
                .onAppear { scrollProxy = proxy }
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("給与").font(.title2.weight(.bold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showEmployerProfiles = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("勤務先を追加")
                }
            }
            .sheet(isPresented: $showEmployerProfiles) {
                EmployerProfilesView().environmentObject(store)
            }
        }
    }

    private var monthNav: some View {
        HStack {
            Button { month = DateUtils.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("前の月")
            Spacer()
            Text(DateUtils.monthLabel(month, locale: locale)).font(.headline)
            Spacer()
            Button { month = DateUtils.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("次の月")
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Flow summary

    private var flowSummary: some View {
        HStack(spacing: 4) {
            flowBox(label: "総支給", value: payslip.grossTotal, color: .green)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            flowBox(label: "控除", value: -deductionsTotal, color: .red)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            flowBox(label: "手取り", value: netIncome, color: .accentColor, bold: true)
        }
        .appCard(padding: 14)
    }

    private func flowBox(label: LocalizedStringKey, value: Double, color: Color, bold: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
            Text((value < 0 ? "−" : "") + yen(abs(value)))
                .font(.system(size: 13, weight: bold ? .black : .bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Details link

    /// The full breakdown (hours, per-allowance formulas, per-employer income tax) lives on a
    /// separate screen — with income tax now added, showing everything inline made this tab
    /// feel like a wall of numbers. The three headline figures above are what most visits need.
    private var detailsLinkCard: some View {
        NavigationLink {
            WageDetailView(payslip: payslip, weeklyBuckets: weeklyBuckets, incomeTaxRows: incomeTaxRows,
                           paydayYear: paydayYear, usesManualIncomeTax: manualIncomeTax != nil)
        } label: {
            HStack {
                Label("給与明細の詳細を見る", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .foregroundStyle(.primary)
            .appCard()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Payday

    private var paydayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("給与の支給予定", systemImage: "calendar.badge.clock")
            ForEach(store.employerProfiles) { profile in
                let period = PayPeriod.period(forDate: DateUtils.todayYMD(), closingDay: profile.closingDay)
                let payDate = PayPeriod.paymentDate(periodEnd: period.periodEnd, paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
                let rawPayDate = PayPeriod.paymentDate(periodEnd: period.periodEnd, paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay, adjustment: .none)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.name).fontWeight(.semibold)
                        Text("\(DateUtils.formatPeriodDate(period.periodStart))〜\(DateUtils.formatPeriodDate(period.periodEnd))分")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(DateUtils.formatFullDate(payDate, locale: locale)).font(.subheadline)
                        if payDate != rawPayDate {
                            Group {
                                if profile.paydayAdjustment == .beforeBusinessDay {
                                    Text("土日祝・年末年始のため繰り上げ")
                                } else {
                                    Text("土日祝・年末年始のため繰り下げ")
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - Actual pay received (recorded from the payday-banner prompt)

    private var actualPaymentsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("受け取った給与", systemImage: "checkmark.seal.fill")
            ForEach(store.actualPayments.filter { $0.payDate.hasPrefix(month) }.sorted { $0.payDate > $1.payDate }) { payment in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payment.employer).fontWeight(.semibold)
                        Text(DateUtils.formatFullDate(payment.payDate, locale: locale))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(yen(payment.amount)).foregroundStyle(.green).fontWeight(.semibold)
                    Button {
                        store.deleteActualPayment(id: payment.id)
                    } label: {
                        Image(systemName: "trash").foregroundStyle(.secondary).accessibilityLabel("削除")
                    }
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }

    // MARK: - Deductions

    /// Employee shares for the preset buttons, for the payday month on screen. Rough by design
    /// (the card says 概算): 健康保険 is the 協会けんぽ national average — prefectures and 健保組合
    /// differ — and 介護保険 (40〜64歳) is left out.
    /// - 健康保険: premiums are normally taken from the next month's pay, so the rate follows the
    ///   month before the payday. 協会けんぽ平均 10.0% until 令和8年2月分; 9.9% from 令和8年3月分
    ///   (協会けんぽ changes its rate with the 3月分, paid in April); the 子ども・子育て支援金 0.23%
    ///   from 令和8年4月分 (both halved for the employee).
    /// - 厚生年金: 18.3%, halved — unchanged since 2017.
    /// - 雇用保険 (一般の事業, 労働者負担), by the wage-closing month — taken as the month before the
    ///   payday, the usual 翌月払い: 3/1,000 to 令和4年9月, 5/1,000 令和4年10月〜令和5年3月,
    ///   6/1,000 令和5・6年度, 5.5/1,000 令和7年度, 5/1,000 令和8年度 (厚生労働省「令和N年度の雇用
    ///   保険料率について」, each year's leaflet).
    private var autoRates: [(label: String, rate: Double)] {
        let premiumMonth = DateUtils.shiftMonth(month, by: -1)   // "YYYY-MM"
        let health = (premiumMonth >= "2026-03" ? 0.0495 : 0.05) + (premiumMonth >= "2026-04" ? 0.00115 : 0)
        let employment: Double
        switch premiumMonth {
        case ..."2022-09": employment = 0.003
        case ..."2023-03": employment = 0.005
        case ..."2025-03": employment = 0.006
        case ..."2026-03": employment = 0.0055
        default: employment = 0.005
        }
        return [("健康保険料", health), ("厚生年金保険料", 0.0915), ("雇用保険料", employment)]
    }

    /// The preset buttons below always show the *would-be* estimate for the category — that
    /// figure showing doesn't mean it's actually counted in 手取り予測 yet, only that it will be
    /// once tapped. This tells the button (and its caption) whether that's already happened for
    /// this month, since displaying a ¥ figure with no other cue reads as "already applied."
    private func isDeductionAdded(_ category: String) -> Bool {
        monthDeductions.contains { $0.category == category }
    }

    private var deductionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("控除(概算・参考値)", systemImage: "minus.circle") {
                Button {
                    showDeductionForm = true
                    keepScrollAnchored()
                } label: {
                    Label("手入力で追加", systemImage: "plus").font(.caption)
                }
            }
            Text("健康保険・厚生年金・雇用保険・所得税・住民税はそれぞれ独立した項目として管理します。実際の給与明細を優先してください。")
                .font(.caption).foregroundStyle(.secondary)
            // An inline note rather than two lines of orange body text: the warning is about the
            // three buttons directly below it, so it belongs attached to them, and orange running
            // text at full width read as an error on the whole screen.
            Label("下の3つはタップして追加するまで手取り予測に反映されません。", systemImage: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous))

            HStack(spacing: 8) {
                ForEach(autoRates, id: \.label) { preset in
                    let added = isDeductionAdded(preset.label)
                    Button {
                        let amount = (payslip.grossTotal * preset.rate / 10).rounded() * 10
                        store.addOrReplaceDeduction(month: month, category: preset.label, amount: amount, note: "概算 \(String(format: "%.3f", preset.rate * 100))%")
                        keepScrollAnchored()
                    } label: {
                        VStack(spacing: 2) {
                            HStack(spacing: 3) {
                                if added {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 9)).foregroundStyle(.green)
                                }
                                Text(LocalizedStringKey(preset.label)).font(.system(size: 10.5, weight: .semibold))
                            }
                            Text(yen((payslip.grossTotal * preset.rate / 10).rounded() * 10)).font(.system(size: 11, weight: .bold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(added ? Color.green.opacity(0.16) : Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous))
                        // Untapped presets carry an accent-tinted border so they read as buttons
                        // waiting to be pressed; the plain grey fill they had was indistinguishable
                        // from the read-only figures elsewhere on this card.
                        .overlay(
                            RoundedRectangle(cornerRadius: AppStyle.controlRadius, style: .continuous)
                                .strokeBorder(added ? Color.green.opacity(0.5) : Color.accentColor.opacity(0.28), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            if incomeTaxTotal > 0 {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("所得税(源泉徴収)").fontWeight(.semibold)
                        if manualIncomeTax != nil {
                            Text("給与明細の所得税(手入力)を使うため、自動計算は合計に含めていません").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("勤務先ごとに自動計算・国税庁の税額表に基づく").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if manualIncomeTax != nil {
                        Text(yen(incomeTaxTotal)).foregroundStyle(.secondary).strikethrough()
                    } else {
                        Text("−" + yen(incomeTaxTotal)).foregroundStyle(.red)
                    }
                }
                .font(.subheadline)
            }

            if monthDeductions.isEmpty {
                Text("この月の控除はまだありません。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(monthDeductions) { deduction in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(deduction.category)).fontWeight(.semibold)
                            if !deduction.note.isEmpty { Text(deduction.note).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Text("−" + yen(deduction.amount)).foregroundStyle(.red)
                        Button {
                            store.deleteDeduction(id: deduction.id)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary).accessibilityLabel("削除")
                        }
                    }
                    .font(.subheadline)
                }
            }

            if showDeductionForm {
                Divider()
                Picker("カテゴリ", selection: $deductionCategory) {
                    ForEach(PayrollConstants.deductionCategories, id: \.self) { Text(LocalizedStringKey($0)) }
                }
                TextField("金額(円)", text: $deductionAmountText).keyboardType(.numberPad)
                TextField("メモ(任意)", text: $deductionNote)
                if let deductionError { Text(deductionError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("控除を追加") {
                        // ¥0 is a real payslip value for 所得税 — it still overrides the estimate.
                        guard let amount = Double(deductionAmountText),
                              amount > 0 || (amount == 0 && deductionCategory == "所得税") else {
                            deductionError = "金額を入力してください"
                            return
                        }
                        store.addOrReplaceDeduction(month: month, category: deductionCategory, amount: amount, note: deductionNote)
                        deductionAmountText = ""; deductionNote = ""; deductionError = nil; showDeductionForm = false
                        keepScrollAnchored()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("キャンセル") {
                        showDeductionForm = false
                        keepScrollAnchored()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()
            HStack {
                Text("控除合計").foregroundStyle(.secondary)
                Spacer()
                Text("−" + yen(deductionsTotal)).foregroundStyle(.red)
            }
            .font(.subheadline)
            HStack {
                Text("手取り予測").fontWeight(.heavy)
                Spacer()
                Text(yen(netIncome)).fontWeight(.heavy).foregroundStyle(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard()
    }
}

/// Everything the compact Wage tab tucks behind "詳細を見る": the hour-by-hour payslip
/// breakdown, weekly overtime accounting, and the per-employer income-tax withholding that
/// backs the headline 控除 figure.
private struct WageDetailView: View {
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
