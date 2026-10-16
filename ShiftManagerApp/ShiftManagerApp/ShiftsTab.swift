import SwiftUI

struct ShiftsTab: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var month: String
    @Binding var requestedDate: String?

    @ScaledMetric(relativeTo: .body) private var templateCardWidth: CGFloat = 182

    @State private var selectedDate: String
    @State private var showAddSheet = false
    @State private var showTemplateSheet = false
    @State private var newlySavedTemplateKey: String?
    @State private var templateToDelete: ShiftFormat?
    @State private var editingShift: Shift?
    @State private var dismissedFormatKeys: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: "shiftmgr.dismissedShiftFormats") ?? []
    )
    /// Bumped on every template tap purely to drive `.sensoryFeedback` — a quick-add writes a
    /// shift into a list further down the card, which is easy to miss, so the haptic is the
    /// confirmation that the tap registered.
    @State private var quickAddCount = 0
    private struct ActionError {
        let title: String
        let message: String
    }
    @State private var actionError: ActionError?

    private func deleteShift(_ shift: Shift) {
        guard store.deleteShiftWithUndo(id: shift.id) else { return }
        notifications.log(kind: .deleted, title: "シフトを削除しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date))")
        if editingShift?.id == shift.id { editingShift = nil }
    }

    private func undoDeletion() {
        do {
            for shift in try store.undoShiftDeletions() {
                notifications.log(kind: .added, title: "シフトを元に戻しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date, locale: locale))")
            }
        } catch {
            actionError = ActionError(title: "シフトを元に戻せません", message: error.localizedDescription)
        }
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

    /// Saved templates and older history patterns share the same one-tap entry.
    private struct ShiftFormat: Identifiable {
        let id: String
        let employer: String
        let segments: [WorkSegment]
        let source: Shift
        let templateID: String?
    }

    /// Reuse recorded patterns without a second setup flow. Stable ordering keeps a template
    /// under the user's finger while adding the same pattern across several calendar dates.
    private var recentFormats: [ShiftFormat] {
        var seen: [String: ShiftFormat] = [:]
        for template in store.shiftTemplates {
            let shift = template.pattern
            let key = Self.formatKey(shift)
            seen[key] = ShiftFormat(id: key, employer: shift.employer, segments: shift.segments,
                                    source: shift, templateID: template.id)
        }
        for shift in (store.shifts + store.undoableDeletedShifts).sorted(by: { $0.date > $1.date }) {
            let key = Self.formatKey(shift)
            if seen[key] == nil {
                seen[key] = ShiftFormat(id: key, employer: shift.employer, segments: shift.segments, source: shift, templateID: nil)
            }
        }
        return seen.values
            .filter { !dismissedFormatKeys.contains($0.id) }
            .sorted {
                if $0.employer != $1.employer { return $0.employer < $1.employer }
                let left = $0.segments.first?.startMinute ?? 0
                let right = $1.segments.first?.startMinute ?? 0
                return left == right ? $0.id < $1.id : left < right
            }
    }

    private static func formatKey(_ shift: Shift) -> String {
        ShiftTemplate.fingerprint(shift)
    }

    /// Adds a shift for `selectedDate` straight from a format — no form, matching how a manual
    /// add is logged/reminded so a quick-added shift behaves identically to one typed by hand.
    private func quickAdd(_ format: ShiftFormat) {
        guard !isFormatAdded(format) else { return }
        let shift = format.source.repeated(on: selectedDate)
        let errors = Validation.validateShift(shift, existing: store.shifts)
        guard errors.isEmpty else {
            actionError = ActionError(title: "シフトを追加できません", message: errors.joined(separator: "\n"))
            return
        }
        store.addShift(shift)
        quickAddCount += 1
        notifications.log(kind: .added, title: "シフトを追加しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date, locale: locale))")
        NotificationScheduler.scheduleReminder(for: shift)
    }

    private func dismissFormat(_ format: ShiftFormat) {
        dismissedFormatKeys.insert(format.id)
        UserDefaults.standard.set(Array(dismissedFormatKeys), forKey: "shiftmgr.dismissedShiftFormats")
    }

    private func restoreFormats() {
        dismissedFormatKeys.removeAll()
        UserDefaults.standard.removeObject(forKey: "shiftmgr.dismissedShiftFormats")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    monthNav
                    CalendarMonthView(month: month, monthShifts: monthShifts, classifications: store.classifications, selectedDate: $selectedDate)
                    dayDetailCard
                }
                .padding(16)
                // Leave room just above the month label without moving the calendar
                // when the temporary undo card appears or expires.
                .padding(.top, 32)
                .readableColumn()
            }
            .background(Color(.systemGroupedBackground))
            .overlay(alignment: .top) {
                if store.pendingShiftDeletionCount > 0, let deadline = store.shiftDeletionUndoDeadline {
                    deletionUndoBanner(deadline: deadline)
                        .padding(.horizontal, 24)
                }
            }
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
            .onAppear {
                store.expireShiftDeletionUndo()
                selectRequestedDate()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { store.expireShiftDeletionUndo() }
            }
            .onChange(of: requestedDate) { _, _ in selectRequestedDate() }
            .sheet(isPresented: $showAddSheet) {
                ShiftFormView(date: selectedDate, existing: nil)
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(isPresented: $showTemplateSheet) {
                ShiftFormView(date: selectedDate, existing: nil, isTemplate: true) { template in
                    dismissedFormatKeys.remove(template.fingerprint)
                    UserDefaults.standard.set(Array(dismissedFormatKeys), forKey: "shiftmgr.dismissedShiftFormats")
                    newlySavedTemplateKey = template.fingerprint
                }
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(item: $editingShift) { shift in
                ShiftFormView(date: shift.date, existing: shift)
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .alert(LocalizedStringKey(actionError?.title ?? ""), isPresented: Binding(
                get: { actionError != nil },
                set: { if !$0 { actionError = nil } }
            ), presenting: actionError) { _ in
                Button("閉じる", role: .cancel) { actionError = nil }
            } message: { error in
                Text(LocalizedStringKey(error.message))
            }
            .alert("テンプレートを削除しますか？", isPresented: Binding(
                get: { templateToDelete != nil },
                set: { if !$0 { templateToDelete = nil } }
            ), presenting: templateToDelete) { format in
                Button("削除する", role: .destructive) {
                    if let id = format.templateID { store.deleteShiftTemplate(id: id) }
                    dismissFormat(format)
                    templateToDelete = nil
                }
                Button("キャンセル", role: .cancel) { templateToDelete = nil }
            } message: { _ in
                Text("登録済みのシフトは削除されません。")
            }
        }
    }

    /// A framed card immediately above the month, independent of the scrolling content.
    private func deletionUndoBanner(deadline: Date) -> some View {
        // Read the store's actual deadline on every frame, including after a tab switch.
        // No separate view timer can drift from or restart the restoration window.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { context in
            let remaining = min(ShiftStore.shiftDeletionUndoDuration, max(0, deadline.timeIntervalSince(context.date)))
            let seconds = Int(ceil(remaining))
            let progress = min(1, remaining / ShiftStore.shiftDeletionUndoDuration)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Group {
                            if store.pendingShiftDeletionCount == 1 {
                                Text("削除しました")
                            } else {
                                Text("\(store.pendingShiftDeletionCount)件削除しました")
                            }
                        }
                        .font(.footnote.weight(.medium)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        Text("あと\(seconds)秒")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .accessibilityLabel("元に戻せる残り時間、\(seconds)秒")
                    }
                    Capsule()
                        .fill(Color.accentColor.opacity(0.1))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .scaleEffect(x: progress, y: 1, anchor: .leading)
                        }
                        .frame(height: 3)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(width: 1, height: 22)
                    .accessibilityHidden(true)
                Button(action: undoDeletion) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .medium))
                            .accessibilityHidden(true)
                        Text("元に戻す").font(.footnote.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                    .buttonStyle(.plain)
                    .accessibilityHint("直前に削除したシフトをまとめて戻します")
            }
            .frame(height: 44)
            .padding(.horizontal, 16).padding(.vertical, 4)
            .frame(maxWidth: 300)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(DateUtils.formatFullDate(selectedDate, locale: locale))
                    .font(.title3.weight(.semibold))
                if selectedDate == DateUtils.todayYMD() {
                    Text("今日")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.1), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            formatQuickAddRow
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

    /// Full template matches get an "added" checkmark. Other overlapping patterns are
    /// identified separately so a changed wage cannot create a second copy of the same work.
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

    private var templateControls: some View {
        HStack(spacing: 2) {
            Button {
                newlySavedTemplateKey = nil
                showTemplateSheet = true
            } label: {
                Label("テンプレートを作成", systemImage: "plus")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.08), in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !store.shiftTemplates.isEmpty {
                Menu {
                    Section("削除するテンプレート") {
                        ForEach(store.shiftTemplates) { template in
                            Button(role: .destructive) {
                                let pattern = template.pattern
                                templateToDelete = ShiftFormat(id: template.fingerprint, employer: pattern.employer,
                                                              segments: pattern.segments, source: pattern, templateID: template.id)
                            } label: {
                                Label("\(template.pattern.employer)・\(chipSummary(template.pattern.segments))", systemImage: "trash")
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("テンプレートを管理")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var formatQuickAddRow: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("テンプレート").font(.subheadline.weight(.semibold))
                        .fixedSize()
                    Spacer(minLength: 0)
                    templateControls
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("テンプレート").font(.subheadline.weight(.semibold))
                    templateControls
                }
            }

            if recentFormats.isEmpty {
                Text("いつもの勤務先・時間・時給を、日付なしで保存できます。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(recentFormats) { format in
                                formatChip(format)
                                    .id(format.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 2)
                    }
                    .padding(.horizontal, -16)
                    .onChange(of: newlySavedTemplateKey) { _, key in
                        if let key {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                                proxy.scrollTo(key, anchor: .center)
                            }
                        }
                    }
                }
            }

            HStack(alignment: .firstTextBaseline) {
                if !recentFormats.isEmpty {
                    Text("タップでこの日に追加").font(.caption)
                }
                Spacer(minLength: 8)
                if !dismissedFormatKeys.isEmpty {
                    Button("非表示を戻す", action: restoreFormats).font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
        .sensoryFeedback(.success, trigger: quickAddCount)
    }

    private func formatChip(_ format: ShiftFormat) -> some View {
        let added = isFormatAdded(format)
        let overlaps = !added && ShiftScenario.hasOverlap(format.source.repeated(on: selectedDate), with: store.shifts)
        let accent: Color = overlaps ? .orange : .accentColor
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            quickAdd(format)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                Text(format.employer)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let first = format.segments.first, let last = format.segments.last {
                    Text("\(ClockUtils.formatClock(first.startMinute))–\(ClockUtils.formatClock(last.endMinute))")
                        .font(.title3.weight(.regular))
                        .foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                }

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        if added {
                            Text("追加済み").foregroundStyle(Color.accentColor)
                        } else if overlaps {
                            Text("時間重複").foregroundStyle(.orange)
                        } else if format.segments.count > 1 {
                            Text("\(format.segments.count)区分").foregroundStyle(.secondary)
                        } else if let segment = format.segments.first {
                            HStack(spacing: 3) {
                                Text("時給")
                                Text(yen(segment.hourlyWage))
                            }
                            .foregroundStyle(.secondary)
                        }
                        if format.source.breakMinutes > 0 {
                            Text("休憩\(format.source.breakMinutes)分")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: added ? "checkmark" : (overlaps ? "exclamationmark" : "plus"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accent)
                        .frame(width: 28, height: 28)
                        .background(accent.opacity(0.1), in: Circle())
                }
                .frame(minHeight: 28)
            }
            .padding(14)
            .frame(width: templateCardWidth, alignment: .leading)
            .background(added ? Color.accentColor.opacity(0.06) : Color(.tertiarySystemGroupedBackground), in: shape)
            .overlay {
                shape.strokeBorder(added ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 1)
            }
            .contentShape(shape)
        }
        .buttonStyle(TemplateCardButtonStyle())
        .disabled(added || overlaps)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(added ? [.isSelected] : [])
        .accessibilityLabel("\(format.employer)、\(chipSummary(format.segments))")
        .accessibilityValue(added ? Text("追加済み") : (overlaps ? Text("時間重複") : Text("")))
        .accessibilityHint(added ? Text("") : (overlaps ? Text("登録済みのシフトと勤務時間が重複しています。既存のシフトを確認・編集してください。") : Text("タップでこの日に追加")))
        .contextMenu {
            Button(role: .destructive) {
                dismissFormat(format)
            } label: {
                Label("このテンプレートを非表示", systemImage: "eye.slash")
            }
        }
    }

    /// Keep status text readable when the card is disabled after adding or overlapping.
    private struct TemplateCardButtonStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
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

            Button {
                deleteShift(shift)
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
