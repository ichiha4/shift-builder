import SwiftUI

struct ShiftFormView: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let date: String
    let existing: Shift?

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
    @FocusState private var employerFieldFocused: Bool

    struct SegmentDraft: Identifiable {
        let id = UUID()
        var start: Date
        var end: Date
        var wageText: String
    }

    init(date: String, existing: Shift?) {
        self.date = date
        self.existing = existing
        if let s = existing {
            _employer = State(initialValue: s.employer)
            _segments = State(initialValue: s.segments.map {
                SegmentDraft(start: dateFromMinutes($0.startMinute), end: dateFromMinutes($0.endMinute), wageText: String(Int($0.hourlyWage)))
            })
            _breakEnabled = State(initialValue: s.breakStartMinute != nil)
            _untimedBreakText = State(initialValue: String(s.breakMinutes))
            _breakStart = State(initialValue: dateFromMinutes(s.breakStartMinute ?? 12 * 60))
            _breakEnd = State(initialValue: dateFromMinutes((s.breakStartMinute ?? 12 * 60) + s.breakMinutes))
            _transportText = State(initialValue: String(Int(s.transport)))
            _otherAllowanceText = State(initialValue: String(Int(s.otherAllowance)))
            _isStatutoryHoliday = State(initialValue: s.isStatutoryHoliday)
            _scheduledHoursText = State(initialValue: trimmedHours(s.scheduledMinutes))
            _lateNightPercentText = State(initialValue: String(Int((s.lateNightRate * 100).rounded())))
            _overtimePercentText = State(initialValue: String(Int((s.overtimeRate * 100).rounded())))
            _holidayPercentText = State(initialValue: String(Int((s.holidayRate * 100).rounded())))
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
            transport: Double(transportText) ?? 0, otherAllowance: Double(otherAllowanceText) ?? 0,
            isStatutoryHoliday: isStatutoryHoliday,
            scheduledMinutes: Validation.scheduledMinutes(hours: Double(scheduledHoursText) ?? 8),
            lateNightRate: (Double(lateNightPercentText) ?? 25) / 100,
            overtimeRate: (Double(overtimePercentText) ?? 25) / 100,
            holidayRate: (Double(holidayPercentText) ?? 35) / 100
        )
    }
    private var preview: ShiftPayEstimate { PayCalculation.estimateShiftPay(draftShift, allShifts: store.shifts) }

    private var matchingProfile: EmployerProfile? {
        let trimmed = employer.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return store.employerProfiles.first { $0.name == trimmed }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("日付", value: DateUtils.formatFullDate(date, locale: locale))
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
                    if matchingProfile == nil, !employer.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("設定すると、給与タブにこの勤務先の支給予定が表示されるようになります。")
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

                Section("手当") {
                    LabeledContent("交通費(円)") { TextField("0", text: $transportText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    LabeledContent("その他手当(円)") { TextField("0", text: $otherAllowanceText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    Toggle("この日は法定休日として計算する", isOn: $isStatutoryHoliday)
                }

                Section {
                    DisclosureGroup("詳細設定(今回だけ変更)", isExpanded: $showAdvanced) {
                        LabeledContent("所定労働時間(h)") { TextField("8", text: $scheduledHoursText).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        LabeledContent("深夜割増率(%)") { TextField("25", text: $lateNightPercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                        LabeledContent("残業割増率(%)") { TextField("25", text: $overtimePercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                        LabeledContent("法定休日割増率(%)") { TextField("35", text: $holidayPercentText).keyboardType(.numberPad).multilineTextAlignment(.trailing) }
                    }
                }

                Section("今回の給与予測") {
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
            .navigationTitle(existing == nil ? "シフトを追加" : "シフトを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "追加" : "更新") { save() }
                }
            }
            .onChange(of: employer) { _, newValue in applyProfileDefaultsIfNeeded(for: newValue) }
            .onAppear {
                if existing == nil {
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
        TextField("例:カフェ○○", text: $employer)
            .autocorrectionDisabled()
            .focused($employerFieldFocused)
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
                TextField("時給", text: seg.wageText).keyboardType(.numberPad)
                Text("円")
            }
        }
    }

    /// Only prefills for a NEW shift, and only on an exact name match — never overwrites a
    /// value someone is actively editing on an existing shift.
    private func applyProfileDefaultsIfNeeded(for name: String) {
        guard existing == nil, let profile = store.employerProfiles.first(where: { $0.name == name }) else { return }
        if segments.count == 1, segments[0].wageText.isEmpty || segments[0].wageText == "1200", profile.defaultWage > 0 {
            segments[0].wageText = String(Int(profile.defaultWage))
        }
        if profile.defaultTransport > 0 { transportText = String(Int(profile.defaultTransport)) }
        if profile.otherAllowance > 0 { otherAllowanceText = String(Int(profile.otherAllowance)) }
        scheduledHoursText = trimmedHours(profile.scheduledMinutes)
        lateNightPercentText = String(Int((profile.lateNightRate * 100).rounded()))
        overtimePercentText = String(Int((profile.overtimeRate * 100).rounded()))
        holidayPercentText = String(Int((profile.holidayRate * 100).rounded()))
    }

    private func save() {
        guard !employer.trimmingCharacters(in: .whitespaces).isEmpty else {
            errors = ["勤務先を入力してください"]
            return
        }
        guard let hours = Double(scheduledHoursText), hours.isFinite, (0...24).contains(hours),
              [transportText, otherAllowanceText, lateNightPercentText, overtimePercentText, holidayPercentText].allSatisfy({ text in
                  guard let value = Double(text) else { return false }; return value.isFinite && value >= 0
              }), breakEnabled || (Int(untimedBreakText).map { $0 >= 0 } ?? false) else {
            errors = ["数値を正しく入力してください。所定労働時間は0〜24時間です。"]
            return
        }
        let validationErrors = Validation.validateShift(
            segments: workSegments, breakMinutes: breakMinutes, breakStartMinute: breakEnabled ? breakStart.minutesSinceMidnight : nil,
            lateNightRate: draftShift.lateNightRate, overtimeRate: draftShift.overtimeRate, holidayRate: draftShift.holidayRate
        )
        guard validationErrors.isEmpty else {
            errors = validationErrors
            return
        }
        if existing != nil {
            store.updateShift(draftShift)
            notifications.log(kind: .updated, title: "シフトを更新しました", message: "\(draftShift.employer)・\(DateUtils.formatFullDate(draftShift.date))")
        } else {
            store.addShift(draftShift)
            notifications.log(kind: .added, title: "シフトを追加しました", message: "\(draftShift.employer)・\(DateUtils.formatFullDate(draftShift.date))")
        }
        NotificationScheduler.requestAuthorizationIfNeeded()
        NotificationScheduler.scheduleReminder(for: draftShift)
        dismiss()
    }
}

private func trimmedHours(_ minutes: Int) -> String {
    let hours = Double(minutes) / 60
    return hours.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(hours)) : String(hours)
}
