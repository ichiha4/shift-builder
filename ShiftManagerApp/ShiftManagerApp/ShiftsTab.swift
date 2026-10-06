import SwiftUI

struct ShiftsTab: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.locale) private var locale
    @Binding var month: String
    @Binding var requestedDate: String?

    @State private var selectedDate: String
    @State private var showAddSheet = false
    @State private var showPhotoImport = false
    @State private var editingShift: Shift?
    @State private var dismissedFormatKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "shiftmgr.dismissedShiftFormats") ?? []
    )
    /// Bumped on every template tap purely to drive `.sensoryFeedback` — a quick-add writes a
    /// shift into a list further down the card, which is easy to miss, so the haptic is the
    /// confirmation that the tap registered.
    @State private var quickAddCount = 0
    @State private var pendingDelete: Shift?

    private func confirmDelete(_ shift: Shift) {
        store.deleteShift(id: shift.id)
        NotificationScheduler.cancelReminder(for: shift.id)
        notifications.log(kind: .deleted, title: "シフトを削除しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date))")
        if editingShift?.id == shift.id { editingShift = nil }
    }

    /// A day is always selected — there's no "nothing selected" state to fall back to a
    /// month-wide list anymore, so the calendar needs a sensible starting point up front:
    /// today, when today falls in the month being shown, otherwise that month's 1st.
    init(month: Binding<String>, requestedDate: Binding<String?> = .constant(nil)) {
        self._month = month
        self._requestedDate = requestedDate
        let today = DateUtils.todayYMD()
        _selectedDate = State(initialValue: today.hasPrefix(month.wrappedValue) ? today : month.wrappedValue + "-01")
    }

    private func selectRequestedDate() {
        guard let date = requestedDate, DateUtils.parseYMD(date) != nil else { return }
        selectedDate = date
        requestedDate = nil
    }

    private var monthShifts: [Shift] {
        store.shifts.filter { $0.date.hasPrefix(month) }.sorted { $0.date < $1.date }
    }
    private var dayShifts: [Shift] {
        monthShifts.filter { $0.date == selectedDate }
    }

    /// One previously-used employer + time-block combination, offered as a one-tap way to add
    /// a shift without opening the full form — built from shift history, not a separately
    /// managed template list, so it stays current with no extra upkeep from the user.
    private struct ShiftFormat: Identifiable {
        let id: String
        let employer: String
        let segments: [WorkSegment]
        let source: Shift
        let lastUsedDate: String
    }

    /// Every distinct (employer, time blocks) combination ever used, most-recently-used first,
    /// capped at 5 so the row stays scannable — deliberately built from `store.shifts` instead
    /// of a separate saved-template list, since "recently added history" (the ask) is exactly
    /// what shift history already contains.
    private var recentFormats: [ShiftFormat] {
        var seen: [String: ShiftFormat] = [:]
        for shift in store.shifts.sorted(by: { $0.date > $1.date }) {
            let key = Self.formatKey(shift)
            if seen[key] == nil {
                seen[key] = ShiftFormat(id: key, employer: shift.employer, segments: shift.segments, source: shift, lastUsedDate: shift.date)
            }
        }
        return seen.values
            .filter { !dismissedFormatKeys.contains($0.id) }
            .sorted { $0.lastUsedDate > $1.lastUsedDate }
            .prefix(5)
            .map { $0 }
    }

    private static func formatKey(_ shift: Shift) -> String {
        var normalized = shift
        normalized.id = ""
        normalized.date = ""
        normalized.isStatutoryHoliday = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(normalized).base64EncodedString()) ?? shift.id
    }

    /// Adds a shift for `selectedDate` straight from a format — no form, matching how a manual
    /// add is logged/reminded so a quick-added shift behaves identically to one typed by hand.
    private func quickAdd(_ format: ShiftFormat) {
        guard !isFormatAdded(format) else { return }
        let shift = format.source.repeated(on: selectedDate)
        store.addShift(shift)
        notifications.log(kind: .added, title: "シフトを追加しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date, locale: locale))")
        NotificationScheduler.requestAuthorizationIfNeeded()
        NotificationScheduler.scheduleReminder(for: shift)
    }

    private func dismissFormat(_ format: ShiftFormat) {
        dismissedFormatKeys.insert(format.id)
        UserDefaults.standard.set(Array(dismissedFormatKeys), forKey: "shiftmgr.dismissedShiftFormats")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthNav
                    Button {
                        showPhotoImport = true
                    } label: {
                        Label("写真からシフト登録", systemImage: "photo.badge.plus")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                    CalendarMonthView(month: month, monthShifts: monthShifts, classifications: store.classifications, selectedDate: $selectedDate)
                    dayDetailCard
                }
                .padding(16)
                .readableColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("シフト").font(.title2.weight(.bold))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .accessibilityLabel("シフトを追加")
                }
            }
            .onChange(of: month) { _, newMonth in
                let today = DateUtils.todayYMD()
                selectedDate = today.hasPrefix(newMonth) ? today : newMonth + "-01"
            }
            .onAppear { selectRequestedDate() }
            .onChange(of: requestedDate) { _, _ in selectRequestedDate() }
            .sheet(isPresented: $showAddSheet) {
                ShiftFormView(date: selectedDate, existing: nil)
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(isPresented: $showPhotoImport) {
                NavigationStack { ShiftPhotoImportView(month: month) }
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(item: $editingShift) { shift in
                ShiftFormView(date: shift.date, existing: shift)
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .confirmationDialog(
                "このシフトを削除しますか?",
                isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { shift in
                Button("削除", role: .destructive) { confirmDelete(shift) }
                Button("キャンセル", role: .cancel) {}
            } message: { shift in
                Text("\(shift.employer)・\(DateUtils.formatFullDate(shift.date, locale: locale))")
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

    /// The main content of the tab now that there's no month-wide list beneath it — a date is
    /// always selected (see `init`), so this card is always showing something rather than only
    /// appearing once the user taps a day.
    private var dayDetailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Text(DateUtils.formatFullDate(selectedDate, locale: locale))
                        .font(.title3).fontWeight(.bold)
                    if selectedDate == DateUtils.todayYMD() {
                        Text("今日")
                            .font(.caption2).fontWeight(.bold)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.18))
                            .foregroundStyle(Color.accentColor)
                            .clipShape(Capsule())
                    }
                }
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("追加", systemImage: "plus.circle.fill")
                }
                .font(.subheadline)
            }
            if !recentFormats.isEmpty {
                formatQuickAddRow
            }
            if dayShifts.isEmpty {
                Text("この日のシフトはありません。").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(dayShifts) { shift in
                    shiftRow(shift)
                }
                let total = dayShifts.reduce(0.0) { $0 + PayCalculation.pay(for: $1, classifications: store.classifications).netPay }
                Divider()
                HStack {
                    Text("この日の合計").foregroundStyle(.secondary)
                    Spacer()
                    Text(yen(total)).fontWeight(.bold).foregroundStyle(.green)
                }
                .font(.subheadline)
            }
        }
        .appCard()
    }

    /// Matching shifts cannot be accidentally added twice from the same template.
    /// A different time block remains available, and the full form allows explicit edits.
    private func isFormatAdded(_ format: ShiftFormat) -> Bool {
        dayShifts.contains { Self.formatKey($0) == format.id }
    }

    /// Chip-sized version of `segmentsSummary` — the full per-segment breakdown runs wider than
    /// the screen for a shift split into three wage bands, which pushed the chip past the card
    /// and truncated it mid-number. A chip only needs enough to tell two templates apart; the
    /// per-band detail is on the shift row once it's added.
    private func chipSummary(_ segments: [WorkSegment]) -> String {
        guard let first = segments.first, let last = segments.last else { return "" }
        let span = "\(ClockUtils.formatClock(first.startMinute))–\(ClockUtils.formatClock(last.endMinute))"
        guard segments.count > 1 else { return "\(span) ¥\(Int(first.hourlyWage))" }
        return "\(span)・\(segments.count)区分"
    }

    private var formatQuickAddRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 10))
                Text("テンプレート").font(.caption).fontWeight(.semibold)
                Spacer()
                Text("タップでこの日に追加").font(.caption2)
            }
            .foregroundStyle(.secondary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentFormats) { format in
                        formatChip(format)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 2)
            }
            // Bleeds the scroller out to the card's edges so a row that runs off-screen looks
            // deliberately scrollable, instead of being cut short inside the card's padding.
            .padding(.horizontal, -16)
        }
        .sensoryFeedback(.success, trigger: quickAddCount)
    }

    private func formatChip(_ format: ShiftFormat) -> some View {
        let added = isFormatAdded(format)
        return Button {
            quickAdd(format)
            quickAddCount += 1
        } label: {
            HStack(spacing: 9) {
                Image(systemName: added ? "checkmark.circle.fill" : "plus.circle.fill")
                    .font(.system(size: 21))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(format.employer)
                            .font(.subheadline).fontWeight(.semibold)
                            .foregroundStyle(.primary)
                        if added {
                            Text("追加済み")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1.5)
                                .background(Color.green.opacity(0.16))
                                .foregroundStyle(.green)
                                .clipShape(Capsule())
                        }
                    }
                    Text(chipSummary(format.segments))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if format.source.breakMinutes > 0 {
                        Text("休憩\(format.source.breakMinutes)分")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.09))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(added)
        // Hiding lives in a long-press menu rather than an always-visible "×" — that × sat a few
        // points from the add target, so a near-miss silently removed the template instead of
        // recording a shift, and nothing on it said which of the two it would do.
        .contextMenu {
            Button(role: .destructive) {
                dismissFormat(format)
            } label: {
                Label("このテンプレートを非表示", systemImage: "eye.slash")
            }
        }
    }

    // Note: `.swipeActions` only works inside a `List` — this screen uses a plain ScrollView
    // (to keep the custom card styling), so delete is a visible trash button instead.
    private func shiftRow(_ shift: Shift) -> some View {
        let pay = PayCalculation.pay(for: shift, classifications: store.classifications)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(shift.isStatutoryHoliday ? Color.red : Color.green)
                .frame(width: 4)

            Button {
                editingShift = shift
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(shift.employer).fontWeight(.semibold)
                        Spacer()
                        Text(yen(pay.netPay)).foregroundStyle(.green).fontWeight(.semibold)
                    }
                    Text(segmentsSummary(shift.segments))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    badges(pay)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Deleting asks first: this button sits a few points from the row that opens the
            // editor, so a near-miss used to destroy a shift outright with nothing to undo it.
            Button {
                pendingDelete = shift
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("シフトを削除")
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func badges(_ pay: ShiftPayResult) -> some View {
        HStack(spacing: 5) {
            if pay.scheduledOvertimeMinutes > 0 { badge("所定内残業", .blue) }
            if pay.lateNightExtra > 0 { badge("深夜", .orange) }
            if pay.extendedOvertimeMinutes > 0 { badge("月60h超", .red) }
            else if pay.overtimeExtra > 0 { badge("法定残業", .orange) }
            if pay.holidayExtra > 0 { badge("法定休日", .red) }
            if pay.transport > 0 { badge("交通費", .indigo) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
