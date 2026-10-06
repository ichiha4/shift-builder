import SwiftUI
import Charts

struct CashFlowForecastView: View {
    @EnvironmentObject private var store: ShiftStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var balanceText = ""
    @State private var asOfDate = DateUtils.todayYMD()
    @State private var horizon = 7
    @State private var expectedPayments: [ExpectedPayment] = []
    @State private var editingIncome: CashFlowEvent?
    @State private var showPaywall = false
    @FocusState private var isBalanceFocused: Bool

    private var projection: CashFlowProjection? {
        guard let balance = planningAmount(balanceText, allowNegative: true) else { return nil }
        return CashFlowForecast.project(asOfDate: asOfDate, openingBalance: balance,
            days: subscriptions.hasPlus ? horizon : 7, shifts: store.shifts,
            profiles: store.employerProfiles, actualPayments: store.actualPayments,
            expenses: store.expenses, recurringExpenses: store.recurringExpenses,
            expectedPayments: expectedPayments)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("基準日", value: DateUtils.formatFullDate(asOfDate, locale: locale))
                HStack {
                    Text("今日の残高（円）")
                    TextField("例：30000", text: $balanceText)
                        .keyboardType(.numbersAndPunctuation)
                        .multilineTextAlignment(.trailing).focused($isBalanceFocused)
                        .accessibilityLabel("今日の残高（円）")
                }
                Picker("予測期間", selection: Binding(get: { horizon }, set: { value in
                    isBalanceFocused = false
                    if value == 90 && !subscriptions.hasPlus { showPaywall = true }
                    else { horizon = value }
                })) {
                    Text("7日・無料").tag(7)
                    Text("90日・Plus").tag(90)
                }.pickerStyle(.segmented)
                if !balanceText.isEmpty && planningAmount(balanceText, allowNegative: true) == nil {
                    Text("残高を正しい金額で入力してください。")
                        .font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("今日の入出金を反映した残高を入力してください。予測は明日から始まります。入力した残高と見込み手取りは、この画面を閉じるとリセットされます。")
            }

            if let projection {
                Section("残高の見通し") {
                    LabeledContent("最終日の予測残高", value: yen(projection.closingBalance))
                    LabeledContent("最小の日末残高", value: yen(projection.minimumBalance))
                    if let date = projection.firstNegativeDate {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("残高不足が予測されています").fontWeight(.semibold)
                                Text(DateUtils.formatFullDate(date, locale: locale))
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(.subheadline).foregroundStyle(.red)
                    }
                    Chart {
                        RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.secondary.opacity(0.4))
                        ForEach([CashFlowDay(date: asOfDate, balance: projection.openingBalance)] + projection.days) { day in
                            if let date = planningDate(day.date) {
                                LineMark(x: .value("Date", date), y: .value("Balance", day.balance))
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                    .chartYAxis { AxisMarks(position: .leading) }
                    .frame(height: 180).padding(.vertical, 8)
                    .accessibilityLabel("残高の見通し")
                }

                Section {
                    Text("未調整の給与予測は控除前です。入金予定をタップして、見込み手取りに置き換えられます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("登録済みのシフト・支出・有効な定期支出だけを計算します。未入力の生活費や、同じ日の入出金の順序は反映していません。")
                        .font(.caption).foregroundStyle(.secondary)
                    if store.shifts.contains(where: { shift in !store.employerProfiles.contains { $0.name == shift.employer } }) {
                        Text("給与の予測には勤務先の締め日・支払日が必要です。未設定の勤務先は給与予測に含まれません。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                if projection.events.isEmpty {
                    Section {
                        Text("この期間に登録された入出金予定はありません。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(Set(projection.events.map(\.date))).sorted(), id: \.self) { date in
                        Section(DateUtils.formatFullDate(date, locale: locale)) {
                            ForEach(projection.events.filter { $0.date == date }) { event in
                                if event.kind == .grossEstimate || event.kind == .expectedTakeHome {
                                    Button {
                                        isBalanceFocused = false
                                        editingIncome = event
                                    } label: { eventRow(event, editable: true) }
                                    .buttonStyle(.plain)
                                } else { eventRow(event) }
                            }
                        }
                    }
                }
            } else if balanceText.isEmpty {
                Section {
                    Text("今日の残高を入力すると、給料日と支出予定から予測が表示されます。")
                        .foregroundStyle(.secondary)
                }
            }
            if !subscriptions.hasPlus {
                Section {
                    Button("Plusで90日先まで予測") {
                        isBalanceFocused = false
                        showPaywall = true
                    }
                }
            }
        }
        .navigationTitle("残高予測")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") { isBalanceFocused = false }
            }
        }
        .sheet(item: $editingIncome) { event in
            ExpectedPaymentSheet(event: event) { amount in
                expectedPayments.removeAll { $0.employer == event.title && $0.payDate == event.date }
                if let amount {
                    expectedPayments.append(ExpectedPayment(employer: event.title, payDate: event.date, amount: amount))
                }
            }
        }
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PlusPaywallView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showPaywall = false } }
                }
            }
        }
        .onChange(of: subscriptions.hasPlus) { _, active in
            if active && showPaywall { horizon = 90; showPaywall = false }
            if !active { horizon = 7 }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && asOfDate != DateUtils.todayYMD() {
                asOfDate = DateUtils.todayYMD()
                balanceText = ""
                expectedPayments = []
            }
        }
    }

    private func eventRow(_ event: CashFlowEvent, editable: Bool = false) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(event.title).font(.subheadline)
                Text(event.kind.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text((event.amount > 0 ? "+" : "") + yen(event.amount))
                .font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(event.amount < 0 ? Color.primary : Color.accentColor)
            if editable { Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary) }
        }.padding(.vertical, 3)
    }
}

