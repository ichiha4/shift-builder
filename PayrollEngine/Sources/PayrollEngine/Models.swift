import Foundation

/// One contiguous block of work at a single hourly wage. `startMinute`/`endMinute` are
/// minutes since 00:00 (0..<1440). An overnight segment (e.g. 22:00–06:00) is expressed
/// with `endMinute < startMinute`; callers add 1440 when expanding it, exactly like the
/// original JS `toMin`/wrap-around logic.
public struct WorkSegment: Codable, Equatable, Sendable {
    public var startMinute: Int
    public var endMinute: Int
    public var hourlyWage: Double

    public init(startMinute: Int, endMinute: Int, hourlyWage: Double) {
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.hourlyWage = hourlyWage
    }

    /// False for a segment whose start/end coincide — the native form can't produce an
    /// "empty string" time the way the web version's text inputs could, but a user can still
    /// leave start == end, which should be treated as not-yet-entered rather than a 24h shift.
    public var isUsable: Bool { startMinute != endMinute }
}

public struct Shift: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// Calendar date this shift falls on, "YYYY-MM-DD" (local time, never UTC-derived —
    /// see DateUtils.ymd). Kept as a string because it's used as a dictionary/grouping key
    /// throughout, exactly like the original app.
    public var date: String
    public var employer: String
    public var segments: [WorkSegment]
    public var breakMinutes: Int
    /// nil = break length only known approximately (averaged across the whole shift).
    /// Set = break excluded from exact clock minutes, and lateNight/overtime is judged
    /// precisely around it.
    public var breakStartMinute: Int?
    public var transport: Double
    public var otherAllowance: Double
    public var isStatutoryHoliday: Bool
    public var scheduledMinutes: Int
    public var lateNightRate: Double
    public var overtimeRate: Double
    public var holidayRate: Double

    public init(
        id: String = UUID().uuidString,
        date: String,
        employer: String,
        segments: [WorkSegment],
        breakMinutes: Int = 0,
        breakStartMinute: Int? = nil,
        transport: Double = 0,
        otherAllowance: Double = 0,
        isStatutoryHoliday: Bool = false,
        scheduledMinutes: Int = PayrollConstants.dailyOvertimeThresholdMinutes,
        lateNightRate: Double = PayrollConstants.defaultLateNightRate,
        overtimeRate: Double = PayrollConstants.defaultOvertimeRate,
        holidayRate: Double = PayrollConstants.defaultHolidayRate
    ) {
        self.id = id
        self.date = date
        self.employer = employer
        self.segments = segments
        self.breakMinutes = breakMinutes
        self.breakStartMinute = breakStartMinute
        self.transport = transport
        self.otherAllowance = otherAllowance
        self.isStatutoryHoliday = isStatutoryHoliday
        self.scheduledMinutes = scheduledMinutes
        self.lateNightRate = lateNightRate
        self.overtimeRate = overtimeRate
        self.holidayRate = holidayRate
    }

    /// Repeat a saved shift without silently losing its unpaid break or allowances.
    /// Statutory-holiday status belongs to the selected date and must be set separately.
    public func repeated(on date: String) -> Shift {
        var copy = self
        copy.id = UUID().uuidString
        copy.date = date
        copy.isStatutoryHoliday = false
        return copy
    }

    /// Whether the break is precisely timed (start known and length > 0) — mirrors the JS
    /// `preciseBreak` flag used throughout the original calculation.
    public var hasPreciseBreak: Bool { breakStartMinute != nil && breakMinutes > 0 }
}

/// How a payday that lands on a weekend or Japanese national holiday gets adjusted. Most
/// companies pay early (前倒し) rather than late, so that's the default — but it varies enough
/// by employer that it's worth exposing rather than assuming.
public enum PaydayAdjustment: String, Codable, CaseIterable, Sendable {
    case none
    case beforeBusinessDay
    case afterBusinessDay
}

public struct EmployerProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// 0 is a valid, meaningful value (an on-call employer where everything is overtime) —
    /// keep this Double, never coalesce a legitimate 0 to a default the way the ported-from
    /// JS bug once did (`e.scheduledHours || 8`).
    public var scheduledHours: Double
    public var defaultWage: Double
    public var defaultTransport: Double
    public var otherAllowance: Double
    /// 1-31, or 0 meaning 末日 (last day of the month).
    public var closingDay: Int
    /// 0 = paid the same month as the closing date, 1 = the following month, etc.
    public var paydayMonthOffset: Int
    public var paydayDay: Int
    public var paydayAdjustment: PaydayAdjustment
    public var lateNightRate: Double
    public var overtimeRate: Double
    public var holidayRate: Double
    public var employmentType: String
    /// 甲欄 = this is the job with a 扶養控除等申告書 on file (normally the main/only job);
    /// 乙欄 = a concurrent second (or third...) job. Only one employer should ever be 甲欄 —
    /// see IncomeTax.swift for why combining multiple employers under one table is wrong.
    public var incomeTaxColumn: IncomeTaxColumn
    /// 源泉控除対象親族の数 — only meaningful (and only asked for in the UI) for 甲欄.
    public var dependentsCount: Int
    /// Whether a 源泉控除対象配偶者 applies — only meaningful for 甲欄.
    public var hasSpouseAllowance: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        scheduledHours: Double = 8,
        defaultWage: Double = 0,
        defaultTransport: Double = 0,
        otherAllowance: Double = 0,
        closingDay: Int = 0,
        paydayMonthOffset: Int = 1,
        paydayDay: Int = 25,
        paydayAdjustment: PaydayAdjustment = .beforeBusinessDay,
        lateNightRate: Double = PayrollConstants.defaultLateNightRate,
        overtimeRate: Double = PayrollConstants.defaultOvertimeRate,
        holidayRate: Double = PayrollConstants.defaultHolidayRate,
        employmentType: String = "アルバイト",
        incomeTaxColumn: IncomeTaxColumn = .kou,
        dependentsCount: Int = 0,
        hasSpouseAllowance: Bool = false
    ) {
        self.id = id
        self.name = name
        self.scheduledHours = scheduledHours
        self.defaultWage = defaultWage
        self.defaultTransport = defaultTransport
        self.otherAllowance = otherAllowance
        self.closingDay = closingDay
        self.paydayMonthOffset = paydayMonthOffset
        self.incomeTaxColumn = incomeTaxColumn
        self.dependentsCount = dependentsCount
        self.hasSpouseAllowance = hasSpouseAllowance
        self.paydayDay = paydayDay
        self.paydayAdjustment = paydayAdjustment
        self.lateNightRate = lateNightRate
        self.overtimeRate = overtimeRate
        self.holidayRate = holidayRate
        self.employmentType = employmentType
    }

    public var scheduledMinutes: Int { Int((scheduledHours * 60).rounded()) }
}

