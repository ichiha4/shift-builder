import SwiftUI

/// Add/edit sheet for a saved employer profile. Values here become defaults that
/// `ShiftFormView.applyProfileDefaultsIfNeeded` fills in when a new shift's employer name
/// matches — and, once any profile exists, drive the Wage tab's 給与の支給予定 card.
struct EmployerProfileFormView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss

    let existing: EmployerProfile?
    private let hadPrefillName: Bool

    @State private var name: String
    @State private var scheduledHoursText: String
    @State private var defaultWageText: String
    @State private var defaultTransportText: String
    @State private var otherAllowanceText: String
    @State private var closingDay: Int
    @State private var paydayMonthOffset: Int
    @State private var paydayDay: Int
    @State private var paydayAdjustment: PaydayAdjustment
    @State private var lateNightPercentText: String
    @State private var overtimePercentText: String
    @State private var holidayPercentText: String
    @State private var employmentType: String
    @State private var incomeTaxColumn: IncomeTaxColumn
    @State private var dependentsCount: Int
    @State private var hasSpouseAllowance: Bool
    @State private var errors: [String] = []
    @State private var showAdvanced = false
    @FocusState private var nameFieldFocused: Bool

    init(existing: EmployerProfile?, prefillName: String = "") {
        self.existing = existing
        self.hadPrefillName = existing == nil && !prefillName.isEmpty
        if let p = existing {
            _name = State(initialValue: p.name)
            _scheduledHoursText = State(initialValue: Self.trimmed(p.scheduledHours))
            _defaultWageText = State(initialValue: p.defaultWage > 0 ? FormNumber.text(p.defaultWage) : "")
            _defaultTransportText = State(initialValue: FormNumber.text(p.defaultTransport))
            _otherAllowanceText = State(initialValue: FormNumber.text(p.otherAllowance))
            _closingDay = State(initialValue: p.closingDay)
            _paydayMonthOffset = State(initialValue: p.paydayMonthOffset)
            _paydayDay = State(initialValue: p.paydayDay)
            _paydayAdjustment = State(initialValue: p.paydayAdjustment)
            _lateNightPercentText = State(initialValue: FormNumber.percentageText(p.lateNightRate))
            _overtimePercentText = State(initialValue: FormNumber.percentageText(p.overtimeRate))
            _holidayPercentText = State(initialValue: FormNumber.percentageText(p.holidayRate))
            _employmentType = State(initialValue: p.employmentType)
            _incomeTaxColumn = State(initialValue: p.incomeTaxColumn)
            _dependentsCount = State(initialValue: p.dependentsCount)
            _hasSpouseAllowance = State(initialValue: p.hasSpouseAllowance)
        } else {
            _name = State(initialValue: prefillName)
            _scheduledHoursText = State(initialValue: "8")
            _defaultWageText = State(initialValue: "")
            _defaultTransportText = State(initialValue: "0")
            _otherAllowanceText = State(initialValue: "0")
            _closingDay = State(initialValue: 0)
            _paydayMonthOffset = State(initialValue: 1)
            _paydayDay = State(initialValue: 25)
            _paydayAdjustment = State(initialValue: .beforeBusinessDay)
            _lateNightPercentText = State(initialValue: "25")
            _overtimePercentText = State(initialValue: "25")
            _holidayPercentText = State(initialValue: "35")
            _employmentType = State(initialValue: PayrollConstants.employmentTypes[0])
            _incomeTaxColumn = State(initialValue: .kou)
            _dependentsCount = State(initialValue: 0)
            _hasSpouseAllowance = State(initialValue: false)
        }
    }

    private var draft: EmployerProfile {
        EmployerProfile(
            id: existing?.id ?? UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespaces),
            scheduledHours: Double(scheduledHoursText) ?? 8,
            defaultWage: FormNumber.nonnegative(defaultWageText, allowEmpty: true) ?? 0,
            defaultTransport: FormNumber.nonnegative(defaultTransportText, allowEmpty: true) ?? 0,
            otherAllowance: FormNumber.nonnegative(otherAllowanceText, allowEmpty: true) ?? 0,
            closingDay: closingDay,
            paydayMonthOffset: paydayMonthOffset,
            paydayDay: paydayDay,
            paydayAdjustment: paydayAdjustment,
            lateNightRate: (FormNumber.nonnegative(lateNightPercentText) ?? 25) / 100,
            overtimeRate: (FormNumber.nonnegative(overtimePercentText) ?? 25) / 100,
            holidayRate: (FormNumber.nonnegative(holidayPercentText) ?? 35) / 100,
            employmentType: employmentType,
            incomeTaxColumn: incomeTaxColumn,
            dependentsCount: dependentsCount,
            hasSpouseAllowance: hasSpouseAllowance
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("勤務先") {
                    TextField("例:カフェ○○", text: $name)
                        .autocorrectionDisabled().focused($nameFieldFocused)
                        .accessibilityLabel("勤務先名")
                    LabeledContent("時給(円)") {
                        TextField("例:1200", text: $defaultWageText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .accessibilityLabel("時給")
                    }
                }
                Section {
                    Picker("締め日", selection: $closingDay) {
                        Text("末日").tag(0)
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    Picker("支給月", selection: $paydayMonthOffset) {
                        Text("締め日と同じ月").tag(0)
                        Text("翌月").tag(1)
                        Text("翌々月").tag(2)
                    }
                    Picker("給料日", selection: $paydayDay) {
                        Text("末日").tag(0)
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                } header: { Text("給料日") }
                footer: { Text("勤務先の給料日に合わせて設定してください。") }

                Section {
                    DisclosureGroup("手当・割増などの詳細設定", isExpanded: $showAdvanced) {
                        Picker("雇用形態", selection: $employmentType) {
                            ForEach(PayrollConstants.employmentTypes, id: \.self) { Text(LocalizedStringKey($0)) }
                        }
                        LabeledContent("所定労働時間(h/日)") {
                            TextField("8", text: $scheduledHoursText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("交通費(円)") {
                            TextField("0", text: $defaultTransportText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("その他手当(円)") {
                            TextField("0", text: $otherAllowanceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("深夜割増率(%)") {
                            TextField("25", text: $lateNightPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("残業割増率(%)") {
                            TextField("25", text: $overtimePercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        LabeledContent("法定休日割増率(%)") {
                            TextField("35", text: $holidayPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                        }
                        Picker("給料日が休日のとき", selection: $paydayAdjustment) {
                            Text("前営業日に繰り上げ").tag(PaydayAdjustment.beforeBusinessDay)
                            Text("翌営業日に繰り下げ").tag(PaydayAdjustment.afterBusinessDay)
                            Text("調整しない").tag(PaydayAdjustment.none)
                        }
                        Picker("税額表の区分", selection: $incomeTaxColumn) {
                            Text("甲欄(メインの勤務先)").tag(IncomeTaxColumn.kou)
                            Text("乙欄(掛け持ち先)").tag(IncomeTaxColumn.otsu)
                        }
                        if incomeTaxColumn == .kou {
                            Toggle("源泉控除対象配偶者がいる", isOn: $hasSpouseAllowance)
                            Stepper("扶養親族等の数(配偶者を除く): \(dependentsCount)人", value: $dependentsCount, in: 0...10)
                        }
                        Text("税額表の区分や扶養人数は、勤務先の給与明細に合わせて確認できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                if !errors.isEmpty {
                    Section {
                        ForEach(errors, id: \.self) { e in
                            Text("・\(e)").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle(existing == nil ? "勤務先を追加" : "勤務先を編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "追加" : "更新") { save() }
                }
            }
            .onAppear {
                // Skip auto-focusing the name field when it arrived pre-filled (from
                // ShiftFormView's "給料日を設定" shortcut) — the user is here for the payday
                // section below, not to retype a name they already typed once.
                if existing == nil && !hadPrefillName {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { nameFieldFocused = true }
                }
            }
        }
    }

    private func save() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errors = ["勤務先名を入力してください"]
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !store.employerProfiles.contains(where: { $0.name == trimmedName && $0.id != existing?.id }) else {
            errors = ["同じ名前の勤務先が登録されています。別の名前を入力してください。"]
            return
        }
        guard let hours = Double(scheduledHoursText), hours.isFinite, (0...24).contains(hours),
              [defaultWageText, defaultTransportText, otherAllowanceText].allSatisfy({ FormNumber.nonnegative($0, allowEmpty: true) != nil }),
              [lateNightPercentText, overtimePercentText, holidayPercentText].allSatisfy({ FormNumber.nonnegative($0) != nil }) else {
            errors = ["数値を正しく入力してください。所定労働時間は0〜24時間です。"]
            return
        }
        errors = []
        NotificationScheduler.requestAuthorizationIfNeeded()
        store.saveEmployerProfile(draft)
        dismiss()
    }

    private static func trimmed(_ hours: Double) -> String {
        hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(hours)
    }
}

#Preview {
    EmployerProfileFormView(existing: nil).environmentObject(ShiftStore())
}
