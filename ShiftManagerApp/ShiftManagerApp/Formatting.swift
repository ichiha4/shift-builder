import Foundation
import SwiftUI

/// Shared surface metrics. Every screen used to declare its own card — five different corner
/// radii, and headers centred on one tab but left-aligned on the others — which is what made
/// the app read as several screens stitched together instead of one product.
enum AppStyle {
    static let cardRadius: CGFloat = 20
    static let cardPadding: CGFloat = 16
    static let controlRadius: CGFloat = 12
}

private struct CardSurface: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous))
            // The hairline is what separates a card from the page in dark mode, where the
            // grouped-background greys sit a few percent apart on a near-black ground and the
            // cards otherwise dissolve into it. It's nearly invisible in light mode by design.
            .overlay(
                RoundedRectangle(cornerRadius: AppStyle.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
    }
}

extension View {
    func appCard(padding: CGFloat = AppStyle.cardPadding) -> some View {
        modifier(CardSurface(padding: padding))
    }

    /// Caps a screen's content at a readable column and centres it. No effect on iPhone, which is
    /// never this wide; on iPad it stops a layout designed for a phone column from stretching a
    /// two-item list across 1,000 points with the amount stranded at the far edge.
    func readableColumn() -> some View {
        frame(maxWidth: 560).frame(maxWidth: .infinity)
    }
}

/// One consistent section label: left-aligned, same weight and colour everywhere, with room for
/// a trailing control. Headers were previously a mix of `.headline`, `.title3` and centred text.
struct CardHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let trailing: () -> Trailing

    init(_ title: LocalizedStringKey, systemImage: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.subheadline).fontWeight(.semibold)
            Spacer(minLength: 8)
            trailing()
        }
    }
}

extension CardHeader where Trailing == EmptyView {
    init(_ title: LocalizedStringKey, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.trailing = { EmptyView() }
    }
}

/// Base fill for the two hero cards. Not flat black: in dark mode the page behind them is
/// near-black too, so a pure-black card had no visible edge and read as a hole punched in the
/// page rather than as a card sitting on it.
let heroCardBase = LinearGradient(
    colors: [Color(white: 0.14), Color(white: 0.035)],
    startPoint: .topLeading, endPoint: .bottomTrailing
)

extension View {
    /// Rounds a hero card and gives it the faint top-edge highlight that keeps it readable as a
    /// raised surface against a near-black page.
    func heroCardShape() -> some View {
        clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.75)
            )
    }
}

/// Category → accent color, matching the web version's CAT_COLORS palette.
let expenseCategoryColors: [String: Color] = [
    "食費": Color(red: 0.961, green: 0.620, blue: 0.043),
    "交通費": Color(red: 0.231, green: 0.510, blue: 0.965),
    "日用品": Color(red: 0.063, green: 0.725, blue: 0.506),
    "娯楽": Color(red: 0.659, green: 0.333, blue: 0.969),
    "家賃・光熱": Color(red: 0.957, green: 0.247, blue: 0.369),
    "通信費": Color(red: 0.024, green: 0.714, blue: 0.831),
    "その他": Color(red: 0.420, green: 0.447, blue: 0.502),
]

func yen(_ amount: Double) -> String {
    guard amount.isFinite else { return "—" }
    return "¥" + amount.rounded().formatted(
        .number.locale(Locale(identifier: "ja_JP")).precision(.fractionLength(0)))
}

func hoursLabel(_ minutes: Int) -> String {
    String(format: "%.1fh", Double(minutes) / 60)
}

func segmentsSummary(_ segments: [WorkSegment]) -> String {
    segments.map { "\(ClockUtils.formatClock($0.startMinute))–\(ClockUtils.formatClock($0.endMinute)) ¥\(Int($0.hourlyWage))" }.joined(separator: " ・ ")
}

extension Date {
    /// Minutes since midnight, LOCAL time — the app's whole calculation engine works in this
    /// unit (see `WorkSegment`), so every time picker binds through here.
    var minutesSinceMidnight: Int {
        let c = DateUtils.calendar.dateComponents([.hour, .minute], from: self)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }
}

/// The inverse of `Date.minutesSinceMidnight` — builds a `Date` (on an arbitrary fixed day,
/// since only the hour/minute matter to a time-only `DatePicker`) from minutes since midnight.
func dateFromMinutes(_ minutes: Int) -> Date {
    var c = DateComponents()
    c.year = 2000; c.month = 1; c.day = 1
    c.hour = ((minutes % 1440) + 1440) % 1440 / 60
    c.minute = ((minutes % 1440) + 1440) % 1440 % 60
    return DateUtils.calendar.date(from: c) ?? Date()
}
