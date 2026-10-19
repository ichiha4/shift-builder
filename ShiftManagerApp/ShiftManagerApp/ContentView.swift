import SwiftUI
import Charts

enum AppTab: Hashable { case home, shifts, wages }

struct ContentView: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var auth: AuthManager
    @State private var selectedTab: AppTab = .home
    @State private var requestedShiftDate: String?
    @State private var month: String = DateUtils.todayYMD().prefix(7).description

    private var canDisplayData: Bool {
        #if LOCAL_DEVICE_TESTING
        return store.cloudDataReady && store.isAttached(to: LocalDeviceTestTransport.accountID)
        #else
        guard let uid = auth.user?.uid else { return false }
        return store.cloudDataReady && store.isAttached(to: uid)
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewTab(month: $month, selectedTab: $selectedTab, requestedShiftDate: $requestedShiftDate)
                .tabItem { Label("ホーム", systemImage: "house.fill") }
                .tag(AppTab.home)
            ShiftsTab(month: $month, requestedDate: $requestedShiftDate)
                .tabItem { Label("シフト", systemImage: "clock.fill") }
                .tag(AppTab.shifts)
            WageTab(month: $month)
                .tabItem { Label("給与", systemImage: "wallet.pass.fill") }
                .tag(AppTab.wages)
        }
        .opacity(canDisplayData ? 1 : 0)
        .disabled(!canDisplayData)
        .safeAreaInset(edge: .top, spacing: 0) {
            #if !LOCAL_DEVICE_TESTING
            SyncStatusView().environmentObject(store).opacity(canDisplayData ? 1 : 0).disabled(!canDisplayData)
            #endif
        }
        .overlay {
            if !canDisplayData {
                VStack(spacing: 16) {
                    if !store.cloudReadFailed { ProgressView() }
                    if store.remoteDeletionPending {
                        Text("別の端末でのアカウント削除を確認しています。記録はこの端末に保管しています。")
                            .font(.subheadline).multilineTextAlignment(.center)
                    }
                    Text(LocalizedStringKey(store.cloudReadFailed ? "データを読み込めませんでした" : "データを同期しています"))
                        .font(.headline)
                    Text("履歴を保護するため、データの読み込みが終わるまで編集できません。通信環境を確認してください。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.hasInterruptedAccountDeletion {
                        Button("アカウント削除を再開") { auth.needsReauthToDelete = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("再読み込み") {
                        #if LOCAL_DEVICE_TESTING
                        let uid = LocalDeviceTestTransport.accountID
                        #else
                        guard let uid = auth.user?.uid else { return }
                        #endif
                        store.detachUser(clearLocalState: false)
                        store.attachUser(uid: uid)
                        #if !LOCAL_DEVICE_TESTING
                        Task { await auth.recoverInterruptedAccountDeletion() }
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                    #if !LOCAL_DEVICE_TESTING
                    Button("ログアウト") { auth.signOut() }
                    #endif
                }
                .padding(28).frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

private struct OverviewTab: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = DateUtils.todayYMD()
    @Binding var month: String
    @Binding var selectedTab: AppTab
    @Binding var requestedShiftDate: String?
    @AppStorage("shiftmgr.showBalance") private var showBalance = true
    @State private var showSettings = false
    @State private var showNotifications = false
    @State private var showEmployerForm = false
    @State private var showEmployerProfiles = false
    @State private var paydayPrompt: PaydayPrompt?

    /// Home always answers what is scheduled to be paid next month, independently of the
    /// calendar month being browsed on the other tabs. A missing profile has no known payday.
    private var paymentMonth: String { DateUtils.shiftMonth(String(today.prefix(7)), by: 1) }
    private var monthShifts: [Shift] {
        let registeredNames = Set(store.employerProfiles.map(\.name))
        return PayPeriod.shifts(paidInMonth: paymentMonth, shifts: store.shifts, profiles: store.employerProfiles)
            .filter { registeredNames.contains($0.employer) }
    }
    private var payslip: MonthlyPayslip { Aggregation.calculateMonthlyPay(monthShifts, classifications: store.classifications) }
    private var hasUnconfiguredEmployer: Bool {
        store.shifts.contains { shift in !store.employerProfiles.contains { $0.name == shift.employer } }
    }
    private var byEmployer: [(name: String, pay: Double)] {
        Dictionary(grouping: monthShifts, by: \.employer).map { name, shifts in
            (name: name, pay: Aggregation.calculateMonthlyPay(shifts, classifications: store.classifications).grossTotal)
        }.sorted { $0.pay > $1.pay }
    }
    private struct BalancePoint { let day: Int; let balance: Double }
    private var cumulativeSeries: [BalancePoint] {
        guard let (year, monthNumber, _) = DateUtils.parseYMD(paymentMonth + "-01") else { return [] }
        var amounts: [Int: Double] = [:]
        for profile in store.employerProfiles {
            for period in PayPeriod.periods(paidInMonth: paymentMonth, profile: profile) {
                let payDate = PayPeriod.paymentDate(periodEnd: period.periodEnd,
                    paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay,
                    adjustment: profile.paydayAdjustment)
                let shifts = monthShifts.filter {
                    $0.employer == profile.name && $0.date >= period.periodStart && $0.date <= period.periodEnd
                }
                if let day = Int(payDate.suffix(2)) {
                    amounts[day, default: 0] += Aggregation.calculateMonthlyPay(shifts, classifications: store.classifications).grossTotal
                }
            }
        }
        var total = 0.0
        return (1...DateUtils.lastDayOfMonth(year: year, month: monthNumber)).map { day in
            total += amounts[day] ?? 0
            return BalancePoint(day: day, balance: total)
        }
    }
    private static let chartGreen = Color(red: 0.20, green: 0.87, blue: 0.53)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    heroCard
                    if store.employerProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("まず勤務先を登録", systemImage: "building.2.fill").font(.headline)
                            Text("締め日・給料日を設定すると、登録したシフトから給与予定を計算できます。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("勤務先を登録する") { showEmployerForm = true }
                                .buttonStyle(.borderedProminent)
                        }.frame(maxWidth: .infinity, alignment: .leading).appCard()
                    } else if hasUnconfiguredEmployer {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("給料日が未設定の勤務先があります。")
                                .font(.subheadline.weight(.semibold))
                            Text("来月の給与予定に含めるには、勤務先を登録してください。")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("勤務先を設定する") { showEmployerProfiles = true }
                        }.frame(maxWidth: .infinity, alignment: .leading).appCard()
                    }
                    Button {
                        month = String(today.prefix(7))
                        requestedShiftDate = today
                        selectedTab = .shifts
                    } label: {
                        Label("日付を選んでシフト追加", systemImage: "calendar.badge.plus")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent)
                    ForEach(pendingPaydays) { prompt in
                        PaydayBanner(prompt: prompt) { paydayPrompt = prompt }
                    }
                    RecordedIncomeWallCard(year: DateUtils.calendar.component(.year, from: Date()))
                    if let shift = upcomingShift { upcomingShiftCard(shift) }
                    if !byEmployer.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            CardHeader("来月の給与予定・勤務先別", systemImage: "briefcase.fill")
                            ForEach(byEmployer, id: \.name) { item in
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    Text(showBalance ? yen(item.pay) : "••••")
                                        .fontWeight(.semibold).foregroundStyle(.green)
                                }.font(.subheadline)
                            }
                            Text("締め日・給料日に合わせて、登録したシフトから計算しています。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.appCard()
                    } else {
                        Text(LocalizedStringKey(hasUnconfiguredEmployer
                             ? "給料日が未設定の勤務先のシフトは、給与予定に含まれていません。"
                             : "来月支給されるシフトを登録すると、給与予定が表示されます。"))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).appCard()
                    }
                }.padding(16).readableColumn()
            }
            .background(Color(.systemGroupedBackground))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { settingsButton }
                ToolbarItem(placement: .principal) { Text("ホーム").font(.title2.weight(.bold)) }
                ToolbarItem(placement: .navigationBarTrailing) { notificationsButton }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNotifications) { NotificationListView().environmentObject(notifications) }
            .sheet(isPresented: $showEmployerForm) { EmployerProfileFormView(existing: nil).environmentObject(store) }
            .sheet(isPresented: $showEmployerProfiles) { EmployerProfilesView().environmentObject(store) }
            .sheet(item: $paydayPrompt) { prompt in ActualPaySheet(prompt: prompt).environmentObject(store) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { today = DateUtils.todayYMD() } }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in today = DateUtils.todayYMD() }
        }
    }

    private var pendingPaydays: [PaydayPrompt] {
        guard let (ty, tm, _) = DateUtils.parseYMD(today) else { return [] }
        var results: [PaydayPrompt] = []
        for profile in store.employerProfiles {
            for offset in -2...1 {
                var y = ty, m = tm + offset
                while m < 1 { m += 12; y -= 1 }
                while m > 12 { m -= 12; y += 1 }
                let closeDay = DateUtils.resolveDay(year: y, month: m, day: profile.closingDay)
                let periodEnd = String(format: "%04d-%02d-%02d", y, m, closeDay)
                let payDate = PayPeriod.paymentDate(periodEnd: periodEnd, paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
                guard payDate == today else { continue }
                let alreadyRecorded = store.actualPayments.contains { $0.employer == profile.name && $0.payDate == payDate && $0.taxableGross != nil }
                if !alreadyRecorded {
                    results.append(PaydayPrompt(profile: profile, payDate: payDate))
                }
                break
            }
        }
        return results
    }

    private var upcomingShift: Shift? {
        let nowMinute = Date().minutesSinceMidnight
        return store.shifts.filter { shift in
            shift.date > today || (shift.date == today && (shift.segments.first?.startMinute ?? -1) > nowMinute)
        }.min { a, b in
            if a.date != b.date { return a.date < b.date }
            return (a.segments.map(\.startMinute).min() ?? 0) < (b.segments.map(\.startMinute).min() ?? 0)
        }
    }

    private func upcomingShiftCard(_ shift: Shift) -> some View {
        Button {
            month = String(shift.date.prefix(7))
            requestedShiftDate = shift.date
            selectedTab = .shifts
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("次のシフト").font(.caption).foregroundStyle(.secondary)
                    Text(shift.employer).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    Text(DateUtils.formatFullDate(shift.date, locale: locale))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let segment = shift.segments.first {
                    Text("\(ClockUtils.formatClock(segment.startMinute))–\(ClockUtils.formatClock(segment.endMinute))")
                        .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.primary)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appCard()
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("設定")
    }

    private var notificationsButton: some View {
        Button {
            showNotifications = true
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .frame(width: 44, height: 44)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(Circle())
                if notifications.unreadCount > 0 {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .offset(x: 1, y: -1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("通知")
        .accessibilityValue(notifications.unreadCount > 0 ? "未読\(notifications.unreadCount)件" : "")
    }

    private var heroCard: some View {
        let chartColor = Self.chartGreen
        return ZStack(alignment: .topLeading) {
            heroCardBase

            // Soft, blurred color blobs on the black base — an abstract "aurora" glow
            // (a common premium dark-card look) instead of a flat black rectangle. The
            // rightmost blob echoes the chart's own trend color so the glow and the line feel
            // like one design rather than two unrelated layers.
            Circle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 200, height: 200)
                .blur(radius: 55)
                .offset(x: -90, y: -100)
            Circle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 240, height: 240)
                .blur(radius: 65)
                .offset(x: 140, y: 120)
            Circle()
                .fill(chartColor.opacity(0.16))
                .frame(width: 190, height: 190)
                .blur(radius: 55)
                .offset(x: 260, y: -50)

            if cumulativeSeries.count > 1 {
                Chart(cumulativeSeries, id: \.day) { point in
                    AreaMark(x: .value("Day", point.day), y: .value("Balance", point.balance))
                        .foregroundStyle(LinearGradient(colors: [chartColor.opacity(0.4), chartColor.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.stepEnd)
                    LineMark(x: .value("Day", point.day), y: .value("Balance", point.balance))
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.stepEnd)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartLegend(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
                .allowsHitTesting(false)
                // Fades in left-to-right so it reads as a backdrop behind the text rather
                // than competing with it — but never drops to fully invisible, so the whole
                // month's shape is still legible at a glance, not just its right half.
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.32), location: 0),
                            .init(color: .black.opacity(0.6), location: 0.5),
                            .init(color: .black.opacity(0.95), location: 1),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("来月の給与予定")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showBalance.toggle() }
                    } label: {
                        Image(systemName: showBalance ? "eye.fill" : "eye.slash.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Text(showBalance ? yen(payslip.grossTotal) : "••••••••")
                    .font(.system(size: 40, weight: .regular, design: .default))
                    .minimumScaleFactor(0.65).lineLimit(1)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.top, 12)

                Text("\(DateUtils.monthLabel(paymentMonth, locale: locale))支給分・控除前")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 8)
                Text("\(monthShifts.count)回のシフト・\(hoursLabel(payslip.baseMinutes))")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.85))
                    .padding(.top, 10)
                Spacer(minLength: 0)
                Text("グラフ：給料日ごとの支給予定累計")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.6))
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 28)
        }
        .frame(height: 220)
        .heroCardShape()
    }
}

