import SwiftUI

struct CalendarMonthView: View {
    let month: String
    let monthShifts: [Shift]
    let classifications: [String: [String: ShiftClassification]]
    @Binding var selectedDate: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private let weekdays = ["日", "月", "火", "水", "木", "金", "土"]

    private var year: Int { Int(month.prefix(4)) ?? 2000 }
    private var monthNum: Int { Int(month.suffix(2)) ?? 1 }
    private var daysInMonth: Int { DateUtils.lastDayOfMonth(year: year, month: monthNum) }
    private var startOffset: Int {
        let weekday = DateUtils.calendar.component(.weekday, from: DateUtils.date(year: year, month: monthNum, day: 1))
        return weekday - 1 // weekday: 1 = Sunday
    }
    private var shiftsByDate: [String: [Shift]] { Dictionary(grouping: monthShifts, by: \.date) }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { idx, w in
                    Text(w)
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(idx == 0 ? .red : idx == 6 ? .blue : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                // Negative IDs here are deliberate: this ForEach and the day-cell ForEach below
                // are siblings in the same LazyVGrid, and `id: \.self` on plain Ints let their
                // ranges collide (e.g. a month starting on Tuesday has a blank-cell range of
                // 0..<2 and a day range of 1...30 — both contain 1) — SwiftUI then silently
                // drops one of the two colliding views, which was erasing day 1 (or more, for
                // months starting later in the week) off the calendar. Negative IDs can never
                // collide with a real day number.
                ForEach(0..<startOffset, id: \.self) { i in
                    Color.clear.frame(height: 44).id(-(i + 1))
                }
                let palette = employerPalette
                ForEach(1...daysInMonth, id: \.self) { day in
                    dayCell(day, palette: palette)
                }
            }
        }
        .appCard()
    }

    /// A colour per employer appearing this month, assigned by sorted position rather than by
    /// hashing the name — hashing gave a single-job month an arbitrary colour (magenta, in
    /// practice) that matched nothing else in the app. Position means the common one-employer
    /// case is always green, the same green the pay figures use, and a second job is still
    /// clearly distinct.
    private var employerPalette: [String: Color] {
        let palette: [Color] = [.green, .blue, .orange, .purple, .pink, .teal]
        let names = Set(monthShifts.map(\.employer)).sorted()
        return Dictionary(uniqueKeysWithValues: names.enumerated().map {
            ($0.element, palette[$0.offset % palette.count])
        })
    }

    private func dayCell(_ day: Int, palette: [String: Color]) -> some View {
        let dateStr = String(format: "%04d-%02d-%02d", year, monthNum, day)
        let dayShifts = shiftsByDate[dateStr] ?? []
        let isSelected = selectedDate == dateStr
        let weekday = DateUtils.calendar.component(.weekday, from: DateUtils.date(year: year, month: monthNum, day: day))
        let dayColor: Color = isSelected ? .white : (weekday == 1 ? .red : weekday == 7 ? .blue : .primary)
        let employers = Array(Set(dayShifts.map(\.employer))).sorted()

        return Button {
            selectedDate = dateStr
        } label: {
            VStack(spacing: 4) {
                Text("\(day)")
                    .font(.subheadline)
                    .foregroundStyle(dayColor)
                    .frame(width: 28, height: 28)
                    .background(isSelected ? Color.accentColor : Color.clear)
                    .clipShape(Circle())
                // Dots rather than the employer's name: for the common single-job month the name
                // repeated under fifteen cells was pure noise, and it forced a cell tall enough to
                // push the selected-day card off screen. Colour still distinguishes two jobs.
                HStack(spacing: 3) {
                    ForEach(employers.prefix(3), id: \.self) { employer in
                        Circle()
                            .fill(palette[employer] ?? .green)
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        // Without this a screen reader announces only the bare day number: the dots that say
        // "you work here that day" are drawn, not spoken, so the whole point of the grid is lost.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(monthNum)月\(day)日")
        .accessibilityValue(employers.isEmpty ? "シフトなし" : employers.joined(separator: "、"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
