import Foundation

public struct PayBreakdown: Equatable, Sendable {
    public var base: Double
    public var lateNightExtra: Double
    public var overtimeExtra: Double
    public var holidayExtra: Double
}

public struct FormulaLine: Equatable, Sendable {
    public var range: String
    public var hours: Double
    public var wage: Double
    public var rate: Double
    public var amount: Double
}

/// Live preview for the add-shift form. The caller can supply other shifts to use the same
/// cross-shift overtime rules as the committed figure, `ShiftPayResult`, produced by
/// `PayCalculation.calculateShiftPay`, which aggregates per employer across day and week
/// before classifying overtime.
public struct ShiftPayEstimate: Equatable, Sendable {
    /// Full scheduled span including breaks. Legal break requirements use `netMinutes`.
    public var totalMinutes: Int
    public var netMinutes: Int
    public var base: Double
    public var lateNightExtra: Double
    public var overtimeExtra: Double
    public var holidayExtra: Double
    public var lateNightMinutes: Int
    public var overtimeMinutes: Int
    public var holidayMinutes: Int
    public var netPay: Double
    public var breakdown: PayBreakdown
}

public struct ShiftPayResult: Equatable, Sendable {
    public var totalMinutes: Int
    public var netMinutes: Int
    public var normalMinutes: Int
    public var base: Double
    public var lateNightExtra: Double
    public var overtimeExtra: Double
    public var holidayExtra: Double
    public var lateNightMinutes: Int
    public var scheduledOvertimeMinutes: Int
    public var overtimeMinutes: Int
    /// The subset of `overtimeMinutes` past the month's 60th legal-overtime hour, paid at 5割増.
    public var extendedOvertimeMinutes: Int
    public var holidayMinutes: Int
    public var transport: Double
    public var otherAllowance: Double
    /// Pay removed for a break entered without a start time. Such a break can't be placed on the
    /// clock, so base/night/holiday pay are computed over the span and reduced proportionally.
    /// Legal overtime premiums already use net working time and are not deducted again. Anything that totals the components (payslips,
    /// withholding) must subtract it, or it reports pay for time that wasn't worked.
    public var breakDeduction: Double
    public var netPay: Double
    public var hasPreciseBreak: Bool
    public var lateNightRanges: [String]
    public var overtimeRanges: [String]
    public var holidayRanges: [String]
    public var lateNightFormula: [FormulaLine]
    public var overtimeFormula: [FormulaLine]
    public var holidayFormula: [FormulaLine]
    public var breakdown: PayBreakdown
}

struct ExpandedShift {
    var minutes: [WorkedMinute]
    var netMinutes: Int
    var rawLength: Int
    var hasPreciseBreak: Bool
    var breakMinutes: Int
}

public enum MinuteBucket: Equatable, Sendable {
    case normal, scheduledOvertime, dailyLegalOvertime, weeklyLegalOvertime, holiday
    /// 法定時間外労働のうち、その月の60時間を超えた分。労基法37条1項但書の5割増が適用される。
    /// 中小企業への猶予は2023年4月に終了しており、事業規模を問わず適用される。
    case extendedMonthlyOvertime
}

struct BucketedMinute {
    var clockMinute: Int
    var wage: Double
    var bucket: MinuteBucket
}

/// Per-employer overtime classification for one (already-saved) shift — the output of
/// `PayCalculation.classifyEmployerOvertime`, keyed by shift id.
public struct ShiftClassification {
    var expanded: ExpandedShift
    var minutes: [BucketedMinute]
}

public enum PayCalculation {

    // MARK: - Live preview (unsaved, single-shift, no cross-shift context)