struct PaydayPrompt: Identifiable {
    let profile: EmployerProfile
    let payDate: String
    var id: String { profile.id + payDate }
}

/// The "it's payday" banner on the Overview tab — appears the day an employer's (already
/// weekend/holiday-adjusted) payment date is today, and stays until the user records what they
/// actually received. Animates in with a spring pop plus a gently pulsing yen icon so it reads
/// as a small celebration, not just another list row.
private struct PaydayBanner: View {
    let prompt: PaydayPrompt
    let onEnterPay: () -> Void
    @EnvironmentObject var notifications: NotificationLogStore
    @State private var hasAppeared = false
    @State private var iconSpin = false

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.green.opacity(0.18)).frame(width: 46, height: 46)
                Image(systemName: "dollarsign.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.green)
                    .rotation3DEffect(.degrees(iconSpin ? 360 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                    .animation(.linear(duration: 2.5).repeatForever(autoreverses: false), value: iconSpin)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(prompt.profile.name)：給料日になりました")
                    .font(.subheadline).fontWeight(.bold)
                Text("給与を入力して、年収の残りを確認")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("入力する", action: onEnterPay)
                .font(.caption).fontWeight(.semibold)
                .buttonStyle(.borderedProminent)
                .tint(.green)
        }
        .padding(14)
        .background(
            LinearGradient(colors: [Color.green.opacity(0.16), Color.green.opacity(0.05)], startPoint: .leading, endPoint: .trailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
        .scaleEffect(hasAppeared ? 1 : 0.85)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.62)) { hasAppeared = true }
            iconSpin = true
            notifications.logPaydayIfNeeded(employer: prompt.profile.name, payDate: prompt.payDate)
        }
    }
}

