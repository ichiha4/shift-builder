import Foundation

public enum Validation {
    /// Absolute [start, end) range for one segment, unwrapping an overnight segment past
    /// midnight (e.g. 22:00–06:00 becomes [1320, 1800)) so two segments can be compared for
    /// overlap on one number line.
    public static func absoluteRange(_ seg: WorkSegment) -> (start: Int, end: Int) {
        var end = seg.endMinute
        if end < seg.startMinute { end += 1440 }
        return (seg.startMinute, end)
    }

    /// Segment order starts at the shift's first clock time. Earlier clock times belong to
    /// the next day (22:00–02:00, then 02:00–08:00), keeping rates and overlap on one timeline.
    public static func absoluteRanges(_ segments: [WorkSegment]) -> [(start: Int, end: Int)] {
        guard let first = segments.first else { return [] }
        return segments.map { segment in
            let offset = segment.startMinute < first.startMinute ? 1440 : 0
            let range = absoluteRange(segment)
            return (range.start + offset, range.end + offset)
        }
    }

    /// Blocking checks — a shift with any of these can't be saved. Unlike the original JS
    /// (which had to reject empty/malformed "HH:MM" text), a native form binds segment times
    /// to real `Int` minutes from a picker, so there's no "unparseable time" case here —
    /// only genuinely invalid combinations.
    public static func validateShift(segments: [WorkSegment], breakMinutes: Int, breakStartMinute: Int?, lateNightRate: Double, overtimeRate: Double, holidayRate: Double) -> [String] {
        var errors: [String] = []
        if segments.isEmpty { errors.append("勤務時間を1つ以上入力してください") }
        if breakMinutes < 0 { errors.append("休憩時間にマイナスの値は設定できません") }
        for (i, seg) in segments.enumerated() {
            if !seg.isUsable { errors.append("時間帯\(i + 1): 終了時刻が開始時刻と同じか前になっています") }
            if !seg.hourlyWage.isFinite || seg.hourlyWage <= 0 { errors.append("時間帯\(i + 1): 時給が0円以下になっています。1円以上を入力してください") }
        }
        let ranges = absoluteRanges(segments)
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                let (s1, e1) = ranges[i]
                let (s2, e2) = ranges[j]
                if s1 < e2 && s2 < e1 { errors.append("時間帯\(i + 1)と時間帯\(j + 1)の勤務時間が重複しています") }
            }
        }
        let totalMin = ranges.reduce(0) { $0 + max(0, $1.end - $1.start) }
        if breakMinutes > totalMin { errors.append("休憩時間が勤務時間を超えています") }
        if let breakStart = breakStartMinute, breakMinutes > 0 {
            let allMinutes = SegmentExpansion.expand(segments)
            let workedSet = Set(allMinutes.map(\.clockMinute))
            let startsInside = workedSet.contains(breakStart) || workedSet.contains(breakStart + 1440)
            if !startsInside {
                errors.append("休憩開始時刻が勤務時間外です")
            } else {
                let base = workedSet.contains(breakStart) ? breakStart : breakStart + 1440
                var allInside = true
                for t in base..<(base + breakMinutes) where !workedSet.contains(t) { allInside = false; break }
                if !allInside { errors.append("休憩時間が勤務時間の範囲を超えて設定されています") }
            }
        }
        for (label, rate) in [("深夜割増率", lateNightRate), ("残業割増率", overtimeRate), ("法定休日割増率", holidayRate)] where !rate.isFinite || rate < 0 {
            errors.append("\(label)にマイナスの値は設定できません")
        }
        return errors
    }

    /// Soft, non-blocking sanity checks (typos, not input errors) against a live preview.
    public static func detectShiftAnomalies(_ estimate: ShiftPayEstimate) -> [String] {
        var warnings: [String] = []
        if estimate.totalMinutes > 16 * 60 {
            warnings.append("1回の勤務が\(String(format: "%.1f", Double(estimate.totalMinutes) / 60))時間と長時間になっています。時刻の入力ミスがないか確認してください")
        }
        if estimate.netMinutes > 0 && estimate.netPay <= 0 {
            warnings.append("勤務時間があるのに給与が¥0円です。時給や休憩の設定を確認してください")
        }
        if estimate.overtimeMinutes > 8 * 60 {
            warnings.append("残業時間が\(String(format: "%.1f", Double(estimate.overtimeMinutes) / 60))時間と長くなっています。所定労働時間の設定を確認してください")
        }
        return warnings
    }

    /// A break can cross midnight, just like a work segment.
    public static func breakDurationMinutes(start: Int, end: Int) -> Int {
        end >= start ? end - start : end + 1440 - start
    }

    /// Safe conversion for a live form: invalid input stays zero until save validation reports it.
    public static func scheduledMinutes(hours: Double) -> Int {
        guard hours.isFinite, (0...24).contains(hours) else { return 0 }
        return Int((hours * 60).rounded())
    }

    /// Requirements are based on actual working time EXCLUDING breaks (労基法34条).
    /// Exactly eight hours needs 45 minutes; only more than eight needs 60 minutes.
    public static func breakHint(netMinutes: Int) -> String? {
        if netMinutes > 480 { return "8時間超の勤務のため、法律上は休憩60分以上が必要です" }
        if netMinutes > 360 { return "6時間超の勤務のため、法律上は休憩45分以上が必要です" }
        return nil
    }
}
