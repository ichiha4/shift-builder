import SwiftUI
import FirebaseAuth
import AuthenticationServices
import GoogleSignInSwift

/// The key `.preferredColorScheme` at the app root reads — see ShiftManagerAppApp.swift.
enum AppearanceKey {
    static let isDarkMode = "shiftmgr.isDarkMode"
}

/// The key `Bundle.setLanguage` at the app root reads — see ShiftManagerAppApp.swift. Stores
/// "system", "ja", or "en"; anything else falls back to following the device's language.
enum AppLanguageKey {
    static let language = "shiftmgr.appLanguage"
}

enum SupportInfo {
    static let email = "support@example.invalid"
    static let supportURL = URL(string: "https://github.com/ichiha4/shift-builder/issues")!
    static let privacyPolicyURL = URL(string: "https://github.com/ichiha4/shift-builder/blob/main/docs/PRIVACY.md")!

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    /// Pre-fills the environment a bug report needs, so a user who writes "the total is wrong"
    /// has already told us which build and which iOS they saw it on.
    static var mailURL: URL {
        let body = """


        ----
        アプリ: \(versionString)
        iOS: \(UIDevice.current.systemVersion)
        端末: \(UIDevice.current.model)
        """
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Shift Builderへのお問い合わせ"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url!
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject private var store: ShiftStore
    @EnvironmentObject private var subscriptions: SubscriptionManager
    @AppStorage(AppearanceKey.isDarkMode) private var isDarkMode = false
    @AppStorage(AppLanguageKey.language) private var appLanguage = "system"

    @State private var showChangePassword = false
    @State private var showSignOutConfirm = false
    @State private var showDeleteAccountConfirm = false
    @State private var copiedSupportEmail = false
    @State private var exportRecovery = false
    @Environment(\.openURL) private var openURL

    private var isEmailAccount: Bool {
        auth.user?.providerData.contains { $0.providerID == "password" } ?? false
    }

    /// Falls back to the part of the email before "@" when no display name is set (e.g. a
    /// plain email/password account never has one) — always shows something rather than blank.
    private var displayName: String {
        #if LOCAL_DEVICE_TESTING
        return "実機テスト"
        #else
        if let name = auth.user?.displayName, !name.isEmpty { return name }
        if let email = auth.user?.email { return String(email.split(separator: "@").first ?? Substring(email)) }
        return ""
        #endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 56))
                            .foregroundStyle(.secondary)
                        Text(displayName)
                            .font(.headline).fontWeight(.bold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                if store.legacyRecoveryData != nil {
                    Section("以前の端末データ") {
                        Text("同期方式の更新前にこの端末にあった記録を、確認用のファイルとして保存できます。クラウドの記録には反映されません。")
                            .font(.caption)
                        Button("以前の記録をファイルに保存") { exportRecovery = true }
                    }
                }
                Section("見た目") {
                    Picker("", selection: $isDarkMode) {
                        Label("ライト", systemImage: "sun.max.fill").tag(false)
                        Label("ナイト", systemImage: "moon.fill").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, 4)
                    Text("夜勤明けに開くならナイトの方が目に負担がかかりません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("言語") {
                    Picker("言語", selection: $appLanguage) {
                        Text("システムに合わせる").tag("system")
                        Text("日本語").tag("ja")
                        Text("English").tag("en")
                    }
                }

                Section("Shift Builder Plus") {
                    NavigationLink { PlusView() } label: {
                        LabeledContent {
                            Text(LocalizedStringKey(subscriptions.hasPlus ? "有効" : "無料プラン"))
                                .font(.caption).foregroundStyle(.secondary)
                        } label: {
                            Label("お金の計画", systemImage: "chart.line.uptrend.xyaxis")
                        }
                    }
                }

                #if LOCAL_DEVICE_TESTING
                Section("実機テスト") {
                    Text("ログインなしで操作を確認できます。記録はこのテスト用アプリの中に保存されます。")
                    Text("PlusはXcodeのテスト用購入で確認します。実際の請求はありません。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                #else
                Section("アカウント") {
                    if let email = auth.user?.email {
                        LabeledContent("メールアドレス", value: email)
                    }
                    if isEmailAccount {
                        Button("パスワードを変更") { showChangePassword = true }
                    }
                    Button("ログアウト", role: .destructive) { showSignOutConfirm = true }
                    Button("アカウントを削除", role: .destructive) { showDeleteAccountConfirm = true }
                }
                #endif

                Section("サポート") {
                    Button {
                        // With no mail account set up, mailto: goes nowhere and the tap looks
                        // broken — so fall back to copying the address and saying so.
                        openURL(SupportInfo.mailURL) { accepted in
                            if !accepted {
                                UIPasteboard.general.string = SupportInfo.email
                                copiedSupportEmail = true
                            }
                        }
                    } label: {
                        LabeledContent {
                            Text(SupportInfo.email).font(.caption)
                        } label: {
                            Label("お問い合わせ", systemImage: "envelope")
                        }
                    }
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = SupportInfo.email
                        } label: {
                            Label("メールアドレスをコピー", systemImage: "doc.on.doc")
                        }
                    }
                    Link(destination: SupportInfo.supportURL) {
                        Label("サポート・よくある質問", systemImage: "questionmark.circle")
                    }
                    Link(destination: SupportInfo.privacyPolicyURL) {
                        Label("プライバシーポリシー", systemImage: "hand.raised")
                    }
                    LabeledContent("バージョン", value: SupportInfo.versionString)
                }
            }
            .fileExporter(isPresented: $exportRecovery, document: SyncRecoveryDocument(data: store.legacyRecoveryData ?? Data()), contentType: .json, defaultFilename: "ShiftBuilder-previous-device-records") { _ in }
            .alert("メールアドレスをコピーしました", isPresented: $copiedSupportEmail) {
                Button("OK") {}
            } message: {
                Text("メールアプリが設定されていないようです。お使いのメールから \(SupportInfo.email) 宛てにお送りください。")
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showChangePassword) {
                ChangePasswordView()
                    .environmentObject(auth)
            }
            .confirmationDialog("ログアウトしますか?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("ログアウト", role: .destructive) {
                    auth.signOut()
                    dismiss()
                }
                Button("キャンセル", role: .cancel) {}
            }
            .confirmationDialog(
                "アカウントを削除しますか?",
                isPresented: $showDeleteAccountConfirm,
                titleVisibility: .visible
            ) {
                Button("削除する", role: .destructive) {
                    Task { await auth.deleteAccount() }
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("シフト・給与・支出などすべての記録が完全に削除されます。この操作は取り消せません。Plusの解約はApp Storeのサブスクリプション管理から別途行ってください。")
            }
            .alert(
                "エラー",
                isPresented: Binding(
                    get: { auth.errorMessage != nil && !auth.needsReauthToDelete },
                    set: { isPresented in if !isPresented { auth.errorMessage = nil } }
                )
            ) {
                Button("OK") { auth.errorMessage = nil }
            } message: {
                Text(auth.errorMessage ?? "")
            }
        }
    }
}

struct DeleteAccountReauthView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""