/// Enter one payslip figure for annual-income tracking. Take-home is optional and remains a
/// separate value, including when editing a legacy record that contained only take-home pay.
struct ActualPaySheet: View {
    let prompt: PaydayPrompt
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var amountText = ""
    @State private var grossText = ""
    @State private var showTakeHome = false
    @State private var showDeleteConfirmation = false
    @AppStorage(IncomeWallSettings.annualTargetKey) private var annualTarget = 0.0
    @FocusState private var amountFocused: Bool

    private var gross: Double? { FormNumber.nonnegative(grossText) }
    private var takeHome: Double? { amountText.isEmpty ? nil : FormNumber.nonnegative(amountText) }
    private var canSave: Bool { gross != nil && (amountText.isEmpty || takeHome != nil) }
    private var existingPayment: ActualPayment? {
        store.actualPayments.first { $0.employer == prompt.profile.name && $0.payDate == prompt.payDate }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("勤務先", value: prompt.profile.name)
                    LabeledContent("支給日", value: DateUtils.formatFullDate(prompt.payDate, locale: locale))
                }
                Section {
                    TextField("円", text: $grossText)
                        .keyboardType(.numberPad)
                        .focused($amountFocused)
                        .accessibilityLabel("給与明細の課税支給額")
                } header: { Text("給与明細の「課税支給額」") }
                  footer: { Text("税金や保険料が引かれる前の金額です。非課税の交通費は含めません。振込額や「課税対象額（社会保険料控除後）」とは異なります。") }
                Section {
                    DisclosureGroup("手取りも記録する（任意）", isExpanded: $showTakeHome) {
                        TextField("実際の振込額（円）", text: $amountText)
                            .keyboardType(.numberPad).accessibilityLabel("実際の振込額")
                    }
                }
                if annualTarget > 0, annualTarget.isFinite, let gross,
                   prompt.payDate <= DateUtils.todayYMD() {
                    Section("入力後の年収の目安") {
                        let year = Int(prompt.payDate.prefix(4)) ?? DateUtils.calendar.component(.year, from: Date())
                        let otherPayments = store.actualPayments.filter { !($0.employer == prompt.profile.name && $0.payDate == prompt.payDate) }
                        let total = Aggregation.recordedIncome(year: year, through: DateUtils.todayYMD(), payments: otherPayments).taxableGross + gross
                        LabeledContent("\(String(year))年の給与累計", value: yen(total))
                        LabeledContent(total > annualTarget ? "上限を超えた金額" : "上限まであと", value: yen(abs(annualTarget - total)))
                    }
                }
                if prompt.payDate > DateUtils.todayYMD() {
                    Text("年収の累計には、この支給日から反映されます。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if existingPayment != nil {
                    Section {
                        Button("この給与記録を削除", role: .destructive) { showDeleteConfirmation = true }
                    }
                }
            }
            .navigationTitle("給料を記録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard canSave, let gross else { return }
                        store.recordActualPayment(employer: prompt.profile.name, payDate: prompt.payDate, amount: takeHome, taxableGross: gross)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if let payment = existingPayment {
                    if let amount = payment.amount { amountText = FormNumber.text(amount) }
                    if let gross = payment.taxableGross { grossText = FormNumber.text(gross) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { amountFocused = true }
            }
            .confirmationDialog("この給与記録を削除しますか？", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    if let payment = existingPayment { store.deleteActualPayment(id: payment.id) }
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(ShiftStore())
}
