import SwiftUI

extension ShiftsTab {
    /// The heading opens a readable list; each pattern has its own explicit actions.
    struct TemplateManagerView: View {
        @EnvironmentObject private var store: ShiftStore
        @EnvironmentObject private var notifications: NotificationLogStore
        @Environment(\.dismiss) private var dismiss
        @Environment(\.colorScheme) private var colorScheme
        let formats: [ShiftFormat]
        let date: String
        let onSave: (ShiftTemplate, ShiftFormat) -> Void
        let onDelete: (ShiftFormat) -> String?
        @State private var editingFormat: ShiftFormat?
        @State private var deletingFormat: ShiftFormat?
        @State private var deletionError: String?

        private var accent: Color {
            colorScheme == .dark ? Color(red: 0.40, green: 0.91, blue: 0.73) : Color(red: 0.035, green: 0.44, blue: 0.33)
        }

        var body: some View {
            NavigationStack {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("勤務パターン")
                            Spacer()
                            Text("\(formats.count)件")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.bottom, 4)
                        if formats.isEmpty {
                            Text("表示中のテンプレートはありません。")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 100)
                        }
                        ForEach(formats) { format in
                            templateRow(format)
                        }
                        Text("登録済みのシフトはそのまま残ります。")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 4).padding(.top, 8)
                    }
                    .padding(16)
                    .readableColumn()
                }
                .background(Color(.systemGroupedBackground))
                .navigationTitle("テンプレート")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.subheadline.weight(.medium))
                        }
                        .accessibilityLabel("閉じる")
                    }
                }
                .sheet(item: $editingFormat) { format in
                    ShiftFormView(date: date, existing: format.source, isTemplate: true, existingTemplate: format.template) { template in
                        onSave(template, format)
                    }
                        .environmentObject(store)
                        .environmentObject(notifications)
                }
                .alert("テンプレートを削除しますか？", isPresented: Binding(
                    get: { deletingFormat != nil },
                    set: { if !$0 { deletingFormat = nil } }
                ), presenting: deletingFormat) { format in
                    Button("削除する", role: .destructive) {
                        deletingFormat = nil
                        deletionError = onDelete(format)
                    }
                    Button("キャンセル", role: .cancel) { deletingFormat = nil }
                } message: { format in
                    let segments = format.segments.map {
                        "\(ClockUtils.formatClock($0.startMinute))–\(ClockUtils.formatClock($0.endMinute))  \(yen($0.hourlyWage))"
                    }.joined(separator: "\n")
                    Text(verbatim: "\(format.employer)\n\(segments)\n\n") + Text("登録済みのシフトは削除されません。")
                }
                .alert("テンプレートを削除できません", isPresented: Binding(
                    get: { deletionError != nil },
                    set: { if !$0 { deletionError = nil } }
                )) {
                    Button("閉じる", role: .cancel) { deletionError = nil }
                } message: {
                    Text(deletionError ?? "")
                }
            }
        }

        private func templateRow(_ format: ShiftFormat) -> some View {
            let isDark = colorScheme == .dark
            let ink = isDark ? Color.white : Color(red: 0.12, green: 0.20, blue: 0.18)
            let secondaryInk = isDark ? Color.white.opacity(0.62) : Color(red: 0.40, green: 0.47, blue: 0.44)
            let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
            return HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: "briefcase").font(.caption2).foregroundStyle(accent)
                        Text(format.employer).font(.subheadline.weight(.medium))
                            .foregroundStyle(ink.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(format.segments.indices, id: \.self) { index in
                            let segment = format.segments[index]
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(ClockUtils.formatClock(segment.startMinute))
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(accent.opacity(0.65))
                                        .accessibilityHidden(true)
                                    Text(ClockUtils.formatClock(segment.endMinute))
                                }
                                .font(.title.weight(.regular))
                                .foregroundStyle(ink)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: "\(ClockUtils.formatClock(segment.startMinute))–\(ClockUtils.formatClock(segment.endMinute))"))
                                HStack(spacing: 5) {
                                    Text("時給")
                                    Text(yen(segment.hourlyWage))
                                }
                                .font(.caption).foregroundStyle(secondaryInk)
                            }
                        }
                        if format.source.breakMinutes > 0 {
                            Text("休憩\(format.source.breakMinutes)分").font(.caption).foregroundStyle(secondaryInk)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    Button { editingFormat = format } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "pencil").font(.body)
                            Text("編集").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: 48).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(accent)
                    .accessibilityLabel(Text("編集") + Text(verbatim: "、\(format.employer)"))
                    Button(role: .destructive) { deletingFormat = format } label: {
                        VStack(spacing: 5) {
                            Image(systemName: "trash").font(.body)
                            Text("削除").font(.caption2).lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(width: 48).frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(secondaryInk)
                    .accessibilityLabel(Text("削除") + Text(verbatim: "、\(format.employer)"))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 7).padding(.vertical, 12)
                .frame(maxHeight: .infinity)
                .background(accent.opacity(isDark ? 0.025 : 0.015))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(LinearGradient(colors: [accent.opacity(0.08), accent.opacity(0.55), accent.opacity(0.12)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 1)
                        .padding(.vertical, 16)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .background {
                LinearGradient(colors: isDark
                               ? [Color(red: 0.10, green: 0.13, blue: 0.14), Color(red: 0.045, green: 0.065, blue: 0.06)]
                               : [.white, Color(red: 0.975, green: 0.99, blue: 0.985)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .overlay {
                        RadialGradient(colors: [accent.opacity(isDark ? 0.16 : 0.085), .clear],
                                       center: .topTrailing, startRadius: 0, endRadius: 220)
                    }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(LinearGradient(colors: isDark
                                                 ? [.white.opacity(0.2), accent.opacity(0.2), .white.opacity(0.06)]
                                                 : [.white, accent.opacity(0.17), accent.opacity(0.08)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            }
            .shadow(color: .black.opacity(isDark ? 0.13 : 0.045), radius: 10, x: 0, y: 5)
            .accessibilityElement(children: .contain)
        }
    }
}
