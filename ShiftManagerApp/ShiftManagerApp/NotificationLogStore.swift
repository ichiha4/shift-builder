import Foundation
import Combine
import SwiftUI

enum NotificationEventKind: String, Codable {
    case added, updated, deleted, reminder

    var systemImage: String {
        switch self {
        case .added: return "plus.circle.fill"
        case .updated: return "pencil.circle.fill"
        case .deleted: return "trash.circle.fill"
        case .reminder: return "bell.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .added: return .green
        case .updated: return .blue
        case .deleted: return .red
        case .reminder: return .orange
        }
    }
}

struct NotificationEvent: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var date: Date
    var kind: NotificationEventKind
    var title: String
    var message: String
}

/// The in-app notification history shown from the bell icon — a record of what happened
/// (shift added/deleted, upcoming-shift reminders) that's always visible in the app, distinct
/// from the OS-level push notification `NotificationScheduler` fires for the 1-hour-before
/// reminder (which needs to reach the user even when the app isn't open).
@MainActor
final class NotificationLogStore: ObservableObject {
    @Published private(set) var events: [NotificationEvent] = []
    @Published private(set) var unreadCount: Int = 0

    private let eventsKey = "shiftmgr.notificationLog"
    private let unreadKey = "shiftmgr.notificationUnreadCount"
    private let loggedPaydaysKey = "shiftmgr.notificationLoggedPaydays"
    private let maxEvents = 50

    init() {
        events = Self.decode(key: eventsKey)
        unreadCount = UserDefaults.standard.integer(forKey: unreadKey)
    }

    func log(kind: NotificationEventKind, title: String, message: String) {
        events.insert(NotificationEvent(date: Date(), kind: kind, title: title, message: message), at: 0)
        if events.count > maxEvents { events.removeLast(events.count - maxEvents) }
        unreadCount += 1
        persist()
    }

    /// Logs "it's payday" exactly once per (employer, payDate) pair, no matter how many times
    /// the Overview tab's banner re-appears (tab switches, app relaunches on the same day).
    func logPaydayIfNeeded(employer: String, payDate: String) {
        let key = "\(employer)|\(payDate)"
        var logged = Set(UserDefaults.standard.stringArray(forKey: loggedPaydaysKey) ?? [])
        guard !logged.contains(key) else { return }
        logged.insert(key)
        UserDefaults.standard.set(Array(logged), forKey: loggedPaydaysKey)
        log(kind: .reminder, title: "給料日", message: "\(employer)：給料日になりました")
    }

    /// Sign-out / account deletion: the history names that account's employers and dates.
    func reset() {
        events = []
        unreadCount = 0
        for key in [eventsKey, unreadKey, loggedPaydaysKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    func markAllRead() {
        guard unreadCount != 0 else { return }
        unreadCount = 0
        UserDefaults.standard.set(0, forKey: unreadKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(data, forKey: eventsKey)
        }
        UserDefaults.standard.set(unreadCount, forKey: unreadKey)
    }

    private static func decode(key: String) -> [NotificationEvent] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([NotificationEvent].self, from: data) else { return [] }
        return decoded
    }
}