    /// Uses the same rules as a saved shift. Passing the other shifts also includes daily,
    /// weekly and monthly overtime; replacing the same id avoids counting an edited shift twice.
    public static func estimateShiftPay(_ shift: Shift, allShifts: [Shift] = []) -> ShiftPayEstimate {
        let context = allShifts.filter { $0.id != shift.id } + [shift]
        let pay = calculateShiftPay(shift, classifications: buildEmployerClassifications(context))
        return ShiftPayEstimate(
            totalMinutes: pay.totalMinutes, netMinutes: pay.netMinutes, base: pay.base,
            lateNightExtra: pay.lateNightExtra, overtimeExtra: pay.overtimeExtra,
            holidayExtra: pay.holidayExtra, lateNightMinutes: pay.lateNightMinutes,
            overtimeMinutes: pay.overtimeMinutes, holidayMinutes: pay.holidayMinutes,
            netPay: pay.netPay, breakdown: pay.breakdown
        )
    }

    // MARK: - Cross-shift overtime classification (committed)

    static func expandShiftMinutes(_ shift: Shift) -> ExpandedShift {
        let raw = SegmentExpansion.expand(shift.segments)
        if shift.hasPreciseBreak, let breakStart = shift.breakStartMinute {
            let bs = SegmentExpansion.resolveBreakStart(raw, breakStartMinute: breakStart)
            let be = bs + shift.breakMinutes
            let filtered = raw.filter { !($0.clockMinute >= bs && $0.clockMinute < be) }
            return ExpandedShift(minutes: filtered, netMinutes: filtered.count, rawLength: raw.count, hasPreciseBreak: true, breakMinutes: shift.breakMinutes)
        }
        let net = max(0, raw.count - shift.breakMinutes)
        return ExpandedShift(minutes: raw, netMinutes: net, rawLength: raw.count, hasPreciseBreak: false, breakMinutes: shift.breakMinutes)
    }

    /// Aggregates one employer's shifts by day, then by week, to classify every worked
    /// minute as normal / scheduledOvertime (所定内残業, no premium) / dailyLegalOvertime
    /// (>8h/day) / weeklyLegalOvertime (>40h/week, only counted against minutes not already
    /// daily-OT, so an hour is never paid the premium twice). Statutory-holiday shifts are
    /// excluded — their premium is computed separately in `calculateShiftPay`.
    public static func classifyEmployerOvertime(_ employerShifts: [Shift]) -> [String: ShiftClassification] {
        let workable = employerShifts.filter { !$0.isStatutoryHoliday }
        var shiftData: [String: ShiftClassification] = [:]
        for s in workable {
            let exp = expandShiftMinutes(s)
            shiftData[s.id] = ShiftClassification(
                expanded: exp,
                minutes: exp.minutes.map { BucketedMinute(clockMinute: $0.clockMinute, wage: $0.wage, bucket: .normal) }
            )
        }

        var byDate: [String: [Shift]] = [:]
        for s in workable { byDate[s.date, default: []].append(s) }

        struct DayInfo { var totalMinutes: Int; var legalOTMinutes: Int; var scheduledOTMinutes: Int; var shiftIds: [String] }
        var dayInfo: [String: DayInfo] = [:]

        for (date, shiftsOnDayUnsorted) in byDate {
            // Sort chronologically so the day's 所定労働時間 is read from whichever shift
            // actually starts first that day.
            let shiftsOnDay = shiftsOnDayUnsorted.sorted { ($0.segments.first?.startMinute ?? 0) < ($1.segments.first?.startMinute ?? 0) }
            guard let first = shiftsOnDay.first else { continue }
            let scheduledMin = first.scheduledMinutes
            var totalMin = 0
            for s in shiftsOnDay { totalMin += shiftData[s.id]!.expanded.netMinutes }
            let legalOTMin = max(0, totalMin - PayrollConstants.dailyOvertimeThresholdMinutes)
            let scheduledOTMin = max(0, min(totalMin, PayrollConstants.dailyOvertimeThresholdMinutes) - scheduledMin)
            dayInfo[date] = DayInfo(totalMinutes: totalMin, legalOTMinutes: legalOTMin, scheduledOTMinutes: scheduledOTMin, shiftIds: shiftsOnDay.map(\.id))

            struct Combined { var shiftId: String; var idx: Int; var clockMinute: Int }
            var combined: [Combined] = []
            for s in shiftsOnDay {
                for (idx, m) in shiftData[s.id]!.minutes.enumerated() {
                    combined.append(Combined(shiftId: s.id, idx: idx, clockMinute: m.clockMinute))
                }
            }
            combined.sort { $0.clockMinute < $1.clockMinute }
            var remainingLegal = legalOTMin, remainingScheduled = scheduledOTMin
            var i = combined.count - 1
            while i >= 0 && (remainingLegal > 0 || remainingScheduled > 0) {
                let c = combined[i]
                if remainingLegal > 0 {
                    shiftData[c.shiftId]!.minutes[c.idx].bucket = .dailyLegalOvertime
                    remainingLegal -= 1
                } else if remainingScheduled > 0 {
                    shiftData[c.shiftId]!.minutes[c.idx].bucket = .scheduledOvertime
                    remainingScheduled -= 1
                }
                i -= 1
            }
        }

        var byWeek: [String: [String]] = [:]
        for date in dayInfo.keys { byWeek[DateUtils.mondayOfWeek(date), default: []].append(date) }

        for datesUnsorted in byWeek.values {
            let dates = datesUnsorted.sorted()
            let weeklyNonDailyOTMin = dates.reduce(0) { sum, d in sum + (dayInfo[d]!.totalMinutes - dayInfo[d]!.legalOTMinutes) }
            // The 40h line is judged against minutes not already daily-OT, so an hour
            // already paid at the daily-overtime rate is never counted twice.
            let excess = max(0, weeklyNonDailyOTMin - PayrollConstants.weeklyOvertimeThresholdMinutes)
            var weeklyLegalOTMin = min(excess, weeklyNonDailyOTMin)
            guard weeklyLegalOTMin > 0 else { continue }

            struct PoolItem { var shiftId: String; var idx: Int; var date: String; var clockMinute: Int }
            var pool: [PoolItem] = []
            for date in dates {
                for shiftId in dayInfo[date]!.shiftIds {
                    for (idx, m) in shiftData[shiftId]!.minutes.enumerated() where m.bucket == .normal || m.bucket == .scheduledOvertime {
                        pool.append(PoolItem(shiftId: shiftId, idx: idx, date: date, clockMinute: m.clockMinute))
                    }
                }
            }
            pool.sort { a, b in a.date == b.date ? a.clockMinute < b.clockMinute : a.date < b.date }
            var i = pool.count - 1
            while i >= 0 && weeklyLegalOTMin > 0 {
                let p = pool[i]
                shiftData[p.shiftId]!.minutes[p.idx].bucket = .weeklyLegalOvertime
                weeklyLegalOTMin -= 1
                i -= 1
            }
        }

        promoteOvertimePastMonthlyLimit(&shiftData, shifts: workable)
        return shiftData
    }

