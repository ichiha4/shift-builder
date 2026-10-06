import SwiftUI

/// Where the 年収の壁 answers live. Device-only on purpose: a birth date sent to Firestore would be a
/// new category of collected personal data, which the privacy policy and the App Store privacy
/// declaration would both have to disclose. Kept on the device it is never "collected" at all.
/// Forgotten on sign-out and account deletion with the rest of the account's device data
/// (`ShiftStore.wipeLocalData`).
enum IncomeWallSettings {
    static let dependencyKey = "shiftmgr.walls.dependency"
    static let birthDateKey = "shiftmgr.walls.birthDate"
}

private extension IncomeWalls.Dependency {
    var label: LocalizedStringKey {
        switch self {
        case .parent: return "親などの扶養に入っている"
        case .spouse: return "配偶者の扶養に入っている"
        case .none: return "扶養に入っていない"
        }
    }
}

private extension Locale {
    var isJapanese: Bool { language.languageCode?.identifier == "ja" }
}

/// "178万円" in Japanese; "¥1,780,000" otherwise, since 万 has no English equivalent.
private func manYen(_ amount: Int, _ locale: Locale) -> String {
    locale.isJapanese && amount % 10_000 == 0 ? "\(amount / 10_000)万円" : yen(Double(amount))
}

/// "10月" / "October".
private func monthName(_ ymd: String, _ locale: Locale) -> String {
    guard let (y, m, _) = DateUtils.parseYMD(ymd) else { return ymd }
    if locale.isJapanese { return "\(m)月" }
    return DateUtils.date(year: y, month: m, day: 1).formatted(.dateTime.month(.wide).locale(locale))
}

/// "11月30日" / "Nov 30".
private func monthDay(_ ymd: String, _ locale: Locale) -> String {
    guard let (y, m, d) = DateUtils.parseYMD(ymd) else { return ymd }
    if locale.isJapanese { return "\(m)月\(d)日" }
    return DateUtils.date(year: y, month: m, day: d).formatted(.dateTime.month(.abbreviated).day().locale(locale))
}

/// Shared computation for the card and the detail screen, so the two can never disagree.
@MainActor
private struct WallSnapshot {
    let year: Int
    let today: String
    let walls: [IncomeWalls.Wall]?
    let income: IncomeWalls.AnnualIncome
    let dependency: IncomeWalls.Dependency?
    let birthDate: String?
    let needsBirthDate: Bool
    /// Age as 健康保険・年金 count it today (a year older from the day before the birthday).
    let ageNow: Int?
    /// Age on 31 December of `year`, as the tax rules count it.
    let ageAtYearEnd: Int?
    /// False from the 75th birthday: 後期高齢者医療, so no 健康保険 被扶養者 at all.
    let canBeHealthDependent: Bool?

    init(store: ShiftStore, year: Int, dependencyRaw: String, birthDate: String) {
        let today = DateUtils.todayYMD()
        self.year = year
        self.today = today
        let dependency = IncomeWalls.Dependency(rawValue: dependencyRaw)
        let birth: String? = birthDate.isEmpty ? nil : birthDate
        self.dependency = dependency
        self.birthDate = birth
        self.needsBirthDate = (dependency == .parent || dependency == .spouse) && birth == nil
        self.walls = dependency.flatMap {
            IncomeWalls.walls(year: year, dependency: $0, birthDate: birth, today: today)
        }
        self.ageNow = birth.flatMap { IncomeWalls.socialInsuranceAge(birthDate: $0, today: today) }
        self.canBeHealthDependent = birth.flatMap { IncomeWalls.canBeHealthDependent(birthDate: $0, today: today) }
        self.ageAtYearEnd = birth.flatMap(DateUtils.parseYMD).map {
            IncomeWalls.ageAtYearEnd(birthYear: $0.year, birthMonth: $0.month, birthDay: $0.day, year: year)
        }
        // Every shift: an employer's earliest one decides where its pace window starts.
        self.income = IncomeWalls.annualIncome(year: year, today: today,
                                               shifts: store.shifts,
                                               profiles: store.employerProfiles,
                                               classifications: store.classifications)
    }

