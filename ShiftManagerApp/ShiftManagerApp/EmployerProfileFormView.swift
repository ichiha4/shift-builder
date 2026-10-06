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
    @FocusState private var nameFieldFocused: Bool

    init(existing: EmployerProfile?, prefillName: String = "") {
        self.existing = existing
        self.hadPrefillName = existing == nil && !prefillName.isEmpty
        if let p = existing {
            _name = State(initialValue: p.name)
            _scheduledHoursText = State(initialValue: Self.trimmed(p.scheduledHours))
            _defaultWageText = State(initialValue: p.defaultWage > 0 ? String(Int(p.defaultWage)) : "")
            _defaultTransportText = State(initialValue: p.defaultTransport > 0 ? String(Int(p.defaultTransport)) : "")
            _otherAllowanceText = State(initialValue: p.otherAllowance > 0 ? String(Int(p.otherAllowance)) : "")
            _closingDay = State(initialValue: p.closingDay)
            _paydayMonthOffset = State(initialValue: p.paydayMonthOffset)
            _paydayDay = State(initialValue: p.paydayDay)
            _paydayAdjustment = State(initialValue: p.paydayAdjustment)
            _lateNightPercentText = State(initialValue: String(Int((p.lateNightRate * 100).rounded())))
            _overtimePercentText = State(initialValue: String(Int((p.overtimeRate * 100).rounded())))
            _holidayPercentText = State(initialValue: String(Int((p.holidayRate * 100).rounded())))
            _employmentType = State(initialValue: p.employmentType)
            _incomeTaxColumn = State(initialValue: p.incomeTaxColumn)
            _dependentsCount = State(initialValue: p.dependentsCount)
            _hasSpouseAllowance = State(initialValue: p.hasSpouseAllowance)
        } else {
            _name = State(initialValue: prefillName)
            _scheduledHoursText = State(initialValue: "8")
            _defaultWageText = State(initialValue: "")
            _defaultTransportText = State(initialValue: "")
            _otherAllowanceText = State(initialValue: "")
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
            defaultWage: Double(defaultWageText) ?? 0,
            defaultTransport: Double(defaultTransportText) ?? 0,
            otherAllowance: Double(otherAllowanceText) ?? 0,
            closingDay: closingDay,
            paydayMonthOffset: paydayMonthOffset,
            paydayDay: paydayDay,
            paydayAdjustment: paydayAdjustment,
            lateNightRate: (Double(lateNightPercentText) ?? 25) / 100,
            overtimeRate: (Double(overtimePercentText) ?? 25) / 100,
            holidayRate: (Double(holidayPercentText) ?? 35) / 100,
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
                        .autocorrectionDisabled()
                        .focused($nameFieldFocused)
                    Picker("雇用形態", selection: $employmentType) {
                        ForEach(PayrollConstants.employmentTypes, id: \.self) { Text(LocalizedStringKey($0)) }
                    }
                }

                Section {
                    LabeledContent("所定労働時間(h/日)") {
                        TextField("8", text: $scheduledHoursText).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("時給(円)") {
                        TextField("未設定", text: $defaultWageText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("交通費(円)") {
                        TextField("0", text: $defaultTransportText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                    LabeledContent("その他手当(円)") {
                        TextField("0", text: $otherAllowanceText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("この勤務先のデフォルト値")
                } footer: {
                    Text("シフト追加時にこの勤務先名を入力すると、ここで設定した値が自動的に入ります。")
                }

                Section {
                    Picker("税額表の区分", selection: $incomeTaxColumn) {
                        Text("甲欄(メインの勤務先)").tag(IncomeTaxColumn.kou)
                        Text("乙欄(掛け持ち先)").tag(IncomeTaxColumn.otsu)
                    }
                    if incomeTaxColumn == .kou {
                        Toggle("源泉控除対象配偶者がいる", isOn: $hasSpouseAllowance)
                        Stepper("扶養親族等の数(配偶者を除く): \(dependentsCount)人", value: $dependentsCount, in: 0...10)
                    }
                } header: {
                    Text("所得税(源泉徴収)")
                } footer: {
                    if incomeTaxColumn == .kou {
                        Text("「給与所得者の扶養控除等申告書」を提出している勤務先(通常はメインの1箇所だけ)は甲欄です。申告書に書いた内容に合わせて入力してください。源泉控除対象配偶者は、あなたの所得が900万円以下で、配偶者の所得の見積額が95万円以下の場合です。扶養親族等の数に16歳未満の子は含めません。あなた自身が障害者・寡婦・ひとり親・勤労学生に当たる場合はそれぞれ1人を加え、申告書に障害者として書いた配偶者や扶養親族(16歳未満を含む)がいる場合は1人につき1人(同居特別障害者は2人)を加えます。迷ったら給与明細の扶養人数に合わせてください。")
                    } else {
                        Text("2つ以上掛け持ちしている場合、メイン以外は乙欄になります。乙欄は甲欄より税額が高く、扶養人数は反映されません。(「従たる給与についての扶養控除等申告書」を出している場合の減額には対応していません)")
                    }
                }

                Section("割増率") {
                    LabeledContent("深夜割増率(%)") { TextField("25", text: $lateNightPercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    LabeledContent("残業割増率(%)") { TextField("25", text: $overtimePercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    LabeledContent("法定休日割増率(%)") { TextField("35", text: $holidayPercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
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
                    Picker("支給日", selection: $paydayDay) {
                        Text("末日").tag(0)
                        ForEach(1...31, id: \.self) { Text("\($0)日").tag($0) }
                    }
                    Picker("支給日が土日祝・年末年始の場合", selection: $paydayAdjustment) {
                        Text("前営業日に繰り上げ").tag(PaydayAdjustment.beforeBusinessDay)
                        Text("翌営業日に繰り下げ").tag(PaydayAdjustment.afterBusinessDay)
                        Text("調整しない").tag(PaydayAdjustment.none)
                    }
                } header: {
                    Text("給与の締め日・支給日")
                } footer: {
                    Text("給与タブの「給与の支給予定」と年収の壁の計算に使われます。多くの会社は繰り上げ(前倒し)払いです。年末年始(12月31日〜1月3日)は銀行が休みのため、営業日に含めていません。")
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
              [defaultWageText, defaultTransportText, otherAllowanceText, lateNightPercentText, overtimePercentText, holidayPercentText].allSatisfy({ text in
                  guard let value = Double(text) else { return false }; return value.isFinite && value >= 0
              }) else {
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