private struct ExpectedPaymentSheet: View {
    let event: CashFlowEvent
    let save: (Double?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var amountText: String

    init(event: CashFlowEvent, save: @escaping (Double?) -> Void) {
        self.event = event
        self.save = save
        _amountText = State(initialValue: String(format: "%.0f", event.amount))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("勤務先", value: event.title)
                    LabeledContent("支払日", value: DateUtils.formatFullDate(event.date, locale: locale))
                    TextField("見込み手取り（円）", text: $amountText).keyboardType(.decimalPad)
                    Button("シフトからの給与予測に戻す") { save(nil); dismiss() }
                } footer: {
                    Text("この画面の予測だけに使います。実際の受取記録や保存済みのシフトは変更されません。")
                }
            }
            .navigationTitle("見込み手取り")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("適用") {
                        guard let amount = planningAmount(amountText) else { return }
                        save(amount); dismiss()
                    }.disabled(planningAmount(amountText) == nil)
                }
            }
        }
    }
}

struct ShiftScenarioView: View {
    @EnvironmentObject private var store: ShiftStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @Environment(\.locale) private var locale
    @State private var month = String(DateUtils.todayYMD().prefix(7))
    @State private var adding = true
    @State private var selectedShiftID = ""
    @State private var selectedDate = DateUtils.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    @State private var statutoryHoliday = false
    @State private var scenarioID = UUID().uuidString

    private var options: [Shift] {
        let sorted = store.shifts.sorted { $0.date > $1.date }
        return adding ? Array(sorted.prefix(30)) : sorted.filter { $0.date.hasPrefix(month) }
    }
    private var source: Shift? { options.first { $0.id == selectedShiftID } }
    private var candidate: Shift? {
        guard let source, adding else { return nil }
        var copy = source.repeated(on: DateUtils.ymd(selectedDate))
        copy.id = scenarioID
        copy.isStatutoryHoliday = statutoryHoliday
        return copy
    }
    private var dateRange: ClosedRange<Date> {
        let first = planningDate(month + "-01")!
        let count = DateUtils.calendar.range(of: .day, in: .month, for: first)!.count
        return first...DateUtils.calendar.date(byAdding: .day, value: count - 1, to: first)!
    }
    private var hasConflict: Bool {
        candidate.map { ShiftScenario.hasOverlap($0, with: store.shifts) } ?? false
    }
    private var result: ShiftScenarioResult? {
        guard subscriptions.hasPlus, let source, !hasConflict else { return nil }
        return ShiftScenario.compare(month: month, shifts: store.shifts,
            adding: candidate.map { [$0] } ?? [], removingIDs: adding ? [] : [source.id])
    }