    var isSupportedYear: Bool { IncomeWalls.supportedYears.contains(year) }

    /// No work still to be done can change this year's total any more: the last pay period paid in
    /// the year has ended (or, with nothing entered, the year itself has).
    var isYearClosed: Bool { (income.lastCountingWorkDate ?? String(format: "%04d-12-31", year)) < today }
    /// Every payday of the year has passed as well — the total is final, not just determined.
    var isYearPaid: Bool { isYearClosed && income.paydays.allSatisfy { $0.date <= today } }

    var taxWalls: [IncomeWalls.Wall] { walls?.filter { $0.basis == .taxYear } ?? [] }
    /// Tax walls pay already received has gone over — nothing can undo these.
    var passedTaxWalls: [IncomeWalls.Wall] { taxWalls.filter { $0.isExceeded(by: income.paidToDate.rounded()) } }
    /// The lowest tax wall the year-end figure goes over that isn't already passed.
    var firstUpcomingExceededTaxWall: IncomeWalls.Wall? {
        taxWalls.first { !$0.isExceeded(by: income.paidToDate.rounded()) && $0.isExceeded(by: projectedYen) }
    }
    /// The lowest tax wall the year-end figure stays under.
    var nextTaxWall: IncomeWalls.Wall? { taxWalls.first { !$0.isExceeded(by: projectedYen) } }
    var healthWall: IncomeWalls.Wall? { walls?.first { $0.basis == .forwardYear } }

    /// The year-end projection at whole yen — the figure on screen. The raw value carries
    /// floating-point dust (a pace of ¥390,000 / 90 days makes 45 days come to ¥194,999.99999…),
    /// and working from it turned "¥207,500 ÷ ¥1,250" into 165 hours instead of 166.
    var projectedYen: Double { income.projectedTotal.rounded() }

    /// Hours of room left, at the best-paid job's rate and rounded DOWN, so the app never
    /// promises time that isn't there whichever job the hours go to.
    func hoursOfRoom(_ yen: Double) -> Int? {
        guard let perHour = income.highestTaxablePerHour, perHour > 0, yen > 0 else { return nil }
        return Int((yen / perHour + 1e-9).rounded(.down))
    }

    /// Hours to cut back, at the lowest-paid job's rate and rounded UP, so following the advice
    /// gets back under the line whichever job the hours come from.
    func hoursToCut(_ yen: Double) -> Int? {
        guard let perHour = income.lowestTaxablePerHour, perHour > 0, yen > 0 else { return nil }
        return Int((yen / perHour - 1e-9).rounded(.up))
    }
}

/// The year-end figure's label: an estimate while work can still change it, then determined,
/// then final once every payday has passed.
@MainActor
private func totalLabel(_ snap: WallSnapshot) -> LocalizedStringKey {
    snap.isYearPaid ? "年収(確定)" : (snap.isYearClosed ? "年収(確定見込み)" : "年末見込み")
}

// MARK: - Home card

