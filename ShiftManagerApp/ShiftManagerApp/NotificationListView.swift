import SwiftUI

struct NotificationListView: View {
    @EnvironmentObject var notifications: NotificationLogStore
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "M/d HH:mm"
        f.locale = Locale(identifier: "ja_JP")
        return f
    }()

    var body: some View {
        NavigationStack {
            Group {
                if notifications.events.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("通知はまだありません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(notifications.events) { event in
                        HStack(alignment: .center, spacing: 12) {
                            Image(systemName: event.kind.systemImage)
                                .font(.system(size: 22))
                                .foregroundStyle(event.kind.tint)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(event.title).fontWeight(.semibold)
                                    Spacer()
                                    Text(dateFormatter.string(from: event.date))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(event.message)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("通知")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .onAppear { notifications.markAllRead() }
        }
    }
}

#Preview {
    NotificationListView().environmentObject(NotificationLogStore())
}
