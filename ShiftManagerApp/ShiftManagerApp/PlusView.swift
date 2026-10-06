import SwiftUI
import StoreKit

struct PlusView: View {
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State private var showPaywall = false
    @State private var showPhotoImport = false
    @State private var showManage = false

    var body: some View {
        List {
            #if LOCAL_DEVICE_TESTING
            Section {
                Label("テスト用購入・実際の請求はありません", systemImage: "testtube.2")
                    .font(.caption)
            }
            #endif
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Shift Builder Plus").font(.title2.bold())
                    Text("シフトの入力を減らして、お金の予定まで。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if subscriptions.hasPlus {
                        Label("Plusは有効です", systemImage: "checkmark.seal.fill")
                            .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                    }
                }.padding(.vertical, 8)
            }
            Section("シフトの入力") {
                Button { showPhotoImport = true } label: {
                    feature("写真からシフト登録", subtitle: "日付と時間の一覧を読み取り、確認して一括登録。候補の確認は無料。", icon: "photo.badge.plus", plus: true)
                }
            }
            Section("お金の計画") {
                NavigationLink { CashFlowForecastView() } label: {
                    feature("残高予測", subtitle: "給料日と定期支出から、日ごとの残高を確認。7日分は無料。", icon: "chart.xyaxis.line")
                }
                NavigationLink {
                    if subscriptions.hasPlus { ShiftScenarioView() }
                    else { PlusPaywallView() }
                } label: {
                    feature("シフトの収入比較", subtitle: "1回増やす・減らすと、月の給与がいくら変わるか比較。", icon: "arrow.left.arrow.right", plus: true)
                }
            }
            Section {
                if subscriptions.hasPlus {
                    Button("サブスクリプションを管理") { showManage = true }
                } else {
                    Button("Plusの内容を見る") { showPaywall = true }
                }
                Button("購入を復元") { Task { await subscriptions.restore() } }
                    .disabled(subscriptions.isBusy)
                if subscriptions.isBusy { ProgressView() }
                subscriptionMessages(subscriptions)
            } footer: {
                Text("Plusの購入はApple Accountに紐付きます。アプリのログアウトやアカウント削除では解約されません。")
            }
        }
        .navigationTitle("お金の計画")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPaywall) {
            NavigationStack {
                PlusPaywallView().toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("閉じる") { showPaywall = false } }
                }
            }
        }
        .manageSubscriptionsSheet(isPresented: $showManage)
        .sheet(isPresented: $showPhotoImport) {
            NavigationStack { ShiftPhotoImportView(month: String(DateUtils.todayYMD().prefix(7))) }
        }
        .task { await subscriptions.prepare() }
    }

    private func feature(_ title: LocalizedStringKey, subtitle: LocalizedStringKey,
                         icon: String, plus: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    if plus { Text("PLUS").font(.caption2.bold()).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 6)
    }
}

struct PlusPaywallView: View {
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @State private var showManage = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                #if LOCAL_DEVICE_TESTING
                Label("テスト用購入・実際の請求はありません", systemImage: "testtube.2")
                    .font(.caption).padding(12).appCard()
                #endif
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.largeTitle)
                    Text("Shift Builder Plus").font(.largeTitle.bold())
                    Text("シフトの入力も、来月のお金も。")
                        .font(.title3.weight(.medium))
                }
                .foregroundStyle(.white).padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(heroCardBase).heroCardShape()
                VStack(alignment: .leading, spacing: 16) {
                    benefit("写真からシフトを一括登録", detail: "日付と勤務時間の一覧を読み取り、確認・修正して登録。横長の全員表や勤務記号は対応外です。", icon: "photo.badge.plus")
                    benefit("90日先までの残高予測", detail: "給料日、家賃、サブスクなどをまとめて見通せます。", icon: "calendar")
                    benefit("シフトの収入比較", detail: "勤務を1回増減したときの給与差を、残業割増も含めて確認できます。", icon: "arrow.left.arrow.right")
                }.appCard()
                if subscriptions.hasPlus {
                    Label("Plusは有効です", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Color.accentColor)
                    Button("サブスクリプションを管理") { showManage = true }
                        .buttonStyle(.bordered)
                } else if let product = subscriptions.monthlyProduct {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(product.displayPrice).font(.title.bold())
                        Text("／月").foregroundStyle(.secondary)
                    }
                    Text("月額・自動更新。解約するまで毎月更新されます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { Task { await subscriptions.purchase() } } label: {
                        HStack {
                            if subscriptions.isBusy { ProgressView().tint(.white) }
                            Text("Plusを始める").fontWeight(.semibold)
                        }.frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(subscriptions.isBusy || subscriptions.isCheckingAccess)
                } else {
                    if subscriptions.isLoadingProducts { ProgressView("料金を読み込んでいます") }
                    Button("商品情報を再読み込み") { Task { await subscriptions.prepare() } }
                        .buttonStyle(.bordered).disabled(subscriptions.isLoadingProducts)
                }
                subscriptionMessages(subscriptions)
                Button("購入を復元") { Task { await subscriptions.restore() } }
                    .disabled(subscriptions.isBusy)
                Text("シフト入力、基本の給与計算、収支の記録は無料で使えます。")
                    .font(.caption).foregroundStyle(.secondary)
                #if LOCAL_DEVICE_TESTING
                Text("この画面の購入はXcodeでの動作確認用です。料金は請求されません。")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                Text("お支払いはApple Accountに請求されます。更新・解約はApp Storeのサブスクリプション管理から行えます。アプリのアカウント削除では解約されません。")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
                HStack(spacing: 16) {
                    Link("利用規約", destination: SubscriptionManager.termsURL)
                    Link("プライバシーポリシー", destination: SupportInfo.privacyPolicyURL)
                }.font(.caption)
            }.padding(16).readableColumn()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Plus")
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showManage)
        .task { await subscriptions.prepare() }
    }

    private func benefit(_ title: LocalizedStringKey, detail: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@ViewBuilder
@MainActor
private func subscriptionMessages(_ subscriptions: SubscriptionManager) -> some View {
    if let error = subscriptions.errorKey {
        Text(LocalizedStringKey(error)).font(.footnote).foregroundStyle(.red)
    }
    if let notice = subscriptions.noticeKey {
        Text(LocalizedStringKey(notice)).font(.footnote).foregroundStyle(.secondary)
    }
}
