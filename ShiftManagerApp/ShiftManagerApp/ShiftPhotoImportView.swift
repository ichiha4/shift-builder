import SwiftUI
import PhotosUI
import UIKit

struct ShiftPhotoImportView: View {
    @EnvironmentObject private var store: ShiftStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @EnvironmentObject private var notifications: NotificationLogStore
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable, Equatable {
        var candidate: ShiftImportCandidate
        var selected = true
        var breakText: String
        var id: Int { candidate.id }
    }
    @State private var monthText: String
    @State private var photo: PhotosPickerItem?
    @State private var recognized: RecognizedShiftText?
    @State private var rows: [Row]
    @State private var issues: [ShiftImportIssue] = []
    @State private var profileID = ""
    @State private var wageText = ""
    @State private var confirmed = false
    @State private var isReading = false
    @State private var isSaving = false
    @State private var error = ""
    @State private var result: ShiftImportPlan?
    @State private var showEmployerForm = false
    @State private var showPaywall = false
    @State private var readTask: Task<Void, Never>?
    @State private var generation = UUID()

    init(month: String, preview: RecognizedShiftText? = nil) {
        _monthText = State(initialValue: month)
        _recognized = State(initialValue: preview)
        let parsed = preview.flatMap { try? ShiftImportParser.parse(lines: $0.lines, month: month) }
        _rows = State(initialValue: (parsed?.candidates ?? []).map { Row(candidate: $0, breakText: String($0.breakMinutes)) })
        _issues = State(initialValue: parsed?.issues ?? [])
    }

