import Foundation

public struct ShiftImportCandidate: Equatable, Identifiable, Sendable {
    public var id: Int
    public var date: String
    public var startMinute: Int
    public var endMinute: Int
    public var breakMinutes: Int
    public var source: String
    public var breakWasRead: Bool

    public init(id: Int, date: String, startMinute: Int, endMinute: Int,
                breakMinutes: Int = 0, source: String = "", breakWasRead: Bool = false) {
        self.id = id; self.date = date; self.startMinute = startMinute; self.endMinute = endMinute
        self.breakMinutes = breakMinutes; self.source = source; self.breakWasRead = breakWasRead
    }
}

public struct ShiftImportIssue: Equatable, Sendable {
    public var source: String
    public var reason: String
}

public struct ShiftImportParseResult: Equatable, Sendable {
    public var candidates: [ShiftImportCandidate]
    public var issues: [ShiftImportIssue]
}

public enum ShiftImportError: LocalizedError, Equatable {
    case invalidMonth
    case noSelection
    case invalidProfile
    case invalidRow(Int, String)
    case overlappingShift(String)
    case storeUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidMonth: return "対象年月をYYYY-MMの形式で入力してください。"
        case .noSelection: return "登録するシフトを選んでください。"
        case .invalidProfile: return "勤務先と、1円以上の時給を確認してください。"
        case .invalidRow(_, let message): return message
        case .overlappingShift(let date):
            return "\(date)の同じ勤務先に、時間が重なるシフトがあります。既存のシフトを確認・編集してください。"
        case .storeUnavailable: return "アカウントの読み込み・同期状態を確認してから登録してください。"
        }
    }
}

