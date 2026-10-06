import Foundation

/// 年収の壁 — the income levels at which something changes for a part-time worker: their own
/// income tax starts, a parent's or spouse's tax deduction shrinks or ends, or they drop out of a
/// family member's health insurance.
///
/// Every tax figure is stored as the 合計所得 limit the statute actually uses and converted to 給与収入
/// by formula, never typed in as a 給与収入 amount — so the published figures (136万円, 178万円 …) are
/// checked by the tests rather than trusted as transcribed. Sources, all read 2026-09:
/// - 国税庁 No.1410 給与所得控除 / No.1199 基礎控除 / No.1180 扶養控除 / No.1177 特定親族特別控除 /
///   No.1195 配偶者特別控除 / No.2509 給与所得の収入すべき時期
/// - 国税庁 令和8年分 扶養控除等(異動)申告書 (birth-date ranges for the age rules)
/// - 日本年金機構「従業員が家族を被扶養者にするとき」「19歳以上23歳未満の方の被扶養者認定における
///   年間収入要件」「労働契約内容による年間収入での被扶養者の認定の取り扱い」
public enum IncomeWalls {

    public enum Dependency: String, Codable, CaseIterable, Sendable {
        /// 親など(配偶者以外の親族)の扶養に入っている。
        case parent
        /// 配偶者の扶養に入っている。
        case spouse
        /// 誰の扶養にも入っていない。
        case none
    }

    /// The two ways "年収" is counted. They differ in both period and content, and treating them as
    /// one number is the most common mistake made about these walls.
    public enum Basis: Equatable, Sendable {
        /// 所得税・扶養控除: 1月1日〜12月31日に**支給日**が来た給与。非課税の通勤手当は含まない。
        /// (No.2509: 支給日が定められている給与の収入すべき時期は、その支給日)
        case taxYear
        /// 健康保険の被扶養者: 過去の実績ではなく今後1年間の収入見込み。通勤手当・残業代を含む。
        case forwardYear
    }

    public enum Kind: String, Equatable, Sendable {
        /// 本人に所得税がかかる。
        case ownIncomeTax
        /// 親などの扶養控除(一般・老人)がなくなる。
        case dependentDeductionEnds
        /// 19〜22歳: 親の特定親族特別控除が満額(63万円)から減り始める。
        case specificRelativeDeductionDecreases
        /// 19〜22歳: 親の特定親族特別控除がなくなる。
        case specificRelativeDeductionEnds
        /// 70歳以上の配偶者: 老人控除対象配偶者(48万円)から配偶者特別控除(38万円)に下がる。
        case elderlySpouseDeductionReduced
        /// 配偶者の配偶者特別控除が満額(38万円)から減り始める。
        case spouseSpecialDeductionDecreases
        /// 配偶者の配偶者特別控除がなくなる。
        case spouseSpecialDeductionEnds
        /// 家族の健康保険の扶養から外れる。
        case healthInsuranceDependent
    }

    public struct Wall: Equatable, Sendable {
        public let kind: Kind
        public let basis: Basis
        /// Yen.
        public let limit: Int
        /// Tax limits are「以下」— income exactly at the limit is still under. Health insurance is
        ///「未満」— reaching the limit is already over.
        public let stayUnderInclusive: Bool

        public func isExceeded(by income: Double) -> Bool {
            stayUnderInclusive ? income > Double(limit) : income >= Double(limit)
        }

        /// The monthly pay that keeps a `.forwardYear` wall — 日本年金機構 states the 130万円 test as
        /// 月額108,333円以下, i.e. the largest whole-yen monthly figure whose twelve-fold stays under.
        public var monthlyEquivalent: Int { (limit - 1) / 12 }
    }

    /// 令和8年分・令和9年分 only. For 2028 (令和10年分) onward the 基礎控除 changes and the NTA has not
    /// yet published that year's 給与所得控除, so rather than guess, other years are unsupported.
    public static let supportedYears: ClosedRange<Int> = 2026...2027

    // MARK: 令和8年分・令和9年分 — statutory 合計所得 figures