struct IncomeWallCard: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.locale) private var locale
    let year: Int
    @AppStorage(IncomeWallSettings.dependencyKey) private var dependencyRaw = ""
    @AppStorage(IncomeWallSettings.birthDateKey) private var birthDate = ""
    @State private var showDetail = false

    var body: some View {
        let snap = WallSnapshot(store: store, year: year, dependencyRaw: dependencyRaw, birthDate: birthDate)
        Button { showDetail = true } label: {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader("年収の壁 \(String(year))年", systemImage: "chart.bar.xaxis") {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                content(snap)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .appCard()
        .sheet(isPresented: $showDetail) {
            IncomeWallDetailView(year: year).environmentObject(store)
        }
    }

    @ViewBuilder
    private func content(_ snap: WallSnapshot) -> some View {
        if !snap.isSupportedYear {
            Text("この年の壁の金額には対応していません。")
                .font(.caption).foregroundStyle(.secondary)
        } else if snap.dependency == nil {
            Text("扶養の状況を設定すると、\(String(year))年にあといくら働けるかが分かります。")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("設定する").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.accentColor)
        } else if snap.needsBirthDate {
            Text("生年月日を入力すると、\(String(year))年にあといくら働けるかが分かります。")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("入力する").font(.subheadline).fontWeight(.semibold).foregroundStyle(Color.accentColor)
        } else if snap.walls != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(totalLabel(snap)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(yen(snap.projectedYen)).font(.title3).fontWeight(.bold)
                }
                WallBar(value: snap.projectedYen, walls: snap.taxWalls,
                        muted: snap.income.taxPaceIsTentative && !snap.isYearClosed)
                if let passed = snap.passedTaxWalls.last {
                    Label("\(manYen(passed.limit, locale))を超えました", systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let over = snap.firstUpcomingExceededTaxWall {
                    upcomingLine(over, snap: snap)
                } else if let next = snap.nextTaxWall {
                    let room = Double(next.limit) - snap.projectedYen
                    Group {
                        if snap.isYearClosed {
                            Text("\(manYen(next.limit, locale))まで残り\(yen(room))")
                        } else if let hours = snap.hoursOfRoom(room) {
                            Text("次の壁\(manYen(next.limit, locale))まで、あと\(yen(room))(約\(hours)時間)")
                        } else {
                            Text("次の壁\(manYen(next.limit, locale))まで、あと\(yen(room))")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                if let health = snap.healthWall, let est = snap.income.forwardAnnualEstimate?.rounded() {
                    healthLine(health, estimate: est)
                }
                if snap.income.healthPaceIsTentative || (snap.income.taxPaceIsTentative && !snap.isYearClosed) {
                    Text("記録が少ないため、予測は目安です。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func upcomingLine(_ wall: IncomeWalls.Wall, snap: WallSnapshot) -> some View {
        let crossing = IncomeWalls.crossingPayday(of: wall, in: snap.income).map { monthName($0, locale) }
        Label {
            if snap.isYearClosed, let crossing {
                Text("\(crossing)の支給で\(manYen(wall.limit, locale))を超えます")
            } else if let crossing {
                Text("\(crossing)の支給で\(manYen(wall.limit, locale))超の見込み")
            } else {
                Text("\(manYen(wall.limit, locale))を超える見込みです")
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(Color.orange)
    }

    private func healthLine(_ wall: IncomeWalls.Wall, estimate: Double) -> some View {
        let over = wall.isExceeded(by: estimate)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("健康保険の扶養", systemImage: over ? "exclamationmark.triangle.fill" : "checkmark.circle")
                Spacer(minLength: 8)
                Text(LocalizedStringKey(over ? "基準超の見込み" : "基準内の見込み"))
            }
            .foregroundStyle(over ? Color.orange : Color.secondary)
            Text("年間目安\(yen(estimate))・基準\(manYen(wall.limit, locale))未満")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }

}

/// Progress toward the tax walls, with a tick at each one. Decorative for VoiceOver: the same
/// figures are read out as text right around it.
private struct WallBar: View {
    let value: Double
    let walls: [IncomeWalls.Wall]
    /// A rough (tentative) projection: shown without the warning colour, like the text beside it.
    var muted = false

    var body: some View {
        let top = Double((walls.map(\.limit).max() ?? 1) ) * 1.08
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemGroupedBackground))
                Capsule()
                    .fill(walls.contains { $0.isExceeded(by: value) } ? (muted ? Color.gray : Color.orange) : Color.green)
                    .frame(width: max(6, min(w, w * value / top)))
                ForEach(walls, id: \.kind) { wall in
                    Rectangle()
                        .fill(Color.primary.opacity(0.35))
                        .frame(width: 2, height: 14)
                        .offset(x: w * Double(wall.limit) / top - 1)
                }
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}

// MARK: - Detail

struct IncomeWallDetailView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    let year: Int
    @AppStorage(IncomeWallSettings.dependencyKey) private var dependencyRaw = ""
    @AppStorage(IncomeWallSettings.birthDateKey) private var birthDate = ""
    @State private var editingBirthDate = false

    private var birthDateBinding: Binding<Date> {
        Binding(
            get: {
                guard let (y, m, d) = DateUtils.parseYMD(birthDate) else { return DateUtils.date(year: 2006, month: 1, day: 1) }
                return DateUtils.date(year: y, month: m, day: d)
            },
            set: { birthDate = DateUtils.ymd($0) }
        )
    }

    var body: some View {
        let snap = WallSnapshot(store: store, year: year, dependencyRaw: dependencyRaw, birthDate: birthDate)
        NavigationStack {
            Form {
                situationSection(snap)
                if !snap.isSupportedYear {
                    Section { Text("この年の壁の金額には対応していません。") }
                } else if let walls = snap.walls, !snap.needsBirthDate {
                    incomeSection(snap)
                    Section {
                        ForEach(walls, id: \.kind) { wall in wallRow(wall, snap: snap) }
                    } header: {
                        Text("壁")
                    } footer: {
                        wallsFooter(snap)
                    }
                    notesSection(snap)
                }
            }
            .navigationTitle("年収の壁 \(String(year))年")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("閉じる") { dismiss() } }
            }
            .sheet(isPresented: $editingBirthDate) {
                BirthDateEntry(initial: birthDateBinding.wrappedValue) { birthDate = DateUtils.ymd($0) }
            }
        }
    }

    private func situationSection(_ snap: WallSnapshot) -> some View {
        Section {
            Picker("扶養の状況", selection: $dependencyRaw) {
                Text("選択してください").tag("")
                ForEach(IncomeWalls.Dependency.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
            }
            if snap.dependency == .parent || snap.dependency == .spouse {
                if birthDate.isEmpty {
                    Button("生年月日を入力") { editingBirthDate = true }
                } else {
                    DatePicker("生年月日", selection: birthDateBinding,
                               in: DateUtils.date(year: 1920, month: 1, day: 1)...Date(),
                               displayedComponents: .date)
                    if let age = snap.ageAtYearEnd {
                        Text("\(String(year))年12月31日時点で\(age)歳").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("生年月日を削除", role: .destructive) { birthDate = "" }
                }
            }
        } header: {
            Text("あなたの状況")
        } footer: {
            Text("年齢によって当てはまる壁が変わるため、扶養に入っている場合は生年月日が必要です。この情報は端末内にのみ保存され、外部には送信されません。")
        }
    }

    private func incomeSection(_ snap: WallSnapshot) -> some View {
        let i = snap.income
        return Section {
            LabeledContent("支給済み", value: yen(i.paidToDate))
            LabeledContent("入力済みのシフト(今後の支給)", value: yen(i.scheduled))
            if !snap.isYearClosed || i.projectedExtra > 0 {
                LabeledContent("未入力分の見込み", value: yen(i.projectedExtra))
            }
            LabeledContent {
                Text(yen(snap.projectedYen)).fontWeight(.bold)
            } label: {
                Text(totalLabel(snap)).fontWeight(.bold)
            }
        } header: {
            Text("\(String(year))年の年収(税金の計算)")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("税金の年収は、働いた日ではなく給料の支給日で数えます。12月に働いて翌年1月に支給される分は翌年に入ります。交通費は含めていません。未入力分は直近の働き方のペースで見込んでいます。")
                if !snap.isYearClosed {
                    let ends = i.countingWorkEnd.sorted { $0.key < $1.key }
                    if Set(ends.map(\.value)).count == 1, let only = ends.first {
                        Text("\(String(year))年の年収に入るのは、\(monthDay(only.value, locale))までの勤務です。")
                    } else if !ends.isEmpty {
                        Text("\(String(year))年の年収に入る勤務:")
                        ForEach(ends, id: \.key) { employer, end in
                            Text("・\(employer): \(monthDay(end, locale))まで")
                        }
                    }
                }
                if snap.isYearClosed {
                    Text("\(String(year))年の支給に入る勤務はすでに終わっています。")
                }
                if i.hasEmployerWithoutPayday {
                    Text("給料日が未設定の勤務先があります。働いた月の月末に支給されるとして数えています。給与タブで給料日を設定すると正確になります。")
                        .foregroundStyle(.orange)
                }
                if i.taxPaceIsTentative && !snap.isYearClosed {
                    Text("記録がまだ少ないため、見込みは目安です。").foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func wallRow(_ wall: IncomeWalls.Wall, snap: WallSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title(for: wall.kind)).fontWeight(.semibold)
                Spacer()
                Group {
                    if wall.basis == .taxYear { Text("\(manYen(wall.limit, locale))以下") } else { Text("\(manYen(wall.limit, locale))未満") }
                }
                .fontWeight(.semibold)
            }
            status(for: wall, snap: snap)
            Text(explanation(for: wall, snap: snap)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func status(for wall: IncomeWalls.Wall, snap: WallSnapshot) -> some View {
        let i = snap.income
        switch wall.basis {
        case .taxYear:
            if wall.isExceeded(by: i.paidToDate.rounded()) {
                Label("すでに超えています", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            } else if wall.isExceeded(by: snap.projectedYen) {
                exceededStatus(wall, snap: snap)
            } else {
                let room = Double(wall.limit) - snap.projectedYen
                Group {
                    if snap.isYearClosed {
                        Label("残り\(yen(room))", systemImage: "checkmark.circle.fill")
                    } else if let hours = snap.hoursOfRoom(room) {
                        Label("あと\(yen(room))(約\(hours)時間)働けます", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("あと\(yen(room))働けます", systemImage: "checkmark.circle.fill")
                    }
                }
                .font(.caption).foregroundStyle(.green)
            }
        case .forwardYear:
            if let est = i.forwardAnnualEstimate?.rounded() {
                let over = wall.isExceeded(by: est)
                let tentative = i.healthPaceIsTentative
                Label("今の年間見込み\(yen(est))",
                      systemImage: over ? "exclamationmark.triangle.fill" : (tentative ? "info.circle" : "checkmark.circle.fill"))
                    .font(.caption).foregroundStyle(over ? Color.orange : (tentative ? Color.secondary : Color.green))
                if tentative {
                    Text("記録が4週間分たまるまでは目安です。").font(.caption).foregroundStyle(.secondary)
                }
                Text("月あたり\(yen(Double(wall.monthlyEquivalent)))以下が目安です")
                    .font(.caption).foregroundStyle(over ? .orange : .secondary)
                Text("直近90日(勤務を始めて90日未満ならその日から)の収入を、交通費を含めて1年分に換算しています。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("働いた記録がないため、まだ見込みを出せません。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func exceededStatus(_ wall: IncomeWalls.Wall, snap: WallSnapshot) -> some View {
        let i = snap.income
        let excess = snap.projectedYen - Double(wall.limit)
        let crossing = IncomeWalls.crossingPayday(of: wall, in: i).map { monthName($0, locale) }
        let tentative = i.taxPaceIsTentative && !snap.isYearClosed
        Label {
            if snap.isYearClosed {
                if let crossing { Text("\(crossing)の支給で超えます") } else { Text("超えます") }
            } else if let crossing, tentative {
                Text("このペースだと\(crossing)の支給で超える見込み(記録が少ないため目安)")
            } else if let crossing {
                Text("このペースだと\(crossing)の支給で超える見込み")
            } else {
                Text("このペースだと超える見込み")
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption).foregroundStyle(Color.orange)

        if wall.kind == .ownIncomeTax {
            // Not a cliff: tax is charged only on the part above it, so there is nothing to "cut
            // back" to — and for anyone paying premiums the real threshold is higher anyway.
            Text("超えた分に対して所得税がかかります。")
                .font(.caption).foregroundStyle(.secondary)
        } else if snap.isYearClosed {
            EmptyView()
        } else if excess <= i.adjustable {
            // Only work not yet done can be cut, and only work up to the last period paid this year.
            Group {
                if let deadline = i.cutBackDeadline, let hours = snap.hoursToCut(excess) {
                    Text("\(monthDay(deadline, locale))までの勤務を約\(hours)時間(\(yen(excess)))減らすと収まる見込みです")
                } else if let deadline = i.cutBackDeadline {
                    Text("\(monthDay(deadline, locale))までの勤務を\(yen(excess))分減らすと収まる見込みです")
                } else if let hours = snap.hoursToCut(excess) {
                    // Employers close on different days — the dates are listed under the income figures.
                    Text("\(String(snap.year))年の年収に入る勤務を約\(hours)時間(\(yen(excess)))減らすと収まる見込みです")
                } else {
                    Text("\(String(snap.year))年の年収に入る勤務を\(yen(excess))分減らすと収まる見込みです")
                }
            }
            .font(.caption).foregroundStyle(.orange)
        } else {
            Text("すでに働いた分だけで超える見込みです。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func title(for kind: IncomeWalls.Kind) -> LocalizedStringKey {
        switch kind {
        case .ownIncomeTax: return "本人の所得税"
        case .dependentDeductionEnds: return "扶養している人の扶養控除"
        case .specificRelativeDeductionDecreases: return "扶養している人の控除が減り始める"
        case .specificRelativeDeductionEnds: return "扶養している人の控除がなくなる"
        case .elderlySpouseDeductionReduced: return "配偶者の控除が下がる"
        case .spouseSpecialDeductionDecreases: return "配偶者の控除が減り始める"
        case .spouseSpecialDeductionEnds: return "配偶者の控除がなくなる"
        case .healthInsuranceDependent: return "健康保険の扶養"
        }
    }

    /// Whole sentences as localization keys (never spliced), so each reads naturally in English.
    private func explanation(for wall: IncomeWalls.Wall, snap: WallSnapshot) -> LocalizedStringKey {
        switch wall.kind {
        case .ownIncomeTax:
            return "社会保険料などの控除がない場合、この金額を超えると所得税がかかり始めます。社会保険料を払っている人は、その分だけかかり始める金額が高くなります。"
        case .dependentDeductionEnds:
            return "超えると、あなたを扶養している人の扶養控除がなくなり、その人の税金が増えます。"
        case .specificRelativeDeductionDecreases:
            return "19〜22歳の特例により、ここまでは扶養している人の控除(63万円)が満額のままです。超えると段階的に減ります。"
        case .specificRelativeDeductionEnds:
            return "超えると、扶養している人の控除(特定親族特別控除)がなくなります。"
        case .elderlySpouseDeductionReduced:
            return "70歳以上の配偶者の控除(48万円)が、超えると配偶者特別控除(38万円)に下がります。"
        case .spouseSpecialDeductionDecreases:
            return "ここまでは配偶者の控除(38万円)が満額のままです。超えると段階的に減ります。"
        case .spouseSpecialDeductionEnds:
            return "超えると、配偶者の控除(配偶者特別控除)がなくなります。"
        case .healthInsuranceDependent:
            guard snap.dependency == .spouse else {
                return "過去の実績ではなく、今後1年間の収入見込み(交通費を含み、通常は残業代も含む)で判定されます。この金額以上になると家族の健康保険の扶養から外れ、ご自身で健康保険に加入する必要があります。"
            }
            // 国民年金の第3号被保険者 exists only from 20 up to (not including) 60.
            if let age = snap.ageNow, (20..<60).contains(age) {
                return "過去の実績ではなく、今後1年間の収入見込み(交通費を含み、通常は残業代も含む)で判定されます。この金額以上になると配偶者の健康保険の扶養から外れます。配偶者が会社員・公務員の場合は国民年金の第3号被保険者からも外れるため、ご自身で健康保険と国民年金に加入する必要があります。"
            }
            return "過去の実績ではなく、今後1年間の収入見込み(交通費を含み、通常は残業代も含む)で判定されます。この金額以上になると配偶者の健康保険の扶養から外れ、ご自身で健康保険に加入する必要があります。"
        }
    }

    @ViewBuilder
    private func wallsFooter(_ snap: WallSnapshot) -> some View {
        if snap.dependency == .parent, let age = snap.ageAtYearEnd, age < 16 {
            Text("16歳未満のため、扶養している人の所得税の扶養控除はもともとありません。")
        } else if snap.dependency == .parent || snap.dependency == .spouse, snap.canBeHealthDependent == false {
            Text("75歳以上は後期高齢者医療制度に加入するため、健康保険の扶養には入れません。")
        }
    }

    private func notesSection(_ snap: WallSnapshot) -> some View {
        Section("ご注意") {
            VStack(alignment: .leading, spacing: 8) {
                Text("金額は概算です。実際の判定は勤務先・健康保険組合・税務署が行います。")
                Text("このアプリに記録したシフトの給与だけで計算しています。記録していない勤務先の給与がある場合は、その分も判定に含まれます。")
                Text("税金の壁は、給与以外に課税される所得(老齢年金など)があると変わります。健康保険の扶養では、年金・失業給付・傷病手当金など非課税の収入も年収に含まれます。")
                Text("本人の所得税の178万円は、基礎控除と給与所得控除だけで計算した目安です。社会保険料控除などがあると、実際に所得税がかかり始める金額はその分高くなります。")
                Text("住民税は自治体によって基準が異なるため、ここでは扱っていません。")
                Text("賞与は記録できないため含まれていません。")
                Text("交通費は非課税として除いています。車・自転車通勤の手当は、距離に応じた上限を超える分が課税されます。")
                if (snap.dependency == .parent || snap.dependency == .spouse) && snap.healthWall != nil {
                    Text("健康保険の扶養は、扶養する人が勤務先の健康保険(協会けんぽ・健康保険組合・共済組合)に入っている場合の基準です。国民健康保険には扶養の仕組みはありません。")
                    Text("健康保険の扶養は、原則として、同居の場合は扶養する人の年収の半分未満、別居の場合は扶養する人からの仕送り額未満であることも条件です。一定の障害(障害厚生年金を受けられる程度)のある方は180万円未満が基準です。")
                    Text("2026年4月から、給与収入だけの場合で、労働条件通知書に勤務時間と賃金が明記されているときは、契約内容から見込まれる年収で判定されることがあります(契約で決まっていない残業代は含まれません)。ただし、「シフト制」などで勤務時間が明記されていない場合、契約期間が扶養に入る日から1年未満の場合、交通費などの手当の金額が書かれていない場合は、これまでどおり実際の収入見込みで判定されます。")
                    Text("人手不足による残業などで一時的に年収が基準を超えた場合は、勤務先の証明があれば、原則として連続2回まで扶養にとどまれます。")
                    Text("勤務先の規模や労働時間によっては、扶養に関係なく勤務先の社会保険に加入となる場合があります。")
                }
                if snap.dependency == .spouse {
                    Text("配偶者の控除額は相手の所得によって変わり、相手の所得が1,000万円を超えると控除は受けられません。")
                    Text("税金の配偶者控除・配偶者特別控除は、法律上の配偶者だけが対象です。事実婚でも、健康保険の扶養(相手が会社員・公務員なら国民年金の第3号被保険者も)は法律上の配偶者と同じ扱いです。")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// First-time birth-date entry: nothing is saved until 決定, so opening the picker can never
/// quietly apply a default age's walls.
private struct BirthDateEntry: View {
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date
    let onSave: (Date) -> Void

    init(initial: Date, onSave: @escaping (Date) -> Void) {
        _date = State(initialValue: initial)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("生年月日", selection: $date,
                           in: DateUtils.date(year: 1920, month: 1, day: 1)...Date(),
                           displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
            }
            .navigationTitle("生年月日")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("決定") { onSave(date); dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }
}