    /// Re-labels the 法定時間外 minutes past the 60th hour of a calendar month so they're paid at
    /// 5割増 instead of 2割増. Counting runs forward through the month, because the statute caps
    /// the first 60 hours at the lower rate — it's the *later* overtime that earns the higher one,
    /// so which minutes get promoted depends on chronological order, not on which shift they're in.
    /// 所定内残業 is excluded: it isn't 法定時間外 and never counts toward the 60.
    private static func promoteOvertimePastMonthlyLimit(_ shiftData: inout [String: ShiftClassification], shifts: [Shift]) {
        struct Ref { var shiftId: String; var idx: Int }
        var byMonth: [String: [(date: String, clockMinute: Int, ref: Ref)]] = [:]
        for s in shifts {
            guard let data = shiftData[s.id] else { continue }
            let month = String(s.date.prefix(7))
            for (idx, m) in data.minutes.enumerated()
            where m.bucket == .dailyLegalOvertime || m.bucket == .weeklyLegalOvertime {
                byMonth[month, default: []].append((s.date, m.clockMinute, Ref(shiftId: s.id, idx: idx)))
            }
        }

        for (_, entriesUnsorted) in byMonth {
            guard entriesUnsorted.count > PayrollConstants.monthlyOvertimeThresholdMinutes else { continue }
            let entries = entriesUnsorted.sorted { a, b in
                a.date == b.date ? a.clockMinute < b.clockMinute : a.date < b.date
            }
            for e in entries.dropFirst(PayrollConstants.monthlyOvertimeThresholdMinutes) {
                shiftData[e.ref.shiftId]!.minutes[e.ref.idx].bucket = .extendedMonthlyOvertime
            }
        }
    }