    /// 給与所得控除 for 給与収入 up to 2,200,000円 (No.1410).
    static let salaryIncomeDeduction = 740_000
    /// 基礎控除 for 合計所得 up to 1,320,000円 (No.1199).
    static let basicDeduction = 1_040_000
    /// 扶養親族 / 同一生計配偶者: 合計所得 620,000円以下 (No.1180, No.1195).
    static let dependentIncomeCap = 620_000
    /// 特定親族特別控除: full 63万円 up to 合計所得 850,000円, none above 1,230,000円 (No.1177).
    static let specificRelativeFullCap = 850_000
    static let specificRelativeCap = 1_230_000
    /// 配偶者特別控除 (納税者の合計所得900万円以下): full 38万円 up to 合計所得 950,000円, none above
    /// 1,330,000円 (No.1195). The partner's income changes the amounts, not these limits.
    static let spouseSpecialFullCap = 950_000
    static let spouseSpecialCap = 1_330_000

    // MARK: 健康保険の被扶養者 — annual income, 未満 (日本年金機構)

    static let healthInsuranceGeneral = 1_300_000
    /// 19歳以上23歳未満 on 31 December, excluding spouses; for 扶養認定日 2025-10-01 and later.
    static let healthInsuranceAge19to22 = 1_500_000
    /// 60歳以上, or (not modelled here) a qualifying disability.
    static let healthInsuranceAge60Plus = 1_800_000
    /// From 75 everyone is insured by 後期高齢者医療 and cannot be a 被扶養者 at all
    /// (健康保険法第3条第7項ただし書, 高齢者の医療の確保に関する法律第50条).
    static let latterStageElderlyAge = 75

    /// The 給与収入 that produces a given 合計所得. Exactly `income + 740,000` while the result stays
    /// below 2,191,000円 (No.1410 注2); every wall lands inside that band, which the tests assert.
    static func salaryRevenue(forIncome income: Int) -> Int { income + salaryIncomeDeduction }

    // MARK: Ages

    /// 税法の「その年12月31日現在の年齢」. Under 年齢計算ニ関スル法律 a person gains a year at the end of
    /// the day before their birthday, so someone born on 1 January is already a year older on
    /// 31 December — which is why the NTA's ranges read「平成16年1月2日から平成20年1月1日まで」.
    public static func ageAtYearEnd(birthYear: Int, birthMonth: Int, birthDay: Int, year: Int) -> Int {
        let effectiveBirthYear = (birthMonth == 1 && birthDay == 1) ? birthYear - 1 : birthYear
        return year - effectiveBirthYear
    }

    /// Age on a given date, counting the new year of age from the birthday itself.
    public static func age(birthYear: Int, birthMonth: Int, birthDay: Int,
                           onYear y: Int, month m: Int, day d: Int) -> Int {
        let beforeBirthday = (m, d) < (birthMonth, birthDay)
        return y - birthYear - (beforeBirthday ? 1 : 0)
    }

    /// Age as 健康保険・年金 count it on `today` ("YYYY-MM-DD"): these apply 民法's period rules, so a
    /// person is a year older from the day BEFORE their birthday (厚労省 19〜23歳未満 Q&A Q4:
    /// 「年齢は誕生日の前日において加算する」). Used for the 60歳以上 test and 第3号 (20〜59歳).
    /// Whether someone can be a 健康保険 被扶養者 at all on `today`: not from the 75th birthday
    /// itself, the day 後期高齢者医療 starts (協会けんぽ: 扶養でなくなる日「75歳の誕生日」) — unlike
    /// the other age tests, not from the day before.
    public static func canBeHealthDependent(birthDate: String, today: String) -> Bool? {
        guard let (by, bm, bd) = DateUtils.parseYMD(birthDate), let (y, m, d) = DateUtils.parseYMD(today) else { return nil }
        return age(birthYear: by, birthMonth: bm, birthDay: bd, onYear: y, month: m, day: d) < latterStageElderlyAge
    }