    private var selectedProfile: EmployerProfile? { store.employerProfiles.first { $0.id == profileID } }
    private var selectedCount: Int { rows.filter(\.selected).count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let result { completion(result) }
                else {
                    if recognized == nil { intro }
                    sourcePicker
                    if let recognized {
                        if let image = UIImage(data: recognized.previewData) {
                            DisclosureGroup("元の画像を確認") {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
                                    .accessibilityLabel("選択したシフト画像")
                            }
                        }
                        monthInput
                        if !rows.isEmpty {
                            employerInput.disabled(isSaving)
                            reviewRows.disabled(isSaving)
                            confirmation.disabled(isSaving)
                            saveButton
                        }
                        else {
                            Text("登録候補が見つかりませんでした。日付と勤務時間が同じ行にある画像を選んでください。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        if !issues.isEmpty {
                            DisclosureGroup("候補にできなかった行（\(issues.count)件）") {
                                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(issue.source).font(.caption)
                                        Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                                    }.padding(.vertical, 5)
                                }
                            }
                        }
                        DisclosureGroup("読み取った文字を確認") {
                            Text(recognized.lines.joined(separator: "\n")).font(.caption).textSelection(.enabled)
                        }
                    }
                }
                if !error.isEmpty { Text(error).font(.subheadline).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
            }.padding(16).readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("写真からシフト登録")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() }.disabled(isSaving) }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            beginRead {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ShiftPhotoReadError.invalidImage }
                return data
            }
        }
        .onChange(of: profileID) { _, _ in
            wageText = selectedProfile.map { String($0.defaultWage) } ?? ""
            confirmed = false
        }
        .onChange(of: store.employerProfiles) { _, _ in selectDefaultProfile() }
        .onAppear { selectDefaultProfile() }
        .task { await subscriptions.refreshAccess() }
        .onDisappear {
            readTask?.cancel(); generation = UUID()
            recognized = nil; photo = nil; rows = []
        }
        .sheet(isPresented: $showEmployerForm) { EmployerProfileFormView(existing: nil).environmentObject(store) }
        .sheet(isPresented: $showPaywall) {
            NavigationStack { PlusPaywallView().toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showPaywall = false } }
            } }.environmentObject(subscriptions)
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("入力の手間を減らす", systemImage: "photo.badge.plus").font(.headline)
            Text("自分の予定だけが載った画像から、日付と勤務時間を読み取ります。")
                .font(.subheadline)
            Text("対応例：10/6 17:00–22:00。全員の横長の表や「早・遅」などの勤務記号には、まだ対応していません。")
                .font(.caption).foregroundStyle(.secondary)
            Text("画像は端末内で処理し、読み取りのために外部へ送信・保存しません。登録したシフトは通常どおり同期されます。")
                .font(.caption).foregroundStyle(.secondary)
        }.appCard()
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhotosPicker(selection: $photo, matching: .images) {
                Label("写真・スクリーンショットを選ぶ", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).disabled(isReading || isSaving)
            Button("サンプル画像で試す") { beginRead { ShiftPhotoSample.data() } }
                .buttonStyle(.bordered).disabled(isReading || isSaving)
            if isReading { ProgressView("文字を読み取っています") }
        }
    }

    private var monthInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("対象年月").font(.headline)
            TextField("2026-10", text: $monthText).textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled().accessibilityLabel("対象年月、YYYY-MM")
                .onChange(of: monthText) { _, _ in rows = []; confirmed = false }
            Text("年や月が画像にない場合、この年月を使います。").font(.caption).foregroundStyle(.secondary)
            Button("この年月で候補を作る") { parseRecognized() }.disabled(isReading)
        }.appCard()
    }

    private var employerInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("勤務先・給与設定").font(.headline)
            if !store.employerProfiles.isEmpty {
                Picker("勤務先", selection: $profileID) {
                    ForEach(store.employerProfiles) { profile in Text(profile.name).tag(profile.id) }
                }
                HStack {
                    Text("時給")
                    TextField("1200", text: $wageText).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("取り込むシフトの時給")
                        .onChange(of: wageText) { _, _ in confirmed = false }
                    Text("円")
                }
                Text("交通費・手当・割増は選んだ勤務先の設定を使います。時給の変更は今回の登録分だけに適用します。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("登録する勤務先と給与設定を先に追加してください。").font(.subheadline)
            }
            Button("勤務先を追加") { showEmployerForm = true }
        }.appCard()
    }

    private var reviewRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("登録候補（\(rows.count)件）").font(.headline)
            ForEach($rows) { $row in
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("このシフトを登録", isOn: $row.selected)
                    DatePicker("日付", selection: dateBinding($row.candidate.date), displayedComponents: .date)
                    DatePicker("開始", selection: timeBinding($row.candidate.startMinute), displayedComponents: .hourAndMinute)
                    DatePicker("終了", selection: timeBinding($row.candidate.endMinute), displayedComponents: .hourAndMinute)
                    if row.candidate.endMinute < row.candidate.startMinute {
                        Text("終了は翌日です").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("休憩")
                        TextField("0", text: $row.breakText).keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("\(row.candidate.date)の休憩、分")
                        Text("分")
                    }
                    if !row.candidate.breakWasRead {
                        Text("休憩は読み取れていません。必要な分数を入力してください。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("元の行：\(row.candidate.source)").font(.caption).foregroundStyle(.secondary)
                }.appCard().onChange(of: row) { _, _ in confirmed = false }
            }
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("日付・時間・休憩・時給を確認しました", isOn: $confirmed)
            Text("読み取りには間違いが含まれることがあります。同じ勤務先・日付・時間の登録済みシフトは追加せず、既存の内容を保ちます。")
                .font(.caption).foregroundStyle(.secondary)
            Text("候補の確認は無料。一括登録はPlusで利用できます。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var saveButton: some View {
        Button {
            Task { await save() }
        } label: {
            HStack {
                if isSaving { ProgressView().tint(.white) }
                if subscriptions.hasPlus { Text("\(selectedCount)件をまとめて登録") }
                else { Text("Plusでまとめて登録") }
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent)
            .disabled(!confirmed || selectedCount == 0 || selectedProfile == nil || isSaving || !store.cloudDataReady)
    }

    private func completion(_ plan: ShiftImportPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(plan.shifts.count)件を登録しました", systemImage: "checkmark.circle.fill")
                .font(.title2.bold()).foregroundStyle(Color.accentColor)
            if plan.duplicateCount > 0 {
                Text("登録済みの\(plan.duplicateCount)件は追加していません。")
            }
            ForEach(plan.shifts) { shift in
                Text("\(shift.date) · \(shift.employer) · \(ClockUtils.formatClock(shift.segments[0].startMinute))–\(ClockUtils.formatClock(shift.segments[0].endMinute))")
                    .font(.subheadline)
            }
            Button("シフトに戻る") { dismiss() }.buttonStyle(.borderedProminent)
        }.appCard()
    }

    private func selectDefaultProfile() {
        guard selectedProfile == nil else { return }
        profileID = store.employerProfiles.first?.id ?? ""
        wageText = selectedProfile.map { String($0.defaultWage) } ?? ""
    }

    private func beginRead(_ load: @escaping @MainActor () async throws -> Data) {
        readTask?.cancel()
        let ticket = UUID(); generation = ticket
        recognized = nil; rows = []; issues = []; result = nil; confirmed = false; error = ""; isReading = true
        readTask = Task { @MainActor in
            defer { if generation == ticket { isReading = false } }
            do {
                let data = try await load()
                try Task.checkCancellation()
                let text = try await ShiftPhotoReader.read(data)
                guard generation == ticket, !Task.isCancelled else { return }
                recognized = text; parseRecognized()
            } catch is CancellationError { }
            catch { if generation == ticket { self.error = error.localizedDescription } }
        }
    }

    private func parseRecognized() {
        guard let recognized else { return }
        do {
            let parsed = try ShiftImportParser.parse(lines: recognized.lines, month: monthText)
            rows = parsed.candidates.map { Row(candidate: $0, breakText: String($0.breakMinutes)) }
            issues = parsed.issues; confirmed = false; error = ""
        } catch { self.error = error.localizedDescription; rows = [] }
    }

    private func save() async {
        guard confirmed, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            guard var profile = selectedProfile, let wage = Double(wageText) else { throw ShiftImportError.invalidProfile }
            profile.defaultWage = wage
            let candidates = try rows.filter(\.selected).map { row in
                guard let pause = Int(row.breakText) else {
                    throw ShiftImportError.invalidRow(row.id, "\(row.candidate.date)の休憩を分数で入力してください。")
                }
                var candidate = row.candidate; candidate.breakMinutes = pause; return candidate
            }
            _ = try ShiftImportPlanner.plan(candidates: candidates, profile: profile, existing: store.shifts)
            await subscriptions.refreshAccess()
            guard subscriptions.hasPlus else { showPaywall = true; return }
            guard confirmed, selectedProfile?.id == profile.id else { return }
            let saved = try store.importShiftCandidates(candidates, profile: profile)
            for shift in saved.shifts {
                notifications.log(kind: .added, title: "シフトを追加しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date))")
            }
            if !saved.shifts.isEmpty {
                NotificationScheduler.requestAuthorizationIfNeeded()
                for shift in saved.shifts { NotificationScheduler.scheduleReminder(for: shift) }
            }
            result = saved; recognized = nil; photo = nil; error = ""
        } catch { self.error = error.localizedDescription }
    }

    private func timeBinding(_ minute: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minute.wrappedValue / 60, minute: minute.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        }, set: {
            let parts = Calendar.current.dateComponents([.hour,.minute], from: $0)
            minute.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        })
    }
    private func dateBinding(_ date: Binding<String>) -> Binding<Date> {
        Binding(get: {
            guard let parts = DateUtils.parseYMD(date.wrappedValue) else { return Date() }
            return DateUtils.date(year: parts.year, month: parts.month, day: parts.day)
        },
                set: { date.wrappedValue = DateUtils.ymd($0) })
    }
}