    /// Groups an employer's shifts and runs `classifyEmployerOvertime` once per employer.
    /// Call this from the scope that has ALL shifts (not just the visible month) so weeks
    /// spanning a month boundary are judged correctly, then pass the result into
    /// `calculateShiftPay` for each shift.
    public static func buildEmployerClassifications(_ allShifts: [Shift]) -> [String: [String: ShiftClassification]] {
        var byEmployer: [String: [Shift]] = [:]
        for s in allShifts { byEmployer[s.employer, default: []].append(s) }
        var result: [String: [String: ShiftClassification]] = [:]
        for (employer, shifts) in byEmployer { result[employer] = classifyEmployerOvertime(shifts) }
        return result
    }

    static func minutesToFormulaLines(_ pairs: [WorkedMinute], rate: Double) -> [FormulaLine] {
        guard !pairs.isEmpty else { return [] }
        let sorted = pairs.sorted { $0.clockMinute < $1.clockMinute }
        var lines: [FormulaLine] = []
        var runStart = sorted[0].clockMinute
        var runPrev = sorted[0].clockMinute
        var runWage = sorted[0].wage

        func flush(_ endExclusive: Int) {
            let durMin = endExclusive - runStart
            let amount = (Double(durMin) / 60) * runWage * rate
            lines.append(FormulaLine(
                range: "\(ClockUtils.formatClock(runStart))–\(ClockUtils.formatClock(endExclusive))",
                hours: Double(durMin) / 60, wage: runWage, rate: rate, amount: amount
            ))
        }

        for cur in sorted.dropFirst() {
            if cur.clockMinute == runPrev + 1 && cur.wage == runWage { runPrev = cur.clockMinute; continue }
            flush(runPrev + 1)
            runStart = cur.clockMinute; runPrev = cur.clockMinute; runWage = cur.wage
        }
        flush(runPrev + 1)
        return lines
    }