    public static func socialInsuranceAge(birthDate: String, today: String) -> Int? {
        guard let (by, bm, bd) = DateUtils.parseYMD(birthDate),
              let (y, m, d) = DateUtils.parseYMD(addDays(today, 1)) else { return nil }
        return age(birthYear: by, birthMonth: bm, birthDay: bd, onYear: y, month: m, day: d)
    }

    // MARK: Walls

    /// The walls that apply to this person in `year`, lowest first, or nil for an unsupported year.
    /// `birthDate` and `today` are "YYYY-MM-DD"; `birthDate` is only needed for `.parent`/`.spouse`.
    public static func walls(year: Int, dependency: Dependency, birthDate: String?, today: String) -> [Wall]? {
        guard supportedYears.contains(year) else { return nil }

        var result = [Wall(kind: .ownIncomeTax, basis: .taxYear,
                           limit: salaryRevenue(forIncome: basicDeduction), stayUnderInclusive: true)]

        guard dependency != .none else { return result }
        guard let birthDate, let (by, bm, bd) = DateUtils.parseYMD(birthDate),
              let (ty, _, _) = DateUtils.parseYMD(today),
              let ageNow = socialInsuranceAge(birthDate: birthDate, today: today) else { return result }

        // Tax walls belong to the tax year being shown …
        let ageAtYearEnd = ageAtYearEnd(birthYear: by, birthMonth: bm, birthDay: bd, year: year)
        let is19to22 = (19...22).contains(ageAtYearEnd)
        // … but the health-insurance test is about today: the 19〜22 rule reads the 12/31 age of the
        // year that contains the 認定日, whichever tax year is on screen.
        let healthIs19to22 = (19...22).contains(Self.ageAtYearEnd(birthYear: by, birthMonth: bm, birthDay: bd, year: ty))
        let canBeHealthDependent = canBeHealthDependent(birthDate: birthDate, today: today) ?? true

        func taxWall(_ kind: Kind, income: Int) -> Wall {
            Wall(kind: kind, basis: .taxYear, limit: salaryRevenue(forIncome: income), stayUnderInclusive: true)
        }

        switch dependency {
        case .parent:
            if is19to22 {
                // Up to 136万円 the parent claims 特定扶養控除 (63万円); above it, 特定親族特別控除 — also
                // 63万円 — so nothing changes for the parent at 136万円. The first real change is here.
                result.append(taxWall(.specificRelativeDeductionDecreases, income: specificRelativeFullCap))
                result.append(taxWall(.specificRelativeDeductionEnds, income: specificRelativeCap))
            } else if ageAtYearEnd >= 16 {
                result.append(taxWall(.dependentDeductionEnds, income: dependentIncomeCap))
            }
            // Under 16 is 年少扶養親族: the parent gets no 扶養控除 either way, so there is no tax wall.
            if canBeHealthDependent {
                let health = ageNow >= 60 ? healthInsuranceAge60Plus
                    : (healthIs19to22 ? healthInsuranceAge19to22 : healthInsuranceGeneral)
                result.append(Wall(kind: .healthInsuranceDependent, basis: .forwardYear,
                                   limit: health, stayUnderInclusive: false))
            }
        case .spouse:
            if ageAtYearEnd >= 70 {
                result.append(taxWall(.elderlySpouseDeductionReduced, income: dependentIncomeCap))
            }
            result.append(taxWall(.spouseSpecialDeductionDecreases, income: spouseSpecialFullCap))
            result.append(taxWall(.spouseSpecialDeductionEnds, income: spouseSpecialCap))
            // The 150万円 rule excludes spouses, whatever their age.
            if canBeHealthDependent {
                let health = ageNow >= 60 ? healthInsuranceAge60Plus : healthInsuranceGeneral
                result.append(Wall(kind: .healthInsuranceDependent, basis: .forwardYear,
                                   limit: health, stayUnderInclusive: false))
            }
        case .none:
            break
        }
        return result.sorted { $0.limit < $1.limit }
    }

    // MARK: Annual income

