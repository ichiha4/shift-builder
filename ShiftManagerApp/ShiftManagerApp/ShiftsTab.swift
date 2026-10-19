import SwiftUI

struct ShiftsTab: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var month: String
    @Binding var requestedDate: String?

    @ScaledMetric(relativeTo: .body) private var templateCardWidth: CGFloat = 202

    @State private var selectedDate: String
    @State private var showAddSheet = false
    @State private var showTemplateSheet = false
    @State private var showTemplateManager = false
    @State private var newlySavedTemplateKey: String?
    @State private var templateToDelete: ShiftFormat?
    @State private var editingTemplate: ShiftFormat?
    @State private var editingShift: Shift?
    @State private var overlapRequest: ShiftSaveRequest?
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
        let template: ShiftTemplate?
        var templateID: String? { template?.id }
    }

    /// Reuse recorded patterns without a second setup flow. Stable ordering keeps a template
    /// under the user's finger while adding the same pattern across several calendar dates.
    private var recentFormats: [ShiftFormat] {
        var seen: [String: ShiftFormat] = [:]
        for template in store.shiftTemplates {
            let shift = template.pattern
            let key = Self.formatKey(shift)
            seen[key] = ShiftFormat(id: key, employer: shift.employer, segments: shift.segments,
                                    source: shift, template: template)
        }
        for shift in (store.shifts + store.undoableDeletedShifts).sorted(by: { $0.date > $1.date }) {
            let key = Self.formatKey(shift)
            if seen[key] == nil {
                seen[key] = ShiftFormat(id: key, employer: shift.employer, segments: shift.segments, source: shift, template: nil)
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

    /// Save ordinary taps immediately; capture overlapping additions for explicit consent.
    private func quickAdd(_ format: ShiftFormat) {
        guard !isFormatAdded(format) else { return }
        do {
            let request = try store.prepareShiftSave(format.source.repeated(on: selectedDate))
            if request.requiresOverlapConfirmation { overlapRequest = request }
            else { finishQuickAdd(request) }
        } catch {
            actionError = ActionError(title: "シフトを追加できません", message: error.localizedDescription)
        }
    }

    private func finishQuickAdd(_ request: ShiftSaveRequest, confirmingOverlap: Bool = false) {
        let shift = request.shift
        // A sync update during the prompt must not add the same template a second time.
        guard !store.shifts.contains(where: { $0.date == shift.date && Self.formatKey($0) == Self.formatKey(shift) }) else { return }
        do {
            try store.saveReviewedShift(request, confirmingOverlap: confirmingOverlap)
            quickAddCount += 1
            notifications.log(kind: .added, title: "シフトを追加しました", message: "\(shift.employer)・\(DateUtils.formatFullDate(shift.date, locale: locale))")
            NotificationScheduler.scheduleReminder(for: shift)
        } catch {
            actionError = ActionError(title: "シフトを追加できません", message: error.localizedDescription)
        }
    }

    private func dismissFormat(_ format: ShiftFormat) {
        dismissedFormatKeys.insert(format.id)
        UserDefaults.standard.set(Array(dismissedFormatKeys), forKey: "shiftmgr.dismissedShiftFormats")
    }

    private func deleteFormat(_ format: ShiftFormat) -> String? {
        if let id = format.templateID {
            store.deleteShiftTemplate(id: id)
            guard !store.shiftTemplates.contains(where: { $0.id == id }) else {
                return NSLocalizedString("同期の状態を確認して、もう一度お試しください。", comment: "")
            }
        }
        // History-backed patterns also leave the list without deleting recorded work.
        dismissFormat(format)
        return nil
    }

    private func restoreFormats() {
        dismissedFormatKeys.removeAll()
        UserDefaults.standard.removeObject(forKey: "shiftmgr.dismissedShiftFormats")
    }

    private func templateSaved(_ template: ShiftTemplate, replacing format: ShiftFormat? = nil) {
        if let format, format.id != template.fingerprint { dismissedFormatKeys.insert(format.id) }
        dismissedFormatKeys.remove(template.fingerprint)
        UserDefaults.standard.set(Array(dismissedFormatKeys), forKey: "shiftmgr.dismissedShiftFormats")
        newlySavedTemplateKey = template.fingerprint
    }

    @ViewBuilder
    private func templateActions(_ format: ShiftFormat) -> some View {
        Button { editingTemplate = format } label: {
            Label("編集", systemImage: "pencil")
        }
        Button(role: .destructive) { templateToDelete = format } label: {
            Label("削除", systemImage: "trash")
        }
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
            .onChange(of: store.cloudDataReady) { _, ready in
                if !ready { overlapRequest = nil; templateToDelete = nil; editingTemplate = nil; showTemplateManager = false }
            }
            .sheet(isPresented: $showAddSheet) {
                ShiftFormView(date: selectedDate, existing: nil)
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(isPresented: $showTemplateSheet) {
                ShiftFormView(date: selectedDate, existing: nil, isTemplate: true) { template in
                    templateSaved(template)
                }
                    .environmentObject(store)
                    .environmentObject(notifications)
            }
            .sheet(isPresented: $showTemplateManager) {
                TemplateManagerView(formats: recentFormats, date: selectedDate,
                                    onSave: { template, format in templateSaved(template, replacing: format) },
                                    onDelete: deleteFormat)
                    .environmentObject(store)
                    .environmentObject(notifications)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $editingTemplate) { format in
                ShiftFormView(date: selectedDate, existing: format.source, isTemplate: true, existingTemplate: format.template) { template in
                    templateSaved(template, replacing: format)
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
                    templateToDelete = nil
                    if let message = deleteFormat(format) {
                        actionError = ActionError(title: "テンプレートを削除できません", message: message)
                    }
                }
                Button("キャンセル", role: .cancel) { templateToDelete = nil }
            } message: { format in
                Text(verbatim: "\(format.employer)・\(chipSummary(format.segments))\n\n")
                    + Text("登録済みのシフトは削除されません。")
            }
            .alert("勤務時間が重なっています", isPresented: Binding(
                get: { overlapRequest != nil },
                set: { if !$0 { overlapRequest = nil } }
            ), presenting: overlapRequest) { request in
                Button("キャンセル", role: .cancel) { overlapRequest = nil }
                Button("追加する") {
                    overlapRequest = nil
                    finishQuickAdd(request, confirmingOverlap: true)
                }
            } message: { request in
                Text(shiftOverlapMessage(for: request, locale: locale))
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

    /// Exact template taps do nothing after adding; management stays available.
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
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .foregroundStyle(.primary)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !recentFormats.isEmpty {
                Button { showTemplateManager = true } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("テンプレートを管理")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The heading opens a readable list; each pattern has its own explicit actions.
    private struct TemplateManagerView: View {
        @EnvironmentObject private var store: ShiftStore
        @EnvironmentObject private var notifications: NotificationLogStore
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        let formats: [ShiftFormat]
        let date: String
        let onSave: (ShiftTemplate, ShiftFormat) -> Void
        let onDelete: (ShiftFormat) -> String?
        @State private var editingFormat: ShiftFormat?
        @State private var deletingFormat: ShiftFormat?
        @State private var deletionError: String?

        private var accent: Color {
            colorScheme == .dark ? Color(red: 0.40, green: 0.91, blue: 0.73) : Color(red: 0.035, green: 0.44, blue: 0.33)
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("勤務パターン")
                            Spacer()
                            Text("\(formats.count)件")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 4)
                        if formats.isEmpty {
                            Text("表示中のテンプレートはありません。")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        }
                        ForEach(formats) { format in
                            templateRow(format)
                        }
                        Text("登録済みのシフトはそのまま残ります。")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.top, 8)
                    }
                    .padding(16)
                    .readableColumn()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("テンプレート")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.medium))
                        }
                        .accessibilityLabel("閉じる")
                    }
                }
                .sheet(item: $editingFormat) { format in
                    ShiftFormView(date: date, existing: format.source, isTemplate: true, existingTemplate: format.template) { template in
                        onSave(template, format)
                    }
                        .environmentObject(store)
                        .environmentObject(notifications)
                }
                .alert("テンプレートを削除しますか？", isPresented: Binding(
                    get: { deletingFormat != nil },
                    set: { if !$0 { deletingFormat = nil } }
                ), presenting: deletingFormat) { format in
                    Button("削除する", role: .destructive) {
                        deletingFormat = nil
                        deletionError = onDelete(format)
                    }
                    Button("キャンセル", role: .cancel) { deletingFormat = nil }
                } message: { format in
                    let segments = format.segments.map {
                        "\(ClockUtils.formatClock($0.startMinute))–\(ClockUtils.formatClock($0.endMinute))  \(yen($0.hourlyWage))"
                    }.joined(separator: "\n")
                    Text(verbatim: "\(format.employer)\n\(segments)\n\n") + Text("登録済みのシフトは削除されません。")
                }
                .alert("テンプレートを削除できません", isPresented: Binding(
                    get: { deletionError != nil },
                    set: { if !$0 { deletionError = nil } }
                )) {
                    Button("閉じる", role: .cancel) { deletionError = nil }
                } message: {
                    Text(deletionError ?? "")
                }
            }
        }

        private func templateRow(_ format: ShiftFormat) -> some View {
            let isDark = colorScheme == .dark
            let ink = isDark ? Color.white : Color(red: 0.12, green: 0.20, blue: 0.18)
            let secondaryInk = isDark ? Color.white.opacity(0.62) : Color(red: 0.40, green: 0.47, blue: 0.44)
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            return HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "briefcase").font(.caption2).foregroundStyle(accent)
                        Text(format.employer).font(.subheadline.weight(.medium))
                            .foregroundStyle(ink.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(format.segments.indices, id: \.self) { index in
                            let segment = format.segments[index]
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(ClockUtils.formatClock(segment.startMinute))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(accent.opacity(0.65))
                                        .accessibilityHidden(true)
                                    Text(ClockUtils.formatClock(segment.endMinute))
                                }
                                .font(.title.weight(.regular))
                                .foregroundStyle(ink)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: "\(ClockUtils.formatClock(segment.startMinute))–\(ClockUtils.formatClock(segment.endMinute))"))
                                HStack(spacing: 5) {
                                    Text("時給")
                                    Text(yen(segment.hourlyWage))
                                }
                                .font(.caption).foregroundStyle(secondaryInk)
                            }
                        }
                        if format.source.breakMinutes > 0 {
                            Text("休憩\(format.source.breakMinutes)分").font(.caption).foregroundStyle(secondaryInk)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    Button { editingFormat = format } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "pencil").font(.body)
                            Text("編集").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: 48).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(accent)
                    .accessibilityLabel(Text("編集") + Text(verbatim: "、\(format.employer)"))
                    Button(role: .destructive) { deletingFormat = format } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "trash").font(.body)
                            Text("削除").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: 48).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(secondaryInk)
                    .accessibilityLabel(Text("削除") + Text(verbatim: "、\(format.employer)"))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
                .background(accent.opacity(isDark ? 0.025 : 0.015))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(LinearGradient(colors: [accent.opacity(0.08), accent.opacity(0.55), accent.opacity(0.12)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1)
                        .padding(.vertical, 16)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.10, green: 0.13, blue: 0.14), Color(red: 0.045, green: 0.065, blue: 0.06)]
                               : [.white, Color(red: 0.975, green: 0.99, blue: 0.985)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        RadialGradient(colors: [accent.opacity(isDark ? 0.16 : 0.085), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: 220)
                    }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: isDark
                                                 ? [.white.opacity(0.2), accent.opacity(0.2), .white.opacity(0.06)]
                                                 : [.white, accent.opacity(0.17), accent.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(isDark ? 0.13 : 0.045), radius: 10, x: 0, y: 5)
            .accessibilityElement(children: .contain)
        }
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
                Text("勤務先・時間・時給を日付なしで保存。作成後は、日付を選んでタップするだけで追加できます。")
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
                        .padding(.top, 3).padding(.bottom, 10)
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
                    Text(recentFormats.allSatisfy { isFormatAdded($0) } ? "この日は追加済みです" : "タップでこの日に追加").font(.caption)
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
        let isDark = colorScheme == .dark
        let green = isDark ? Color(red: 0.40, green: 0.91, blue: 0.73) : Color(red: 0.035, green: 0.44, blue: 0.33)
        let signal = overlaps ? (isDark ? Color(red: 1, green: 0.74, blue: 0.43) : Color(red: 0.65, green: 0.34, blue: 0.09)) : green
        let ink = isDark ? Color.white : Color(red: 0.12, green: 0.20, blue: 0.18)
        let secondaryInk = isDark ? Color.white.opacity(0.72) : Color(red: 0.34, green: 0.42, blue: 0.38)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return Button {
            quickAdd(format)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "briefcase")
                        .font(.caption2)
                        .foregroundStyle(signal)
                    Text(format.employer)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ink.opacity(isDark ? 0.88 : 0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                if let first = format.segments.first, let last = format.segments.last {
                    HStack(alignment: .center, spacing: 6) {
                        templateTime("出勤", minute: first.startMinute)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(signal.opacity(0.7))
                            .padding(.top, 15)
                            .accessibilityHidden(true)
                        Spacer(minLength: 0)
                        templateTime("退勤", minute: last.endMinute)
                    }
                }

                Rectangle().fill(isDark ? Color.white.opacity(0.14) : green.opacity(0.14)).frame(height: 0.5)

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        if added {
                            Text("追加済み").foregroundStyle(signal)
                        } else if overlaps {
                            Text("確認して追加").foregroundStyle(signal)
                        } else if format.segments.count > 1 {
                            Text("\(format.segments.count)区分").foregroundStyle(secondaryInk)
                        } else if let segment = format.segments.first {
                            HStack(spacing: 3) {
                                Text("時給")
                                Text(yen(segment.hourlyWage))
                            }
                            .foregroundStyle(secondaryInk)
                        }
                        if format.source.breakMinutes > 0 {
                            Text("休憩\(format.source.breakMinutes)分")
                                .foregroundStyle(secondaryInk)
                        }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: added ? "checkmark" : "plus")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(added ? signal : (isDark ? Color(red: 0.05, green: 0.16, blue: 0.13) : .white))
                        .frame(width: 28, height: 28)
                        .background(added ? signal.opacity(isDark ? 0.12 : 0.08) : signal, in: Circle())
                        .overlay {
                            Circle().strokeBorder(signal.opacity(added ? 0.4 : 0), lineWidth: 0.75)
                        }
                }
                .frame(minHeight: 28)
            }
            .padding(16)
            .frame(width: templateCardWidth, alignment: .leading)
            .background {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.10, green: 0.13, blue: 0.14), Color(red: 0.045, green: 0.065, blue: 0.06)]
                               : [.white, Color(red: 0.97, green: 0.985, blue: 0.98)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        RadialGradient(colors: [signal.opacity(isDark ? (added ? 0.25 : 0.14) : (added ? 0.15 : 0.08)), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: 170)
                    }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: isDark
                                                 ? [.white.opacity(0.24), signal.opacity(added ? 0.55 : 0.16), .white.opacity(0.07)]
                                                 : [.white, signal.opacity(added ? 0.42 : 0.17), green.opacity(0.13)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .shadow(color: .black.opacity(isDark ? 0.13 : 0.075), radius: 6, x: 0, y: 4)
            .contentShape(shape)
        }
        .buttonStyle(TemplateCardButtonStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(added ? [.isSelected] : [])
        .accessibilityLabel("\(format.employer)、\(chipSummary(format.segments))")
        .accessibilityValue(added ? Text("追加済み") : (overlaps ? Text("時間重複・確認して追加") : Text("")))
        .accessibilityHint(added ? Text("追加済みです。長押しで編集・削除できます。") : (overlaps ? Text("登録済みのシフトと時間が重なります。タップすると追加前に確認できます。") : Text("タップでこの日に追加")))
        .contextMenu {
            templateActions(format)
        }
        .accessibilityAction(named: Text("テンプレートを編集")) {
            editingTemplate = format
        }
        .accessibilityAction(named: Text("テンプレートを削除")) {
            templateToDelete = format
        }
    }

    private func templateTime(_ title: LocalizedStringKey, minute: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.58) : Color(red: 0.34, green: 0.42, blue: 0.38))
            Text(ClockUtils.formatClock(minute))
                .font(.title3.weight(.regular))
                .foregroundStyle(colorScheme == .dark ? Color.white : Color(red: 0.12, green: 0.20, blue: 0.18))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    /// A small press response keeps the card's primary and management actions consistent.
    private struct TemplateCardButtonStyle: ButtonStyle {
        let reduceMotion: Bool

        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .opacity(configuration.isPressed ? 0.9 : 1)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
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
