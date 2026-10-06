import SwiftUI

/// Manage saved employer profiles — the piece that was missing entirely: without one of
/// these, a shift's employer-name defaults never auto-fill and the Wage tab's payday card
/// (which only renders once `store.employerProfiles` is non-empty) never appears.
struct EmployerProfilesView: View {
    @EnvironmentObject var store: ShiftStore
    @Environment(\.dismiss) private var dismiss

    @State private var showAddSheet = false
    @State private var editingProfile: EmployerProfile?

    var body: some View {
        NavigationStack {
            Group {
                if store.employerProfiles.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "building.2")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text("勤務先はまだ登録されていません")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("登録すると、シフト追加時に時給などが自動入力されます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.employerProfiles) { profile in
                            Button {
                                editingProfile = profile
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name).fontWeight(.semibold).foregroundStyle(.primary)
                                    (Text(LocalizedStringKey(profile.employmentType))
                                        + Text("・時給")
                                        + (profile.defaultWage > 0 ? Text(yen(profile.defaultWage)) : Text("未設定")))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indices in
                            for index in indices { store.deleteEmployerProfile(id: store.employerProfiles[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("勤務先の管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddSheet) {
                EmployerProfileFormView(existing: nil).environmentObject(store)
            }
            .sheet(item: $editingProfile) { profile in
                EmployerProfileFormView(existing: profile).environmentObject(store)
            }
        }
    }
}

#Preview {
    EmployerProfilesView().environmentObject(ShiftStore())
}