    public struct Payday: Equatable, Sendable {
        public var date: String
        public var amount: Double
        /// True when part of `amount` is projected from pace rather than entered shifts.
        public var includesProjection: Bool
    }

    public struct AnnualIncome: Equatable, Sendable {
        /// Tax-year income already paid (支給日 on or before today).
        public var paidToDate = 0.0
        /// Tax-year income from shifts already entered whose payday is later this year.
        public var scheduled = 0.0
        /// Tax-year income projected at the recent pace for days not yet entered.
        public var projectedExtra = 0.0
        public var projectedTotal: Double { paidToDate + scheduled + projectedExtra }
        /// The part of the year's total that work not yet done can still change: projected pay plus
        /// entered shifts dated after today, in periods whose payday is still to come this year.
        /// Pay for work already done is settled even when its payday is later.
        public var adjustable = 0.0
        /// For each employer with pay in this year: the last work date that still counts toward it —
        /// the end of the last pay period paid in the year (12/31 for an employer with no payday set).
        public var countingWorkEnd: [String: String] = [:]
        /// The latest of `countingWorkEnd`: after it, no work can change the year. Nil when nothing
        /// counts toward the year.
        public var lastCountingWorkDate: String? { countingWorkEnd.values.max() }
        /// The date to quote in cut-back advice: set only when every employer whose remaining work
        /// can still change the year shares the same one, so the advice is true for all of them.
        public var cutBackDeadline: String?
        /// 今後1年間の見込み for health insurance: recent pace (通勤手当 included) × 365. Nil when
        /// there is no work history to take a pace from.
        public var forwardAnnualEstimate: Double?
        /// The year-end projection leans on the pace of an employer with fewer than 28 days of
        /// history — it is a rough guide only.
        public var taxPaceIsTentative = false
        /// The same for the health-insurance estimate.
        public var healthPaceIsTentative = false
        public var paceIsTentative: Bool { taxPaceIsTentative || healthPaceIsTentative }
        /// Some employer has no payday set, so its shifts were assumed to be paid at month end of
        /// the month worked.
        public var hasEmployerWithoutPayday = false
        /// Taxable pay per worked hour over the recent window, for "about N more hours".
        public var taxablePerHour: Double?
        /// The lowest and highest per-shift rates over the same window, across employers. Hours still
        /// to work are counted at the highest and hours to cut at the lowest, so neither figure errs
        /// on the generous side whichever shifts the hours come from (a shift's own premiums are
        /// averaged over that shift).
        public var lowestTaxablePerHour: Double?
        public var highestTaxablePerHour: Double?
        /// Every payday in the year, oldest first.
        public var paydays: [Payday] = []
    }

    static let paceWindowDays = 90
    static let tentativeBelowDays = 28
    /// Schedules repeat weekly, so a pace is always measured over at least a week — counting shifts
    /// already entered for later in that week — rather than taking one first shift as a daily rate.
    static let minimumPaceDays = 7

