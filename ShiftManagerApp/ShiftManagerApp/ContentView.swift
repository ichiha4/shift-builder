import SwiftUI
import Charts

enum AppTab: Hashable { case home, shifts, wages, expenses }

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
            ExpensesTab(month: $month)
                .tabItem { Label("支出", systemImage: "receipt.fill") }
                .tag(AppTab.expenses)
        }
        .opacity(canDisplayData ? 1 : 0)
        .disabled(!canDisplayData)
        .safeAreaInset(edge: .top, spacing: 0) {
            #if LOCAL_DEVICE_TESTING
            Label("実機テスト・記録はこの端末に保存", systemImage: "iphone")
                .font(.caption).frame(maxWidth: .infinity)
                .padding(.vertical, 6).background(.regularMaterial)
            #else
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

/// The reorderable sections on the Overview tab, below the fixed hero card. Order is a
/// per-device UI preference (not app data), persisted directly as a plain string array —
/// no need for the JSON machinery ShiftStore uses for real records.
private enum OverviewCardKind: String, CaseIterable, Identifiable {
    case incomeWall, employer, category
    var id: String { rawValue }
}

private struct OverviewTab: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.locale) private var locale
    @Binding var month: String
    @Binding var selectedTab: AppTab
    @Binding var requestedShiftDate: String?
    @State private var showSettings = false
    @State private var showNotifications = false
    @AppStorage("shiftmgr.showBalance") private var showBalance = true
    @State private var cardOrder: [OverviewCardKind] = OverviewTab.loadCardOrder()
    @State private var paydayPrompt: PaydayPrompt?

    private static let cardOrderKey = "shiftmgr.overviewCardOrder"
    private static func loadCardOrder() -> [OverviewCardKind] {
        guard let raw = UserDefaults.standard.array(forKey: cardOrderKey) as? [String] else {
            return OverviewCardKind.allCases
        }
        let parsed = raw.compactMap { OverviewCardKind(rawValue: $0) }
        let missing = OverviewCardKind.allCases.filter { !parsed.contains($0) }
        // A card added after someone saved their order lands at the end of it by default; the
        // 年収の壁 card goes to the top instead, since a new feature parked below the fold is one
        // nobody finds.
        let leading = missing.filter { $0 == .incomeWall }
        return leading + parsed + missing.filter { $0 != .incomeWall }
    }
    private func persistCardOrder() {
        UserDefaults.standard.set(cardOrder.map(\.rawValue), forKey: Self.cardOrderKey)
    }

    private var monthShifts: [Shift] { store.shifts.filter { $0.date.hasPrefix(month) } }
    private var monthExpenses: [Expense] { store.expenses.filter { $0.date.hasPrefix(month) } }
    private var payslip: MonthlyPayslip { Aggregation.calculateMonthlyPay(monthShifts, classifications: store.classifications) }
    private var expenseTotal: Double { monthExpenses.reduce(0) { $0 + $1.amount } }
    private var balance: Double { payslip.grossTotal - expenseTotal }

    /// One employer's contribution to this month's *payday-basis* total — the money that
    /// actually lands (or is expected to land) in this calendar month, as opposed to
    /// `payslip`'s work-date basis (shifts worked this month, regardless of when paid).
    private var paydayBasisEntries: [PaydayIncomeEntry] {
        Aggregation.paydayIncomeEntries(month: month, shifts: store.shifts,
            profiles: store.employerProfiles, actualPayments: store.actualPayments,
            classifications: store.classifications)
    }
    private var paydayBasisIncome: Double { paydayBasisEntries.reduce(0) { $0 + $1.amount } }
    private var paydayBasisBalance: Double { paydayBasisIncome - expenseTotal }

    private var byEmployer: [(name: String, pay: Double)] {
        var map: [String: Double] = [:]
        for entry in paydayBasisEntries { map[entry.employer, default: 0] += entry.amount }
        return map.map { (name: $0.key, pay: $0.value) }.sorted { $0.pay > $1.pay }
    }
    private var byCategory: [(category: String, amount: Double)] {
        var map: [String: Double] = [:]
        for e in monthExpenses { map[e.category, default: 0] += e.amount }
        return map.map { (category: $0.key, amount: $0.value) }.sorted { $0.amount > $1.amount }
    }
    private var maxCategoryAmount: Double { byCategory.first?.amount ?? 1 }

    /// Month-over-month change, for the "+12% this month"-style trend line — real, not
    /// decorative: compares this month's balance to the previous month's.
    private var previousMonthBalance: Double {
        let prevMonth = DateUtils.shiftMonth(month, by: -1)
        let prevShifts = store.shifts.filter { $0.date.hasPrefix(prevMonth) }
        let prevExpenses = store.expenses.filter { $0.date.hasPrefix(prevMonth) }
        let prevGross = Aggregation.calculateMonthlyPay(prevShifts, classifications: store.classifications).grossTotal
        let prevExpenseTotal = prevExpenses.reduce(0) { $0 + $1.amount }
        return prevGross - prevExpenseTotal
    }
    private var monthOverMonthChange: Double? {
        guard previousMonthBalance != 0 else { return nil }
        return (balance - previousMonthBalance) / abs(previousMonthBalance)
    }

    /// Running (income − expenses) balance for each day of the visible month — the data
    /// behind the hero card's background sparkline. Real numbers, not decoration: day 1
    /// starts at 0 and each day adds that day's net shift pay minus that day's expenses.
    private struct BalancePoint { let day: Int; let balance: Double }
    private var cumulativeSeries: [BalancePoint] {
        guard let (y, m, _) = DateUtils.parseYMD(month + "-01") else { return [] }
        let daysInMonth = DateUtils.lastDayOfMonth(year: y, month: m)
        var dailyNet: [Int: Double] = [:]
        for s in monthShifts {
            guard let day = Int(s.date.suffix(2)) else { continue }
            dailyNet[day, default: 0] += PayCalculation.pay(for: s, classifications: store.classifications).netPay
        }
        for e in monthExpenses {
            guard let day = Int(e.date.suffix(2)) else { continue }
            dailyNet[day, default: 0] -= e.amount
        }
        var running = 0.0
        var series: [BalancePoint] = []
        for day in 1...daysInMonth {
            running += dailyNet[day] ?? 0
            series.append(BalancePoint(day: day, balance: running))
        }
        return series
    }

    /// Any employer whose (weekend/holiday-adjusted) payday is today and who hasn't had a
    /// figure recorded yet for it. Walks a small window of candidate period-ends rather than
    /// relying on `PayPeriod.period(forDate:)` — that returns the period still IN PROGRESS,
    /// not the one that just closed and is being paid out today, which is what matters here.
    private var pendingPaydays: [PaydayPrompt] {
        let today = DateUtils.todayYMD()
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
                let alreadyRecorded = store.actualPayments.contains { $0.employer == profile.name && $0.payDate == payDate }
                if !alreadyRecorded {
                    results.append(PaydayPrompt(profile: profile, payDate: payDate))
                }
                break
            }
        }
        return results
    }

    var body: some View {
        NavigationStack {
            // `heroPager`'s paging TabView needs to sit outside the List entirely — nested
            // inside a List row, its swipe gesture never wins against the List's own
            // UITableView-backed scroll gesture, so the page never turns.
            VStack(spacing: 0) {
                heroPager
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                    .readableColumn()

                List {
                if month == String(DateUtils.todayYMD().prefix(7)), let shift = upcomingShift {
                    upcomingShiftCard(shift)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .readableColumn()
                }
                ForEach(pendingPaydays) { prompt in
                    PaydayBanner(prompt: prompt) { paydayPrompt = prompt }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .readableColumn()
                }

                if !store.shifts.isEmpty {
                    NavigationLink { PlusView() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("これからのお金を見通す").font(.subheadline.weight(.semibold))
                                Text("残高予測を7日分、無料で試せます。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }.appCard()
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                    .readableColumn()
                }

                ForEach(cardOrder) { kind in
                    cardView(for: kind)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .readableColumn()
                }
                .onMove { indices, newOffset in
                    cardOrder.move(fromOffsets: indices, toOffset: newOffset)
                    persistCardOrder()
                }

                if monthShifts.isEmpty && monthExpenses.isEmpty && paydayBasisEntries.isEmpty {
                    // A first launch lands here with nothing else on screen, so this is the whole
                    // first impression — it names what to do next rather than only reporting
                    // that the month is empty.
                    VStack(spacing: 10) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(Color.accentColor)
                        Text("この月の記録はまだありません")
                            .font(.subheadline).fontWeight(.semibold)
                        Text("「シフト」タブでカレンダーの日付を選ぶと、勤務を記録できます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            selectedTab = .shifts
                        } label: {
                            Label("シフトを記録する", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .appCard(padding: 28)
                    .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                        .readableColumn()
                }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .background(Color(.systemGroupedBackground))
            // Without this the stack reserves large-title height for a title this screen never
            // sets, leaving ~70pt of empty page above the hero card.
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { settingsButton }
                ToolbarItem(placement: .principal) { monthNav }
                ToolbarItem(placement: .navigationBarTrailing) { notificationsButton }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showNotifications) { NotificationListView().environmentObject(notifications) }
            .sheet(item: $paydayPrompt) { prompt in
                ActualPaySheet(prompt: prompt).environmentObject(store)
            }
        }
    }

    private var upcomingShift: Shift? {
        let today = DateUtils.todayYMD()
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

    @ViewBuilder
    private func cardView(for kind: OverviewCardKind) -> some View {
        switch kind {
        case .incomeWall:
            IncomeWallCard(year: Int(month.prefix(4)) ?? DateUtils.calendar.component(.year, from: Date()))
        case .employer:
            if !byEmployer.isEmpty { employerCard }
        case .category:
            if !byCategory.isEmpty { categoryCard }
        }
    }

    private var employerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader("勤務先別の給与", systemImage: "briefcase.fill")
            ForEach(byEmployer, id: \.name) { item in
                HStack {
                    Text(item.name)
                    Spacer()
                    Text(showBalance ? yen(item.pay) : "••••").fontWeight(.semibold).foregroundStyle(.green)
                }
                .font(.subheadline)
            }
            if paydayBasisEntries.contains(where: { !$0.isActual }) {
                Text("予測は控除前の支給額、実績は入力した手取り額です。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .appCard()
    }

    private var categoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader("支出カテゴリ別", systemImage: "chart.pie.fill")
            ForEach(byCategory, id: \.category) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(expenseCategoryColors[item.category] ?? .gray).frame(width: 8, height: 8)
                            Text(LocalizedStringKey(item.category)).font(.subheadline)
                        }
                        Spacer()
                        Text(yen(item.amount)).font(.subheadline).fontWeight(.semibold)
                    }
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(.tertiarySystemGroupedBackground))
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(expenseCategoryColors[item.category] ?? .gray)
                                    .frame(width: geo.size.width * (item.amount / maxCategoryAmount))
                            }
                    }
                    .frame(height: 6)
                }
            }
        }
        .appCard()
    }

    private var monthNav: some View {
        HStack(spacing: 4) {
            Button { month = DateUtils.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left").frame(minWidth: 32, minHeight: 40).contentShape(Rectangle()) }
                .accessibilityLabel("前の月")
            Text(DateUtils.monthLabel(month, locale: locale)).font(.headline).frame(minWidth: 78)
            Button { month = DateUtils.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right").frame(minWidth: 32, minHeight: 40).contentShape(Rectangle()) }
                .accessibilityLabel("次の月")
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(Capsule())
    }

    /// Placed as a real navigation-bar `ToolbarItem` in `body`, not as a manually-positioned
    /// corner button — a SwiftUI-positioned button in roughly the same spot rendered correctly
    /// but silently ate every tap within about 75pt of the screen's edges (reproduced with a
    /// 100x100 test target, independent of ZStack vs. `.overlay` vs. plain-HStack layout),
    /// consistent with this simulator reserving that strip for edge system gestures. A real
    /// toolbar button's hit-testing goes through UIKit's own navigation bar, which is unaffected.
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

    private static let chartGreen = Color(red: 0.20, green: 0.87, blue: 0.53)
    private static let chartRed = Color(red: 1.0, green: 0.30, blue: 0.32)

    /// Stock-ticker convention: the line (and its area fill) reads as a loss in red the moment
    /// this month's balance dips below where it started, gain in green otherwise — not tied to
    /// month-over-month change, which is a separate comparison shown in the badge below.
    private var isChartTrendingDown: Bool {
        guard let first = cumulativeSeries.first, let last = cumulativeSeries.last else { return false }
        return last.balance < first.balance
    }

    private var heroCard: some View {
        let chartColor = isChartTrendingDown ? Self.chartRed : Self.chartGreen
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
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Day", point.day), y: .value("Balance", point.balance))
                        .foregroundStyle(chartColor)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
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
                    Text("勤務月ベースの収支")
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

                Text(showBalance ? (balance < 0 ? "−" : "") + yen(abs(balance)) : "••••••••")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.top, 12)

                HStack(spacing: 6) {
                    if let change = monthOverMonthChange {
                        Text((change >= 0 ? "↑ " : "↓ ") + String(format: "%.0f%%", abs(change) * 100))
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background((change >= 0 ? Color.green : Color.red).opacity(0.28))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                    Text(showBalance ? LocalizedStringKey("収入 \(yen(payslip.grossTotal))・支出 \(yen(expenseTotal))") : "収入 ••••・支出 ••••")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 28)
        }
        .frame(height: 220)
        .heroCardShape()
    }

    /// Second page of the hero pager — the same balance figure computed on a payday basis
    /// instead of a work-date basis, so the two philosophies (see `heroCard` vs this) sit side
    /// by side rather than forcing one interpretation of "this month" onto the other.
    private var paydayAmountCard: some View {
        ZStack(alignment: .topLeading) {
            heroCardBase
            Circle().fill(Color.white.opacity(0.10)).frame(width: 200, height: 200).blur(radius: 55).offset(x: -90, y: -100)
            Circle().fill(Color.white.opacity(0.06)).frame(width: 240, height: 240).blur(radius: 65).offset(x: 140, y: 120)

            // Spaced by grouping rather than one uniform gap: the label belongs to the figure
            // directly beneath it, so those two sit close, and the real breathing room goes
            // between that headline block and the per-employer breakdown. A flat 14pt everywhere
            // also overran the card's height, at which point SwiftUI compressed every line at
            // once — which is what made the top of the card read as cramped.
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("今月の支給額")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                    Button { showBalance.toggle() } label: {
                        Image(systemName: showBalance ? "eye.fill" : "eye.slash.fill")
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .accessibilityLabel("金額の表示を切り替える")
                }

                Text(showBalance ? yen(paydayBasisIncome) : "••••••••")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.top, 12)

                Text(showBalance ? LocalizedStringKey("支出 \(yen(expenseTotal))・差引 \(yen(paydayBasisBalance))") : "支出 ••••・差引 ••••")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 10)

                if paydayBasisEntries.isEmpty {
                    Text("この月の支給予定はまだありません")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 18)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(paydayBasisEntries.prefix(2))) { entry in
                            HStack(spacing: 6) {
                                Text(entry.employer)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(LocalizedStringKey(entry.isActual ? "実績" : "推定"))
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background((entry.isActual ? Color.green : Color.white).opacity(0.22))
                                    .clipShape(Capsule())
                                Spacer()
                                Text(showBalance ? yen(entry.amount) : "••••")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .padding(.top, 14)
                    if paydayBasisEntries.count > 2 {
                        Text("ほか\(paydayBasisEntries.count - 2)件・詳細は給与タブへ")
                            .font(.caption2).foregroundStyle(.white.opacity(0.6))
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 28)
        }
        .frame(height: 220)
        .heroCardShape()
    }

    /// Custom drag-based pager instead of `TabView(.page)` — the system page view controller
    /// requires a swipe past ~50% of the card's width before it commits to turning the page,
    /// which reads as unresponsive for a 2-page card. A `DragGesture` lets the page turn on a
    /// much shorter, more natural flick (~18% of the width, or a fast enough flick regardless
    /// of distance via `predictedEndTranslation`).
    private var heroPager: some View {
        // Payday-basis first: attributing a shift's pay to whichever calendar month it happens
        // to fall in — the work-date card, second page — reads as wrong the moment a pay period
        // crosses a month boundary (worked in September, paid in October is not "September's
        // income"). The payday basis is the one that matches an actual deposit, so it's the
        // default view; the work-date breakdown is still one swipe away for whoever wants it.
        SwipeableHeroCards(pageA: paydayAmountCard, pageB: heroCard)
    }
}

