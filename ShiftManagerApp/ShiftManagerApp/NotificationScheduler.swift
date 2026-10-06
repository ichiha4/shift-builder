import Foundation
import UserNotifications

/// Schedules the real OS-level push notification for "shift starts in 1 hour" — the one
/// reminder that has to reach the user even when the app isn't open, unlike the in-app
/// history in `NotificationLogStore`. One pending request per shift, keyed by shift id, so
/// editing or deleting a shift can cleanly replace or cancel its own reminder without
/// touching any other shift's.
enum NotificationScheduler {
    private static func identifier(for shiftId: String) -> String { "shift-reminder-\(shiftId)" }
    private static func paydayIdentifier(employer: String, payDate: String) -> String { "payday-reminder-\(employer)-\(payDate)" }

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }
    }

    /// (Re)schedules the 1-hour-before reminder for `shift`, replacing any existing one for
    /// the same id. Silently does nothing if the shift has no usable start time or that time
    /// (minus 1h) has already passed.
    static func scheduleReminder(for shift: Shift) {
        cancelReminder(for: shift.id)
        guard let firstSegment = shift.segments.first(where: \.isUsable) else { return }
        guard let (y, m, d) = DateUtils.parseYMD(shift.date) else { return }

        var startComponents = DateComponents()
        startComponents.year = y; startComponents.month = m; startComponents.day = d
        startComponents.hour = firstSegment.startMinute / 60
        startComponents.minute = firstSegment.startMinute % 60
        // Gregorian on purpose: the date strings are Gregorian, and on a device set to 和暦 the
        // current calendar would read year 2026 as 令和2026 (Gregorian 4044), so nothing ever fired.
        guard let shiftStart = DateUtils.calendar.date(from: startComponents) else { return }

        let reminderDate = shiftStart.addingTimeInterval(-3600)
        guard reminderDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "まもなくシフト開始"
        content.body = "\(shift.employer) \(ClockUtils.formatClock(firstSegment.startMinute))〜"
        content.sound = .default

        var triggerComponents = DateUtils.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminderDate)
        triggerComponents.calendar = DateUtils.calendar
        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: identifier(for: shift.id), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// Sign-out / account deletion: nothing scheduled for that account may fire afterwards.
    static func cancelPendingForSync() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }

    static func cancelAll() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    static func cancelReminder(for shiftId: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier(for: shiftId)])
    }

    /// Schedules a 7:00 AM reminder on `payDate` (an already weekend/holiday-adjusted
    /// "YYYY-MM-DD") for `employer`. Re-scheduling the same (employer, payDate) pair replaces
    /// the existing request rather than duplicating it, since both share the same identifier.
    /// Silently does nothing if 7:00 AM that day has already passed.
    static func schedulePaydayReminder(employer: String, payDate: String) {
        guard let (y, m, d) = DateUtils.parseYMD(payDate) else { return }
        var triggerComponents = DateComponents()
        triggerComponents.year = y; triggerComponents.month = m; triggerComponents.day = d
        triggerComponents.hour = 7; triggerComponents.minute = 0
        triggerComponents.calendar = DateUtils.calendar // see scheduleReminder: never the device's 和暦
        guard let triggerDate = DateUtils.calendar.date(from: triggerComponents), triggerDate > Date() else { return }

        let content = UNMutableNotificationContent()
        content.title = "給料日です"
        content.body = "\(employer)の給料日になりました。実際の手取り額を記録しましょう。"
        content.sound = .default

        let trigger = UNCalendarNotificationTrigger(dateMatching: triggerComponents, repeats: false)
        let request = UNNotificationRequest(identifier: paydayIdentifier(employer: employer, payDate: payDate), content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    /// (Re)schedules 7:00 AM payday reminders for `profile`'s next several pay periods, so the
    /// notification reaches the user even if the app isn't reopened again until well after the
    /// payday. Called whenever a profile is saved and whenever profiles load from disk/cloud.
    static func reschedulePaydayReminders(for profile: EmployerProfile) {
        let today = DateUtils.todayYMD()
        guard let (ty, tm, _) = DateUtils.parseYMD(today) else { return }
        for offset in -1...3 {
            var y = ty, m = tm + offset
            while m < 1 { m += 12; y -= 1 }
            while m > 12 { m -= 12; y += 1 }
            let closeDay = DateUtils.resolveDay(year: y, month: m, day: profile.closingDay)
            let periodEnd = String(format: "%04d-%02d-%02d", y, m, closeDay)
            let payDate = PayPeriod.paymentDate(periodEnd: periodEnd, paydayMonthOffset: profile.paydayMonthOffset, paydayDay: profile.paydayDay, adjustment: profile.paydayAdjustment)
            schedulePaydayReminder(employer: profile.name, payDate: payDate)
        }
    }
}
