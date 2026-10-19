import SwiftUI

struct ShiftFormView: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var date: String
    let existing: Shift?
    let isTemplate: Bool
    let existingTemplate: ShiftTemplate?
    let onTemplateSaved: ((ShiftTemplate) -> Void)?

    @State private var employer: String
    @State private var segments: [SegmentDraft]
    @State private var breakEnabled: Bool
    @State private var breakStart: Date
    @State private var breakEnd: Date
    @State private var transportText: String
    @State private var otherAllowanceText: String
    @State private var isStatutoryHoliday: Bool
    @State private var scheduledHoursText: String
    @State private var lateNightPercentText: String
    @State private var overtimePercentText: String
    @State private var holidayPercentText: String
    @State private var showAdvanced = false
    @State private var showEmployerProfileSheet = false
    @State private var untimedBreakText: String = "0"
    @State private var errors: [String] = []
    @State private var overlapRequest: ShiftSaveRequest?
    @FocusState private var employerFieldFocused: Bool

    struct SegmentDraft: Identifiable {
        let id = UUID()
        var start: Date
        var end: Date
        var wageText: String
    }

    init(date: String, existing: Shift?, isTemplate: Bool = false, existingTemplate: ShiftTemplate? = nil, onTemplateSaved: ((ShiftTemplate) -> Void)? = nil) {
        _date = State(initialValue: date)
        self.existing = existing
        self.isTemplate = isTemplate
        self.existingTemplate = existingTemplate
        self.onTemplateSaved = onTemplateSaved
        if let s = existing {
            _employer = State(initialValue: s.employer)
            _segments = State(initialValue: s.segments.map {
                SegmentDraft(start: dateFromMinutes($0.startMinute), end: dateFromMinutes($0.endMinute), wageText: FormNumber.text($0.hourlyWage))
            })
            _breakEnabled = State(initialValue: s.breakStartMinute != nil)
            _untimedBreakText = State(initialValue: String(s.breakMinutes))
            _breakStart = State(initialValue: dateFromMinutes(s.breakStartMinute ?? 12 * 60))
            _breakEnd = State(initialValue: dateFromMinutes((s.breakStartMinute ?? 12 * 60) + s.breakMinutes))
            _transportText = State(initialValue: FormNumber.text(s.transport))
            _otherAllowanceText = State(initialValue: FormNumber.text(s.otherAllowance))
            _isStatutoryHoliday = State(initialValue: s.isStatutoryHoliday)
            _scheduledHoursText = State(initialValue: trimmedHours(s.scheduledMinutes))
            _lateNightPercentText = State(initialValue: FormNumber.percentageText(s.lateNightRate))
            _overtimePercentText = State(initialValue: FormNumber.percentageText(s.overtimeRate))
            _holidayPercentText = State(initialValue: FormNumber.percentageText(s.holidayRate))
        } else {
            _employer = State(initialValue: "")
            _segments = State(initialValue: [SegmentDraft(start: dateFromMinutes(9 * 60), end: dateFromMinutes(17 * 60), wageText: "1200")])
            _breakEnabled = State(initialValue: false)
            _breakStart = State(initialValue: dateFromMinutes(12 * 60))
            _breakEnd = State(initialValue: dateFromMinutes(13 * 60))
            _transportText = State(initialValue: "0")
            _otherAllowanceText = State(initialValue: "0")
            _isStatutoryHoliday = State(initialValue: false)
            _scheduledHoursText = State(initialValue: "8")
            _lateNightPercentText = State(initialValue: "25")
            _overtimePercentText = State(initialValue: "25")
            _holidayPercentText = State(initialValue: "35")
        }
    }

    private var workSegments: [WorkSegment] {
        segments.map { WorkSegment(startMinute: $0.start.minutesSinceMidnight, endMinute: $0.end.minutesSinceMidnight, hourlyWage: Double($0.wageText) ?? 0) }
    }
    private var breakMinutes: Int {
        breakEnabled ? Validation.breakDurationMinutes(start: breakStart.minutesSinceMidnight, end: breakEnd.minutesSinceMidnight) : max(0, Int(untimedBreakText) ?? 0)
    }
    private var draftShift: Shift {
        Shift(
            id: existing?.id ?? UUID().uuidString,
            date: date, employer: employer.trimmingCharacters(in: .whitespacesAndNewlines), segments: workSegments,
            breakMinutes: breakMinutes, breakStartMinute: breakEnabled ? breakStart.minutesSinceMidnight : nil,
            transport: FormNumber.nonnegative(transportText, allowEmpty: true) ?? 0,
            otherAllowance: FormNumber.nonnegative(otherAllowanceText, allowEmpty: true) ?? 0,
            isStatutoryHoliday: isStatutoryHoliday,
            scheduledMinutes: Validation.scheduledMinutes(hours: Double(scheduledHoursText) ?? 8),
            lateNightRate: (FormNumber.nonnegative(lateNightPercentText) ?? 25) / 100,
            overtimeRate: (FormNumber.nonnegative(overtimePercentText) ?? 25) / 100,
            holidayRate: (FormNumber.nonnegative(holidayPercentText) ?? 35) / 100
        )
    }
    private var preview: ShiftPayEstimate { PayCalculation.estimateShiftPay(draftShift, allShifts: isTemplate ? [] : store.shifts) }

    private var matchingProfile: EmployerProfile? {
        let trimmed = employer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return store.employerProfiles.first { $0.name == trimmed }
    }

    private var employerChoices: [ShiftEmployerChoice] {
        ShiftEmployerChoice.available(profiles: store.employerProfiles,
                                      shifts: store.shifts + store.undoableDeletedShifts + store.shiftTemplates.map(\.pattern))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if !isTemplate {
                    DatePicker("日付", selection: Binding(
                        get: {
                            guard let parts = DateUtils.parseYMD(date) else { return Date() }
                            return DateUtils.date(year: parts.year, month: parts.month, day: parts.day)
                        },
                        set: { date = DateUtils.ymd($0) }
                    ), displayedComponents: .date)
                    .environment(\.calendar, DateUtils.calendar)
                    }
                    employerField
                    if !employer.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button {
                            showEmployerProfileSheet = true
                        } label: {
                            Label(
                                matchingProfile == nil ? "給料日を設定" : "給料日を編集",
                                systemImage: "calendar.badge.clock"
                            )
                        }
                    }
                } header: {
                    Text("勤務先")
                } footer: {
                    if isTemplate, existing != nil {
                        Text("変更はテンプレートだけに反映されます。登録済みのシフトは変わりません。")
                    }
                    if matchingProfile == nil, !employer.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("設定すると、ホームと給与タブにこの勤務先の支給予定が表示されます。")
                    }
                }

                Section("勤務時間") {
                    ForEach($segments) { $seg in
                        segmentRow($seg)
                    }
                    .onDelete { segments.remove(atOffsets: $0) }
                    Button {
                        let last = segments.last
                        segments.append(SegmentDraft(start: last?.end ?? dateFromMinutes(17 * 60), end: dateFromMinutes(22 * 60), wageText: last?.wageText ?? "1200"))
                    } label: {
                        Label("時間帯を追加(時給が変わる場合)", systemImage: "plus.circle")
                    }
                }

                Section("休憩") {
                    Toggle("休憩時間を指定する", isOn: $breakEnabled.animation())
                    if breakEnabled {
                        DatePicker("開始", selection: $breakStart, displayedComponents: .hourAndMinute)
                        DatePicker("終了", selection: $breakEnd, displayedComponents: .hourAndMinute)
                        LabeledContent("休憩時間", value: "\(breakMinutes)分")
                    } else {
                        LabeledContent("休憩時間(分)") {
                            TextField("0", text: $untimedBreakText).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                        Text("開始時刻を指定しない場合、休憩中の時給・深夜割増は概算です。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("詳細設定(今回だけ変更)", isExpanded: $showAdvanced) {
                        LabeledContent("交通費(円)") { TextField("0", text: $transportText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        LabeledContent("その他手当(円)") { TextField("0", text: $otherAllowanceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        if !isTemplate {
                            Toggle("この日は法定休日として計算する", isOn: $isStatutoryHoliday)
                        }
                        LabeledContent("所定労働時間(h)") { TextField("8", text: $scheduledHoursText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        LabeledContent("深夜割増率(%)") { TextField("25", text: $lateNightPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        LabeledContent("残業割増率(%)") { TextField("25", text: $overtimePercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        LabeledContent("法定休日割増率(%)") { TextField("35", text: $holidayPercentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    }
                }

                Section(isTemplate ? "テンプレートの給与目安（控除前）" : "このシフトの給与見込み（控除前）") {
                    LabeledContent("合計(\(String(format: "%.1f", Double(preview.netMinutes) / 60))時間)") {
                        Text(yen(preview.netPay)).font(.headline).foregroundStyle(.green)
                    }
                    if let hint = Validation.breakHint(netMinutes: preview.netMinutes) {
                        Label(hint, systemImage: "info.circle").font(.caption).foregroundStyle(.orange)
                    }
                    ForEach(Validation.detectShiftAnomalies(preview), id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
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
            .navigationTitle(isTemplate ? (existing == nil ? "テンプレートを作成" : "テンプレートを編集") : (existing == nil ? "シフトを追加" : "シフトを編集"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isTemplate ? "保存" : (existing == nil ? "追加" : "更新")) { save() }
                }
            }
            .alert("勤務時間が重なっています", isPresented: Binding(
                get: { overlapRequest != nil },
                set: { if !$0 { overlapRequest = nil } }
            ), presenting: overlapRequest) { request in
                Button("キャンセル", role: .cancel) { overlapRequest = nil }
                Button(request.isEditing ? "更新する" : "追加する") {
                    overlapRequest = nil
                    finishSaving(request, confirmingOverlap: true)
                }
            } message: { request in
                Text(shiftOverlapMessage(for: request, locale: locale))
            }
            .onChange(of: store.cloudDataReady) { _, ready in
                if !ready { overlapRequest = nil }
            }
            .onChange(of: employer) { _, newValue in applyProfileDefaultsIfNeeded(for: newValue) }
            .onAppear {
                if existing == nil && employer.isEmpty && employerChoices.isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { employerFieldFocused = true }
                }
            }
            .sheet(isPresented: $showEmployerProfileSheet, onDismiss: {
                applyProfileDefaultsIfNeeded(for: employer)
            }) {
                EmployerProfileFormView(existing: matchingProfile, prefillName: employer.trimmingCharacters(in: .whitespaces))
                    .environmentObject(store)
            }
        }
    }

    private var employerField: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("例:カフェ○○", text: $employer)
                .autocorrectionDisabled().focused($employerFieldFocused)
                .accessibilityLabel("勤務先名")
            if existing == nil && !employerChoices.isEmpty {
                Menu {
                    ForEach(employerChoices) { choice in
                        Button(choice.name) { selectEmployer(choice) }
                    }
                } label: {
                    Label("勤務先から選ぶ", systemImage: "building.2")
                        .font(.subheadline)
                }
            }
        }
    }

    private func selectEmployer(_ choice: ShiftEmployerChoice) {
        employer = choice.name
        employerFieldFocused = false
        if choice.profile != nil {
            applyProfileDefaultsIfNeeded(for: choice.name, replaceWage: true)
        } else if let source = choice.latestShift {
            for index in segments.indices {
                segments[index].wageText = choice.suggestedHourlyWage.map(FormNumber.text) ?? ""
            }
            transportText = FormNumber.text(source.transport)
            otherAllowanceText = FormNumber.text(source.otherAllowance)
            scheduledHoursText = trimmedHours(source.scheduledMinutes)
            lateNightPercentText = FormNumber.percentageText(source.lateNightRate)
            overtimePercentText = FormNumber.percentageText(source.overtimeRate)
            holidayPercentText = FormNumber.percentageText(source.holidayRate)
        }
    }

    private func segmentRow(_ seg: Binding<SegmentDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                DatePicker("", selection: seg.start, displayedComponents: .hourAndMinute).labelsHidden()
                Text("〜")
                DatePicker("", selection: seg.end, displayedComponents: .hourAndMinute).labelsHidden()
                Spacer()
            }
            HStack {
                Text("時給")
                TextField("時給", text: seg.wageText).keyboardType(.decimalPad)
                Text("円")
            }
        }
    }

    /// Only prefills for a NEW shift, and only on an exact name match — never overwrites a
    /// value someone is actively editing on an existing shift.
    private func applyProfileDefaultsIfNeeded(for name: String, replaceWage: Bool = false) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existing == nil, let profile = store.employerProfiles.first(where: { $0.name == name }) else { return }
        if replaceWage {
            for index in segments.indices {
                segments[index].wageText = profile.defaultWage > 0 ? FormNumber.text(profile.defaultWage) : ""
            }
        } else if segments.count == 1, segments[0].wageText.isEmpty || segments[0].wageText == "1200", profile.defaultWage > 0 {
            segments[0].wageText = FormNumber.text(profile.defaultWage)
        }
        if replaceWage || profile.defaultTransport > 0 { transportText = FormNumber.text(profile.defaultTransport) }
        if replaceWage || profile.otherAllowance > 0 { otherAllowanceText = FormNumber.text(profile.otherAllowance) }
        scheduledHoursText = trimmedHours(profile.scheduledMinutes)
        lateNightPercentText = FormNumber.percentageText(profile.lateNightRate)
        overtimePercentText = FormNumber.percentageText(profile.overtimeRate)
        holidayPercentText = FormNumber.percentageText(profile.holidayRate)
    }

    private func save() {
        guard !employer.trimmingCharacters(in: .whitespaces).isEmpty else {
            errors = ["勤務先を入力してください"]
            return
        }
        guard let hours = Double(scheduledHoursText), hours.isFinite, (0...24).contains(hours),
              [transportText, otherAllowanceText].allSatisfy({ FormNumber.nonnegative($0, allowEmpty: true) != nil }),
              [lateNightPercentText, overtimePercentText, holidayPercentText].allSatisfy({ FormNumber.nonnegative($0) != nil }),
              breakEnabled || (Int(untimedBreakText).map { $0 >= 0 } ?? false) else {
            errors = ["数値を正しく入力してください。所定労働時間は0〜24時間です。"]
            return
        }
        let candidate = draftShift
        errors = []
        if isTemplate {
            let validationErrors = Validation.validateShift(candidate, existing: [])
            guard validationErrors.isEmpty else { errors = validationErrors; return }
            let template = ShiftTemplate(id: existingTemplate?.id ?? UUID().uuidString, pattern: candidate)
            if let original = existingTemplate {
                guard store.shiftTemplates.contains(original) else {
                    errors = ["テンプレートの内容が変わりました。開き直して確認してください。"]
                    return
                }
                guard !store.shiftTemplates.contains(where: { $0.id != original.id && $0.fingerprint == template.fingerprint }) else {
                    errors = ["同じ内容のテンプレートが既にあります。"]
                    return
                }
            }
            let saved = existingTemplate.map { store.updateShiftTemplate($0, pattern: candidate) } ?? store.saveShiftTemplate(template)
            guard saved else {
                errors = ["同期の状態を確認して、もう一度お試しください。"]
                return
            }
            onTemplateSaved?(template)
            dismiss()
            return
        }
        do {
            let request = try store.prepareShiftSave(candidate, editing: existing != nil)
            if request.requiresOverlapConfirmation { overlapRequest = request }
            else { finishSaving(request) }
        } catch {
            errors = [error.localizedDescription]
        }
    }

    private func finishSaving(_ request: ShiftSaveRequest, confirmingOverlap: Bool = false) {
        do {
            try store.saveReviewedShift(request, confirmingOverlap: confirmingOverlap)
        } catch {
            errors = [error.localizedDescription]
            return
        }
        let candidate = request.shift
        if request.isEditing {
            notifications.log(kind: .updated, title: "シフトを更新しました", message: "\(candidate.employer)・\(DateUtils.formatFullDate(candidate.date))")
        } else {
            notifications.log(kind: .added, title: "シフトを追加しました", message: "\(candidate.employer)・\(DateUtils.formatFullDate(candidate.date))")
        }
        NotificationScheduler.requestAuthorizationIfNeeded()
        NotificationScheduler.scheduleReminder(for: candidate)
        dismiss()
    }
}

/// Describe the exact candidate and conflicts captured before the user accepts.
func shiftOverlapMessage(for request: ShiftSaveRequest, locale: Locale) -> String {
    func summary(_ shift: Shift) -> String {
        let times = shift.segments.map {
            "\(ClockUtils.formatClock($0.startMinute))–\(ClockUtils.formatClock($0.endMinute))"
        }.joined(separator: " / ")
        return "\(DateUtils.formatFullDate(shift.date, locale: locale))\n\(shift.employer)  \(times)"
    }
    let prompt = NSLocalizedString(request.isEditing
        ? "登録済みのシフトと勤務時間が重なっています。この内容で更新しますか？"
        : "登録済みのシフトと勤務時間が重なっています。追加しますか？", comment: "")
    var conflicts = request.overlappingShifts.prefix(3).map(summary).joined(separator: "\n")
    if request.overlappingShifts.count > 3 {
        conflicts += "\n" + String(format: NSLocalizedString("ほか%lld件", comment: ""), Int64(request.overlappingShifts.count - 3))
    }
    return [prompt, summary(request.shift),
            NSLocalizedString("重なっているシフト", comment: "") + "\n" + conflicts,
            NSLocalizedString("重なった勤務も給与予定に含まれます。", comment: "")].joined(separator: "\n\n")
}

private func trimmedHours(_ minutes: Int) -> String {
    let hours = Double(minutes) / 60
    return hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(hours)
}