    /// The real, committed calculation. `classifications` is the (already computed, once per
    /// render/load) output of `buildEmployerClassifications` — every other shift this
    /// employer has on the same day/week has already been taken into account.
    public static func calculateShiftPay(_ shift: Shift, classifications: [String: [String: ShiftClassification]]) -> ShiftPayResult {
        let minutes: [BucketedMinute]
        let exp: ExpandedShift
        if shift.isStatutoryHoliday {
            exp = expandShiftMinutes(shift)
            minutes = exp.minutes.map { BucketedMinute(clockMinute: $0.clockMinute, wage: $0.wage, bucket: .holiday) }
        } else if let cls = classifications[shift.employer]?[shift.id] {
            minutes = cls.minutes
            exp = cls.expanded
        } else {
            exp = expandShiftMinutes(shift)
            minutes = exp.minutes.map { BucketedMinute(clockMinute: $0.clockMinute, wage: $0.wage, bucket: .normal) }
        }

        var base = 0.0, lateNightExtra = 0.0, overtimeExtra = 0.0, holidayExtra = 0.0
        var lateNightMin = 0, scheduledOtMin = 0, overtimeMin = 0, holidayMin = 0, extendedOtMin = 0
        var lateNightMinutes: [WorkedMinute] = [], overtimeMinutes: [WorkedMinute] = [], holidayMinutes: [WorkedMinute] = []

        for m in minutes {
            let perMinWage = m.wage / 60
            base += perMinWage
            if ClockUtils.isLateNightMinute(m.clockMinute) {
                lateNightExtra += perMinWage * shift.lateNightRate; lateNightMin += 1
                lateNightMinutes.append(WorkedMinute(clockMinute: m.clockMinute, wage: m.wage))
            }
            switch m.bucket {
            case .holiday:
                holidayExtra += perMinWage * shift.holidayRate; holidayMin += 1
                holidayMinutes.append(WorkedMinute(clockMinute: m.clockMinute, wage: m.wage))
            case .dailyLegalOvertime, .weeklyLegalOvertime:
                overtimeExtra += perMinWage * shift.overtimeRate; overtimeMin += 1
                overtimeMinutes.append(WorkedMinute(clockMinute: m.clockMinute, wage: m.wage))
            case .extendedMonthlyOvertime:
                overtimeExtra += perMinWage * PayrollConstants.extendedOvertimeRate
                overtimeMin += 1; extendedOtMin += 1
                overtimeMinutes.append(WorkedMinute(clockMinute: m.clockMinute, wage: m.wage))
            case .scheduledOvertime:
                // 所定内残業: 割増なし、通常単価のまま base に含まれている
                scheduledOtMin += 1
            case .normal:
                break
            }
        }

        let netMin = exp.netMinutes
        let normalMin = max(0, netMin - overtimeMin - scheduledOtMin - holidayMin)

        let grossPay = base + lateNightExtra + overtimeExtra + holidayExtra
        var netPayBeforeExtras = grossPay
        if !exp.hasPreciseBreak, exp.breakMinutes > 0, exp.rawLength > 0 {
            // Overtime buckets already count only the legal excess of NET working time.
            // Deducting that premium again for a break understates earned overtime pay.
            // Base, night and holiday allocation remains proportional when break timing is unknown.
            let perMin = (base + lateNightExtra + holidayExtra) / Double(exp.rawLength)
            netPayBeforeExtras = max(0, grossPay - Double(exp.breakMinutes) * perMin)
        }
        let netPay = netPayBeforeExtras + shift.transport + shift.otherAllowance
        let breakDeduction = grossPay - netPayBeforeExtras

        return ShiftPayResult(
            totalMinutes: exp.rawLength, netMinutes: netMin, normalMinutes: normalMin, base: base,
            lateNightExtra: lateNightExtra, overtimeExtra: overtimeExtra, holidayExtra: holidayExtra,
            lateNightMinutes: lateNightMin, scheduledOvertimeMinutes: scheduledOtMin, overtimeMinutes: overtimeMin,
            extendedOvertimeMinutes: extendedOtMin,
            holidayMinutes: holidayMin, transport: shift.transport, otherAllowance: shift.otherAllowance, breakDeduction: breakDeduction, netPay: netPay,
            hasPreciseBreak: exp.hasPreciseBreak,
            lateNightRanges: ClockUtils.minutesToRanges(lateNightMinutes.map(\.clockMinute)),
            overtimeRanges: ClockUtils.minutesToRanges(overtimeMinutes.map(\.clockMinute)),
            holidayRanges: ClockUtils.minutesToRanges(holidayMinutes.map(\.clockMinute)),
            lateNightFormula: minutesToFormulaLines(lateNightMinutes, rate: shift.lateNightRate),
            overtimeFormula: minutesToFormulaLines(overtimeMinutes, rate: shift.overtimeRate),
            holidayFormula: minutesToFormulaLines(holidayMinutes, rate: shift.holidayRate),
            breakdown: PayBreakdown(base: base, lateNightExtra: lateNightExtra, overtimeExtra: overtimeExtra, holidayExtra: holidayExtra)
        )
    }

    public static func pay(for shift: Shift, classifications: [String: [String: ShiftClassification]]) -> ShiftPayResult {
        calculateShiftPay(shift, classifications: classifications)
    }

    /// Scheduled-minutes default for a new shift at `employerName`, from its saved profile
    /// (or the plain 8h/25%/25%/35% defaults when the employer has no profile yet).
    public static func profileDefaults(employerName: String, profiles: [EmployerProfile]) -> (scheduledMinutes: Int, lateNightRate: Double, overtimeRate: Double, holidayRate: Double) {
        guard let p = profiles.first(where: { $0.name == employerName }) else {
            return (PayrollConstants.dailyOvertimeThresholdMinutes, PayrollConstants.defaultLateNightRate, PayrollConstants.defaultOvertimeRate, PayrollConstants.defaultHolidayRate)
        }
        return (p.scheduledMinutes, p.lateNightRate, p.overtimeRate, p.holidayRate)
    }
}
