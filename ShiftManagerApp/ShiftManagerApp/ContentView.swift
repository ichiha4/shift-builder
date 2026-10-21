import SwiftUI

enum AppTab: Hashable { case home, shifts, wages }

struct ContentView: View {
    @EnvironmentObject var store: ShiftStore
    @EnvironmentObject var auth: AuthManager
    @State private var selectedTab: AppTab = .home
    @State private var requestedShiftDate: String?
    @State private var month: String = DateUtils.todayYMD().prefix(7).description

    private var canDisplayData: Bool {
        #if LOCAL_DEVICE_TESTING
        return store.cloudDataReady && store.isAttached(to: LocalDeviceTestTransport.accountID)
        #else
        guard let uid = auth.user?.uid else { return false }
        return store.cloudDataReady && store.isAttached(to: uid)
        #endif
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewTab(month: $month, selectedTab: $selectedTab, requestedShiftDate: $requestedShiftDate)
                .tabItem { Label("ホーム", systemImage: "house.fill") }
                .tag(AppTab.home)
            ShiftsTab(month: $month, requestedDate: $requestedShiftDate)
                .tabItem { Label("シフト", systemImage: "clock.fill") }
                .tag(AppTab.shifts)
            WageTab(month: $month)
                .tabItem { Label("給与", systemImage: "wallet.pass.fill") }
                .tag(AppTab.wages)
        }
        .opacity(canDisplayData ? 1 : 0)
        .disabled(!canDisplayData)
        .safeAreaInset(edge: .top, spacing: 0) {
            #if !LOCAL_DEVICE_TESTING
            SyncStatusView().environmentObject(store).opacity(canDisplayData ? 1 : 0).disabled(!canDisplayData)
            #endif
        }
        .overlay {
            if !canDisplayData {
                VStack(spacing: 16) {
                    if !store.cloudReadFailed { ProgressView() }
                    if store.remoteDeletionPending {
                        Text("別の端末でのアカウント削除を確認しています。記録はこの端末に保管しています。")
                            .font(.subheadline).multilineTextAlignment(.center)
                    }
                    Text(LocalizedStringKey(store.cloudReadFailed ? "データを読み込めませんでした" : "データを同期しています"))
                        .font(.headline)
                    Text("履歴を保護するため、データの読み込みが終わるまで編集できません。通信環境を確認してください。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if store.hasInterruptedAccountDeletion {
                        Button("アカウント削除を再開") { auth.needsReauthToDelete = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("再読み込み") {
                        #if LOCAL_DEVICE_TESTING
                        let uid = LocalDeviceTestTransport.accountID
                        #else
                        guard let uid = auth.user?.uid else { return }
                        #endif
                        store.detachUser(clearLocalState: false)
                        store.attachUser(uid: uid)
                        #if !LOCAL_DEVICE_TESTING
                        Task { await auth.recoverInterruptedAccountDeletion() }
                        #endif
                    }
                    .buttonStyle(.borderedProminent)
                    #if !LOCAL_DEVICE_TESTING
                    Button("ログアウト") { auth.signOut() }
                    #endif
                }
                .padding(28).frame(maxWidth: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
    }
}

#Preview {
    ContentView().environmentObject(ShiftStore())
}