    /// Tax-year income for `year` by 支給日, plus the forward estimate for health insurance.
    /// `today` is "YYYY-MM-DD". `classifications` must be built from ALL shifts so overtime is
    /// classified with the full picture, the same as everywhere else in the app.
    public static func annualIncome(year: Int, today: String, shifts: [Shift], profiles: [EmployerProfile],
                                    classifications: [String: [String: ShiftClassification]]) -> AnnualIncome {
        var income = AnnualIncome()
        var paydayTotals: [String: (amount: Double, projected: Bool)] = [:]
        let windowStart = addDays(today, -(paceWindowDays - 1))

        var recentTaxable = 0.0, recentMinutes = 0
        var healthEstimate = 0.0
        var adjustableEnds: Set<String> = []

        for (employer, employerShifts) in Dictionary(grouping: shifts, by: \.employer) {
            let pays = employerShifts.map { (shift: $0, pay: PayCalculation.pay(for: $0, classifications: classifications)) }
            let taxable: (ShiftPayResult) -> Double = { $0.netPay - $0.transport }

            // Pace: this employer's pay per calendar day. The window starts at the employer's first
            // shift when that is within the last 90 days, so a new job isn't diluted by days it
            // didn't exist for, and it spans at least a week (see `minimumPaceDays`).
            let firstDate = employerShifts.map(\.date).min()!
            let paceStart = max(firstDate, windowStart)
            let paceEnd = max(today, addDays(paceStart, minimumPaceDays - 1))
            let paceDays = countDays(from: paceStart, through: paceEnd)
            let measured = pays.filter { $0.shift.date >= paceStart && $0.shift.date <= paceEnd }
            let measuredTaxable = measured.reduce(0.0) { $0 + taxable($1.pay) }
            let dailyRate = measuredTaxable / Double(paceDays)
            recentTaxable += measuredTaxable
            let measuredMinutes = measured.reduce(0) { $0 + $1.pay.netMinutes }
            recentMinutes += measuredMinutes
            // Per shift, not per employer: a job mixing day shifts with better-paid night shifts
            // must not have its cheap hours valued at the average.
            for m in measured where m.pay.netMinutes > 0 {
                let perHour = taxable(m.pay) / (Double(m.pay.netMinutes) / 60)
                income.lowestTaxablePerHour = min(income.lowestTaxablePerHour ?? perHour, perHour)
                income.highestTaxablePerHour = max(income.highestTaxablePerHour ?? perHour, perHour)
            }
            let shortHistory = countDays(from: paceStart, through: today) < tentativeBelowDays
            // 健康保険: 通勤手当 included. A job that hasn't started within the coming week is left
            // out rather than assumed to run for the whole next twelve months.
            if firstDate <= addDays(today, minimumPaceDays - 1) {
                let measuredGross = measured.reduce(0.0) { $0 + $1.pay.netPay }
                healthEstimate += measuredGross / Double(paceDays) * 365
                if measuredGross > 0 && shortHistory { income.healthPaceIsTentative = true }
            }

            // Entered shifts are trusted up to the last one entered (days off in between are real
            // days off); only days after that — and after today — are projected.
            let cutoff = max(today, employerShifts.map(\.date).max()!)
            var contributed = 0.0, adjustable = 0.0, projectedForYear = 0.0

            func add(payDate: String, from start: String, through end: String, projected rawProjected: Double) {
                let inPeriod = pays.filter { $0.shift.date >= start && $0.shift.date <= end }
                let entered = inPeriod.reduce(0.0) { $0 + taxable($1.pay) }
                // A payday already past is settled: nothing is projected into it, even when the
                // period runs beyond it (当月払い — e.g. 末締め当月25日払い pays before the period ends).
                let projected = payDate <= today ? 0 : rawProjected
                if payDate <= today {
                    income.paidToDate += entered
                } else {
                    income.scheduled += entered
                    income.projectedExtra += projected
                    projectedForYear += projected
                    adjustable += projected + inPeriod.filter { $0.shift.date > today }.reduce(0.0) { $0 + taxable($1.pay) }
                }
                contributed += entered + projected
                guard entered + projected > 0 else { return }
                let prior = paydayTotals[payDate] ?? (0, false)
                paydayTotals[payDate] = (prior.amount + entered + projected, prior.projected || projected > 0)
            }

            let lastCounting: String
            if let profile = profiles.first(where: { $0.name == employer }) {
                let periods = payPeriods(paidIn: year, profile: profile)
                for period in periods {
                    let projectFrom = max(addDays(cutoff, 1), period.start)
                    add(payDate: period.payDate, from: period.start, through: period.end,
                        projected: Double(countDays(from: projectFrom, through: period.end)) * dailyRate)
                }
                lastCounting = periods.map(\.end).max() ?? String(format: "%04d-12-31", year)
            } else {
                // No payday on file: assume each month's work is paid at that month's end, so the
                // tax year is simply the calendar year worked. The UI says so and asks for the
                // payday; with 翌月払い the real year holds last December instead of this one, so
                // this can be off in either direction.
                for month in 1...12 {
                    let first = String(format: "%04d-%02d-01", year, month)
                    let last = String(format: "%04d-%02d-%02d", year, month,
                                      DateUtils.lastDayOfMonth(year: year, month: month))
                    let projectFrom = max(addDays(cutoff, 1), first)
                    add(payDate: last, from: first, through: last,
                        projected: Double(countDays(from: projectFrom, through: last)) * dailyRate)
                }
                if contributed > 0 { income.hasEmployerWithoutPayday = true }
                lastCounting = String(format: "%04d-12-31", year)
            }

            // Only a pace that actually projects pay into this year makes the year-end figure a guess.
            if projectedForYear > 0 && shortHistory { income.taxPaceIsTentative = true }
            income.adjustable += adjustable
            if contributed > 0 { income.countingWorkEnd[employer] = lastCounting }
            if adjustable > 0 { adjustableEnds.insert(lastCounting) }
        }
        if adjustableEnds.count == 1 { income.cutBackDeadline = adjustableEnds.first }

        if !shifts.isEmpty { income.forwardAnnualEstimate = healthEstimate }

        if recentMinutes > 0 { income.taxablePerHour = recentTaxable / (Double(recentMinutes) / 60) }
        income.paydays = paydayTotals
            .map { Payday(date: $0.key, amount: $0.value.amount, includesProjection: $0.value.projected) }
            .sorted { $0.date < $1.date }
        return income
    }