/// Pulled out of `OverviewTab` so the drag has somewhere cheap to live: `heroPage`/`dragOffset`
/// used to be `@State` on `OverviewTab` itself, meaning every pixel of drag re-ran that view's
/// `body` — and with it every computed property `heroCard`/`paydayAmountCard` touch along the
/// way (`cumulativeSeries`, `paydayBasisEntries`, both of which walk shifts/employers with
/// nested loops) — dozens of times a second. `pageA`/`pageB` are built *once* per real
/// `OverviewTab.body` pass and handed in as already-materialized views; dragging here only
/// touches this struct's own state, so SwiftUI re-renders just this subtree instead of
/// recomputing the cards it was handed.
private struct SwipeableHeroCards<PageA: View, PageB: View>: View {
    let pageA: PageA
    let pageB: PageB

    @State private var page: Int = 0
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // The two pages laid out side by side are twice `width` wide; without pinning
            // this HStack's own reported size back down to a single page via `.frame(...)`
            // (leading-anchored, so the offset below still lines up) and `.clipped()`, the
            // oversized content leaks past the right edge and throws off the dot overlay's
            // centering, which otherwise inherits that same oversized bounding box.
            HStack(spacing: 0) {
                // `.drawingGroup()` flattens each card (several blurred circles, a Chart, a
                // gradient mask) into a single cached bitmap instead of leaving them as separate
                // layers Core Animation has to re-composite on every frame of the drag — moving
                // one texture is cheap, re-blurring five overlapping circles at 60fps is not, and
                // that per-frame recompositing cost was the other half of the reported lag (the
                // computed-property recomputation this struct itself exists to avoid was the
                // first half).
                pageA.frame(width: width).drawingGroup()
                pageB.frame(width: width).drawingGroup()
            }
            .offset(x: -CGFloat(page) * width + dragOffset)
            .frame(width: width, height: 220, alignment: .leading)
            .clipped()
            // Exclusive `.gesture`, not `.simultaneousGesture` — this pager no longer lives
            // inside anything that competes for the same horizontal touches (it was pulled out
            // of the List entirely earlier), so there's nothing left to share recognition with,
            // and letting some ancestor gesture (e.g. the navigation stack's own edge-pan
            // recognizer) track the same touches at the same time was part of what made the
            // drag feel inconsistent — sometimes tracking smoothly, sometimes not.
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        var translation = value.translation.width
                        // Rubber-band at the ends instead of dragging past page 0/1.
                        if (page == 0 && translation > 0) || (page == 1 && translation < 0) {
                            translation *= 0.35
                        }
                        dragOffset = translation
                    }
                    .onEnded { value in
                        let distanceThreshold = width * 0.18
                        let flickThreshold = width * 0.5
                        let translation = value.translation.width
                        let predicted = value.predictedEndTranslation.width
                        if (translation < -distanceThreshold || predicted < -flickThreshold), page < 1 {
                            page += 1
                        } else if (translation > distanceThreshold || predicted > flickThreshold), page > 0 {
                            page -= 1
                        }
                        withAnimation(.interactiveSpring(response: 0.35, dampingFraction: 0.86)) {
                            dragOffset = 0
                        }
                    }
            )
            .animation(.interactiveSpring(response: 0.35, dampingFraction: 0.86), value: page)
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Button { page = 0; dragOffset = 0 } label: {
                        Text("支給月").font(.system(size: 10, weight: .semibold))
                            .frame(width: 58, height: 28)
                            .foregroundStyle(page == 0 ? .white : .white.opacity(0.55))
                            .background(.white.opacity(page == 0 ? 0.16 : 0), in: Capsule())
                    }
                    .frame(height: 44).contentShape(Rectangle())
                    .accessibilityAddTraits(page == 0 ? .isSelected : [])
                    Button { page = 1; dragOffset = 0 } label: {
                        Text("勤務月").font(.system(size: 10, weight: .semibold))
                            .frame(width: 58, height: 28)
                            .foregroundStyle(page == 1 ? .white : .white.opacity(0.55))
                            .background(.white.opacity(page == 1 ? 0.16 : 0), in: Capsule())
                    }
                    .frame(height: 44).contentShape(Rectangle())
                    .accessibilityAddTraits(page == 1 ? .isSelected : [])
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 220)
    }
}

private struct PaydayPrompt: Identifiable {
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
                Text("実際の手取り額を記録しましょう")
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

/// Sheet opened from the payday banner to record the real amount that landed in the bank —
/// deliberately just one field, since the whole point is this takes five seconds on payday.
private struct ActualPaySheet: View {
    let prompt: PaydayPrompt
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    @State private var amountText = ""
    @FocusState private var amountFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("勤務先", value: prompt.profile.name)
                    LabeledContent("支給日", value: DateUtils.formatFullDate(prompt.payDate, locale: locale))
                }
                Section("実際に振り込まれた手取り額") {
                    TextField("円", text: $amountText)
                        .keyboardType(.numberPad)
                        .focused($amountFocused)
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
                        if let amount = Double(amountText), amount.isFinite, amount > 0 {
                            store.recordActualPayment(employer: prompt.profile.name, payDate: prompt.payDate, amount: amount)
                        }
                        dismiss()
                    }
                    .disabled(Double(amountText).map { !$0.isFinite || $0 <= 0 } ?? true)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { amountFocused = true }
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(ShiftStore())
        .environmentObject(SubscriptionManager())
}