public struct Expense: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var date: String
    public var category: String
    public var amount: Double
    public var memo: String
    /// Set when this expense was auto-generated from a `RecurringExpense` — lets the generator
    /// tell "already created for this month" apart from a same-category expense the user typed
    /// in by hand, without ever creating a duplicate for the same recurring item + month.
    public var recurringExpenseId: String?

    public init(id: String = UUID().uuidString, date: String, category: String, amount: Double, memo: String = "", recurringExpenseId: String? = nil) {
        self.id = id
        self.date = date
        self.category = category
        self.amount = amount
        self.memo = memo
        self.recurringExpenseId = recurringExpenseId
    }
}

/// A fixed monthly outgoing (subscriptions, rent, etc.) — every month once `dayOfMonth` is
/// reached, `ShiftStore.generateDueRecurringExpenses()` drops a matching `Expense` into that
/// month automatically, the same way a real subscription charge would hit a bank statement.
public struct RecurringExpense: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var category: String
    public var amount: Double
    public var memo: String
    /// 1-31, or 0 meaning 末日 (last day of the month) — same convention as `EmployerProfile`'s
    /// closing/payday fields.
    public var dayOfMonth: Int
    public var isActive: Bool

    public init(
        id: String = UUID().uuidString,
        name: String,
        category: String,
        amount: Double,
        memo: String = "",
        dayOfMonth: Int,
        isActive: Bool = true
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.amount = amount
        self.memo = memo
        self.dayOfMonth = dayOfMonth
        self.isActive = isActive
    }
}

public struct Deduction: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    /// "YYYY-MM"
    public var month: String
    public var category: String
    public var amount: Double
    public var note: String

    public init(id: String = UUID().uuidString, month: String, category: String, amount: Double, note: String = "") {
        self.id = id
        self.month = month
        self.category = category
        self.amount = amount
        self.note = note
    }
}

/// What the user actually received on a specific payday, entered from the payday-banner prompt
/// (see ContentView.swift) — kept separate from the shift-based estimate so recording the real
/// figure never overwrites or depends on the calculation being exactly right.
public struct ActualPayment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var employer: String
    /// "YYYY-MM-DD" — the (already weekend/holiday-adjusted) date this was paid on; together
    /// with `employer` this is the natural key, since a given employer pays out once per date.
    public var payDate: String
    public var amount: Double

    public init(id: String = UUID().uuidString, employer: String, payDate: String, amount: Double) {
        self.id = id
        self.employer = employer
        self.payDate = payDate
        self.amount = amount
    }
}

public enum PayrollConstants {
    public static let lateNightStartMinute = 22 * 60
    public static let lateNightEndMinute = 5 * 60
    public static let dailyOvertimeThresholdMinutes = 8 * 60
    public static let weeklyOvertimeThresholdMinutes = 40 * 60
    public static let defaultLateNightRate = 0.25
    public static let defaultOvertimeRate = 0.25
    public static let defaultHolidayRate = 0.35
    /// 法定時間外労働が月60時間を超えた部分の割増率 (労基法37条1項但書)。2023年4月に中小企業への
    /// 猶予措置が終了したため、事業規模にかかわらずこの率が適用される。
    public static let monthlyOvertimeThresholdMinutes = 60 * 60
    public static let extendedOvertimeRate = 0.50

    public static let deductionCategories = ["健康保険料", "厚生年金保険料", "雇用保険料", "所得税", "住民税", "その他控除"]
    /// The subset of `deductionCategories` that counts as 社会保険料 for withholding purposes —
    /// these reduce the taxable base before the 源泉徴収税額表 is applied. 所得税 is the output of
    /// that calculation, not an input to it, and 住民税 is levied separately on the prior year,
    /// so neither belongs here.
    public static let socialInsuranceCategories: Set<String> = ["健康保険料", "厚生年金保険料", "雇用保険料"]
    public static let expenseCategories = ["食費", "交通費", "日用品", "娯楽", "家賃・光熱", "通信費", "その他"]
    public static let employmentTypes = ["アルバイト", "パート", "契約社員", "正社員", "その他"]
}
