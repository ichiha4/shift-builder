import Foundation

/// One worked minute and the hourly wage that applies to it. Expanding a shift into these
/// is what lets late-night/overtime be judged minute-by-minute rather than only in bulk.
public struct WorkedMinute: Equatable, Sendable {
    public var clockMinute: Int
    public var wage: Double
}

public enum SegmentExpansion {
    /// Expands `segments` into one entry per worked minute, across all segments, optionally
    /// removing a precisely-timed break. Passing `breakStartMinute: nil` (or `breakMinutes
    /// <= 0`) returns every worked minute unfiltered — callers that need the raw, break-
    /// inclusive span (e.g. for the total scheduled duration) always
    /// call this with no break arguments, exactly like `expandSegments(segments, "", 0)` did
    /// in the original JS.
    public static func expand(_ segments: [WorkSegment], breakStartMinute: Int? = nil, breakMinutes: Int = 0) -> [WorkedMinute] {
        var minutes: [WorkedMinute] = []
        let ranges = Validation.absoluteRanges(segments)
        for (seg, range) in zip(segments, ranges) where seg.isUsable {
            for t in range.start..<range.end {
                minutes.append(WorkedMinute(clockMinute: t, wage: seg.hourlyWage))
            }
        }
        guard let breakStart = breakStartMinute, breakMinutes > 0 else { return minutes }
        let bs = resolveBreakStart(minutes, breakStartMinute: breakStart)
        let be = bs + breakMinutes
        return minutes.filter { !($0.clockMinute >= bs && $0.clockMinute < be) }
    }

    /// A break given as "13:00" needs to be understood as "13:00 the same day" or "13:00 the
    /// NEXT day" depending on which one actually falls inside the shift — a 22:00–06:00
    /// shift's 01:00 break lives at clock-minute 1500 (1440 + 60), not 60. Mirrors the JS
    /// `resolveBreakStart` fix.
    public static func resolveBreakStart(_ minutes: [WorkedMinute], breakStartMinute: Int) -> Int {
        let worked = Set(minutes.map(\.clockMinute))
        if worked.contains(breakStartMinute) { return breakStartMinute }
        if worked.contains(breakStartMinute + 1440) { return breakStartMinute + 1440 }
        return breakStartMinute
    }
}