    var body: some View {
        Group {
            if subscriptions.hasPlus { scenarioForm }
            else { PlusPaywallView() }
        }
        .navigationTitle("シフトの収入比較")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var scenarioForm: some View {
        Form {
            Section {
                HStack {
                    Button { changeMonth(-1) } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("前の月")
                    Spacer()
                    Text(DateUtils.monthLabel(month, locale: locale)).font(.headline)
                    Spacer()
                    Button { changeMonth(1) } label: { Image(systemName: "chevron.right") }
                        .accessibilityLabel("次の月")
                }.buttonStyle(.borderless)
                Picker("比較する内容", selection: $adding) {
                    Text("1回増やす").tag(true)
                    Text("1回減らす").tag(false)
                }.pickerStyle(.segmented)
                if options.isEmpty {
                    Text("比較するシフトがありません。「シフト」タブで勤務を記録してください。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(LocalizedStringKey(adding ? "使うシフト" : "外すシフト"), selection: $selectedShiftID) {
                        ForEach(options) { shift in
                            Text("\(DateUtils.formatPeriodDate(shift.date)) · \(shift.employer) · \(segmentsSummary(shift.segments))")
                                .tag(shift.id)
                        }
                    }
                    if adding {
                        DatePicker("仮の勤務日", selection: $selectedDate, in: dateRange, displayedComponents: .date)
                        Toggle("この日は法定休日として計算する", isOn: $statutoryHoliday)
                    }
                    if let source {
                        Text(segmentsSummary(source.segments)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("選んだシフトの時給・休憩・手当を使って比較します。保存済みのシフトは変更されません。")
            }
            if hasConflict {
                Section {
                    Text("仮のシフトが登録済みの勤務時間と重なっています。別の日を選んでください。")
                        .foregroundStyle(.red)
                }
            }
            if let result {
                Section {
                    LabeledContent("現在の予定", value: yen(result.baselineGross))
                    LabeledContent("比較した予定", value: yen(result.scenarioGross))
                    HStack {
                        Text("給与の差額").fontWeight(.semibold)
                        Spacer()
                        Text((result.difference > 0 ? "+" : "") + yen(result.difference))
                            .font(.title2.bold()).monospacedDigit().foregroundStyle(Color.accentColor)
                    }.padding(.vertical, 8)
                    LabeledContent("勤務時間の差", value: hoursLabel(result.scenarioMinutes - result.baselineMinutes))
                } header: {
                    Text("この月の給与・控除前")
                } footer: {
                    Text("勤務月を基準に、すべてのシフトから残業・深夜・法定休日の割増を再計算します。税金・社会保険などの控除後の差額ではありません。")
                }
            }
        }
        .onAppear { selectDefault() }
        .onChange(of: adding) { _, _ in selectDefault() }
        .onChange(of: store.shifts) { _, _ in selectDefault() }
    }

    private func changeMonth(_ offset: Int) {
        let next = DateUtils.shiftMonth(month, by: offset)
        guard let (year, _, _) = DateUtils.parseYMD(next + "-01"), (1900...2200).contains(year) else { return }
        month = next
        selectedDate = max(dateRange.lowerBound, min(selectedDate, dateRange.upperBound))
        selectDefault()
    }

    private func selectDefault() {
        if !options.contains(where: { $0.id == selectedShiftID }) { selectedShiftID = options.first?.id ?? "" }
        selectedDate = max(dateRange.lowerBound, min(selectedDate, dateRange.upperBound))
    }
}

private extension CashFlowEvent.Kind {
    var label: LocalizedStringKey {
        switch self {
        case .grossEstimate: return "給与予測・控除前"
        case .expectedTakeHome: return "見込み手取り・入力値"
        case .actualIncome: return "受取実績"
        case .expense: return "登録済み支出"
        case .recurringExpense: return "定期支出の予定"
        }
    }
}

private func planningAmount(_ text: String, allowNegative: Bool = false) -> Double? {
    let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Double(cleaned), value.isFinite, abs(value) <= 1_000_000_000_000,
          allowNegative || value >= 0 else { return nil }
    return value
}

private func planningDate(_ text: String) -> Date? {
    guard let (y, m, d) = DateUtils.parseYMD(text) else { return nil }
    return DateUtils.date(year: y, month: m, day: d)
}