    private var providerID: String? { auth.user?.providerData.first?.providerID }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.orange)
                    Text("本人確認が必要です")
                        .font(.headline)
                    Text("セキュリティのため、アカウント削除の前にもう一度サインインしてください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 16)

                switch providerID {
                case "password":
                    SecureField("現在のパスワード", text: $password)
                        .textContentType(.password)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal, 24)

                    Button(role: .destructive) {
                        Task { await auth.reauthenticateWithPasswordAndDeleteAccount(password: password) }
                    } label: {
                        if auth.isLoading {
                            ProgressView()
                        } else {
                            Text("削除する").frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(password.isEmpty || auth.isLoading)
                    .padding(.horizontal, 24)
                case "google.com":
                    GoogleSignInButton {
                        Task { await auth.reauthenticateWithGoogleAndDeleteAccount() }
                    }
                    .frame(height: 48)
                    .padding(.horizontal, 24)
                    .disabled(auth.isLoading)
                case "apple.com":
                    SignInWithAppleButton(.continue) { request in
                        auth.prepareAppleRequest(request)
                    } onCompletion: { result in
                        auth.handleAppleReauthCompletion(result)
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 24)
                    .disabled(auth.isLoading)
                default:
                    EmptyView()
                }

                if let message = auth.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                Spacer()
            }
            .padding(.top, 8)
            .navigationTitle("本人確認")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        auth.errorMessage = nil
                        auth.needsReauthToDelete = false
                        dismiss()
                    }
                    .disabled(auth.isLoading)
                }
            }
        }
    }
}

private struct ChangePasswordView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var didSucceed = false

    private var canSubmit: Bool {
        !currentPassword.isEmpty && newPassword.count >= 6 && newPassword == confirmPassword && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("現在のパスワード", text: $currentPassword)
                        .textContentType(.password)
                    SecureField("新しいパスワード(6文字以上)", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("新しいパスワード(確認)", text: $confirmPassword)
                        .textContentType(.newPassword)
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    } else if !newPassword.isEmpty && !confirmPassword.isEmpty && newPassword != confirmPassword {
                        Text("新しいパスワードが一致しません。").foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("パスワードを変更")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("変更") { Task { await submit() } }.disabled(!canSubmit)
                    }
                }
            }
            .alert("パスワードを変更しました", isPresented: $didSucceed) {
                Button("OK") { dismiss() }
            }
        }
    }

    private func submit() async {
        guard let email = auth.user?.email else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            // Password changes require a recent sign-in — re-authenticate first so a stale
            // session doesn't surface a confusing "requires-recent-login" error instead.
            let credential = EmailAuthProvider.credential(withEmail: email, password: currentPassword)
            try await auth.user?.reauthenticate(with: credential)
            try await auth.user?.updatePassword(to: newPassword)
            didSucceed = true
        } catch {
            errorMessage = (error as NSError).localizedDescription
        }
    }
}

#Preview {
    SettingsView().environmentObject(AuthManager()).environmentObject(ShiftStore())
        .environmentObject(SubscriptionManager())
}