public enum ShiftImportParser {
    /// First version accepts a personal list with one date and one time range per line.
    /// It never guesses schedule codes, staff rows, or a date from another line.
    public static func parse(lines: [String], month: String) throws -> ShiftImportParseResult {
        guard let selected = monthParts(month) else { throw ShiftImportError.invalidMonth }
        var candidates: [ShiftImportCandidate] = []
        var issues: [ShiftImportIssue] = []
        for (index, source) in lines.enumerated() {
            let text = (source.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? source)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let full = match(#"^(\d{4})[年/.-](\d{1,2})[月/.-](\d{1,2})日?"#, text)
            let partial = full == nil ? match(#"^(\d{1,2})[月/.-](\d{1,2})日?"#, text) : nil
            let dayOnly = full == nil && partial == nil ? match(#"^(\d{1,2})(?:日|(?=\s|\())"#, text) : nil
            let found = full ?? partial ?? dayOnly
            guard let found else {
                if !timeMatches(text).isEmpty {
                    issues.append(.init(source: source, reason: "行の先頭の日付を確認できません。"))
                }
                continue
            }
            let ns = text as NSString
            let year = full.map { number($0, 1, ns) } ?? selected.year
            let monthNumber = full.map { number($0, 2, ns) } ?? partial.map { number($0, 1, ns) } ?? selected.month
            let day = full.map { number($0, 3, ns) } ?? partial.map { number($0, 2, ns) } ?? dayOnly.map { number($0, 1, ns) } ?? 0
            guard let date = validDate(year: year, month: monthNumber, day: day) else {
                issues.append(.init(source: source, reason: "日付が正しくありません。"))
                continue
            }
            let remainder = ns.substring(from: found.range.location + found.range.length)
            if match(#"午[前後]|(?i)\b(?:AM|PM)\b"#, remainder) != nil {
                issues.append(.init(source: source, reason: "午前・午後の表記には対応していません。24時間表記で確認してください。"))
                continue
            }
            let times = timeMatches(remainder)
            guard times.count == 1 else {
                issues.append(.init(source: source, reason: times.isEmpty ? "勤務時間を確認できません。" : "複数の勤務時間があるため、自動で選べません。"))
                continue
            }
            let time = times[0]; let remaining = remainder as NSString
            let startHour = number(time, 1, remaining)
            let startMinute = optionalNumber(time, 2, remaining) ?? optionalNumber(time, 3, remaining) ?? 0
            let endHour = number(time, 4, remaining)
            let endMinute = optionalNumber(time, 5, remaining) ?? optionalNumber(time, 6, remaining) ?? 0
            guard (0..<24).contains(startHour), (0..<60).contains(startMinute),
                  (0...24).contains(endHour), (0..<60).contains(endMinute),
                  endHour != 24 || endMinute == 0 else {
                issues.append(.init(source: source, reason: "時刻が正しくありません。"))
                continue
            }
            let start = startHour * 60 + startMinute, end = (endHour * 60 + endMinute) % 1440
            guard start != end else {
                issues.append(.init(source: source, reason: "開始と終了が同じ時刻です。"))
                continue
            }
            let pause = match(#"休憩\s*[:：]?\s*(\d{1,3})\s*分"#, remainder)
            candidates.append(.init(id: index, date: date, startMinute: start, endMinute: end,
                                    breakMinutes: pause.map { number($0, 1, remaining) } ?? 0,
                                    source: source, breakWasRead: pause != nil))
        }
        return .init(candidates: candidates, issues: issues)
    }

    public static func monthParts(_ month: String) -> (year: Int, month: Int)? {
        guard let result = match(#"^(\d{4})-(\d{2})$"#, month) else { return nil }
        let ns = month as NSString
        let year = number(result, 1, ns), value = number(result, 2, ns)
        guard validDate(year: year, month: value, day: 1) != nil else { return nil }
        return (year, value)
    }

    public static func isValidDate(_ text: String) -> Bool {
        guard let result = match(#"^(\d{4})-(\d{2})-(\d{2})$"#, text) else { return false }
        let ns = text as NSString
        return validDate(year: number(result, 1, ns), month: number(result, 2, ns), day: number(result, 3, ns)) == text
    }

    private static func validDate(year: Int, month: Int, day: Int) -> String? {
        guard (1900...2200).contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return nil }
        let actual = calendar.dateComponents([.year,.month,.day], from: date)
        guard actual.year == year, actual.month == month, actual.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func timeMatches(_ text: String) -> [NSTextCheckingResult] {
        let pattern = #"(?<![\d:])(\d{1,2})(?::(\d{2})|時(?:(\d{1,2})分?)?)?\s*[-~〜～－–—]\s*(?:翌日?\s*)?(\d{1,2})(?::(\d{2})|時(?:(\d{1,2})分?)?)?(?![\d:])"#
        return (try? NSRegularExpression(pattern: pattern))?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
    }
    private static func match(_ pattern: String, _ text: String) -> NSTextCheckingResult? {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func number(_ match: NSTextCheckingResult, _ group: Int, _ text: NSString) -> Int {
        optionalNumber(match, group, text) ?? 0
    }
    private static func optionalNumber(_ match: NSTextCheckingResult, _ group: Int, _ text: NSString) -> Int? {
        let range = match.range(at: group)
        return range.location == NSNotFound ? nil : Int(text.substring(with: range))
    }
}

public struct ShiftImportPlan: Sendable {
    public var shifts: [Shift]
    public var duplicateCount: Int
}

public enum ShiftImportPlanner {
    /// Validates the whole selection before writing anything. Existing records are preserved.
    public static func plan(candidates: [ShiftImportCandidate], profile: EmployerProfile,
                            existing: [Shift]) throws -> ShiftImportPlan {
        guard !candidates.isEmpty else { throw ShiftImportError.noSelection }
        let employer = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !employer.isEmpty, profile.defaultWage.isFinite, profile.defaultWage > 0,
              profile.defaultTransport.isFinite, profile.defaultTransport >= 0,
              profile.otherAllowance.isFinite, profile.otherAllowance >= 0,
              profile.scheduledHours.isFinite, (0...24).contains(profile.scheduledHours) else {
            throw ShiftImportError.invalidProfile
        }
        var additions: [Shift] = [], duplicates = 0
        for candidate in candidates {
            guard ShiftImportParser.isValidDate(candidate.date),
                  (0..<1440).contains(candidate.startMinute), (0..<1440).contains(candidate.endMinute) else {
                throw ShiftImportError.invalidRow(candidate.id, "\(candidate.date)の日付・時刻を確認してください。")
            }
            let segment = WorkSegment(startMinute: candidate.startMinute, endMinute: candidate.endMinute, hourlyWage: profile.defaultWage)
            let errors = Validation.validateShift(segments: [segment], breakMinutes: candidate.breakMinutes,
                                                breakStartMinute: nil, lateNightRate: profile.lateNightRate,
                                                overtimeRate: profile.overtimeRate, holidayRate: profile.holidayRate)
            guard errors.isEmpty else { throw ShiftImportError.invalidRow(candidate.id, "\(candidate.date): " + errors.joined(separator: " ")) }
            let shift = Shift(date: candidate.date, employer: employer, segments: [segment],
                              breakMinutes: candidate.breakMinutes, transport: profile.defaultTransport,
                              otherAllowance: profile.otherAllowance, scheduledMinutes: profile.scheduledMinutes,
                              lateNightRate: profile.lateNightRate, overtimeRate: profile.overtimeRate, holidayRate: profile.holidayRate)
            let sameDay = (existing + additions).filter {
                $0.date == shift.date && $0.employer.trimmingCharacters(in: .whitespacesAndNewlines) == employer
            }
            if sameDay.contains(where: { $0.segments.count == 1 && $0.segments[0].startMinute == segment.startMinute && $0.segments[0].endMinute == segment.endMinute }) {
                duplicates += 1
                continue
            }
            let incoming = Validation.absoluteRange(segment)
            if sameDay.contains(where: { record in
                Validation.absoluteRanges(record.segments).contains { $0.start < incoming.end && incoming.start < $0.end }
            }) { throw ShiftImportError.overlappingShift(candidate.date) }
            additions.append(shift)
        }
        return .init(shifts: additions, duplicateCount: duplicates)
    }
}