    /// The payday on which the running total first goes over `wall`, or nil if it never does this
    /// year. Only meaningful for `.taxYear` walls.
    public static func crossingPayday(of wall: Wall, in income: AnnualIncome) -> String? {
        var total = 0.0
        for payday in income.paydays {
            total += payday.amount
            // Whole yen, the same figure the screen shows, so floating-point dust can't move the
            // crossing to a different payday than the one the displayed totals imply.
            if wall.isExceeded(by: total.rounded()) { return payday.date }
        }
        return nil
    }

    // MARK: Helpers

    struct PaidPeriod: Equatable { var start: String; var end: String; var payDate: String }

    /// Every pay period of `profile` whose payday falls in `year`. Period ends are walked from the
    /// start of the previous year so that even a 翌々月 payday in January is found.
    static func payPeriods(paidIn year: Int, profile: EmployerProfile) -> [PaidPeriod] {
        var out: [PaidPeriod] = []
        for (y, m) in (1...24).map({ i -> (Int, Int) in (year - 1 + (i - 1) / 12, (i - 1) % 12 + 1) }) {
            let closeDay = DateUtils.resolveDay(year: y, month: m, day: profile.closingDay)
            let periodEnd = String(format: "%04d-%02d-%02d", y, m, closeDay)
            let payDate = PayPeriod.paymentDate(periodEnd: periodEnd, paydayMonthOffset: profile.paydayMonthOffset,
                                                paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
            guard payDate.hasPrefix(String(format: "%04d-", year)) else { continue }
            let period = PayPeriod.period(forDate: periodEnd, closingDay: profile.closingDay)
            out.append(PaidPeriod(start: period.periodStart, end: period.periodEnd, payDate: payDate))
        }
        return out
    }

    static func addDays(_ ymd: String, _ n: Int) -> String {
        guard let (y, m, d) = DateUtils.parseYMD(ymd) else { return ymd }
        let date = DateUtils.calendar.date(byAdding: .day, value: n, to: DateUtils.date(year: y, month: m, day: d))!
        return DateUtils.ymd(date)
    }

    /// Days from `a` through `b` inclusive; 0 when `b` is before `a`.
    static func countDays(from a: String, through b: String) -> Int {
        guard a <= b, let (ay, am, ad) = DateUtils.parseYMD(a), let (by, bm, bd) = DateUtils.parseYMD(b) else { return 0 }
        let days = DateUtils.calendar.dateComponents([.day], from: DateUtils.date(year: ay, month: am, day: ad),
                                                     to: DateUtils.date(year: by, month: bm, day: bd)).day!
        return days + 1
    }
}
