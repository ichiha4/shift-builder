import Foundation
import FirebaseAuth
import FirebaseFirestore
import GoogleSignIn
import AuthenticationServices
import CryptoKit
import UIKit

/// Wraps Firebase Auth for the three sign-in methods the app supports (email/password, Google,
/// Apple). `user` drives which screen ShiftManagerAppApp shows; ShiftStore is attached/detached
/// to the signed-in uid from there so data always syncs to the right account.
@MainActor
final class AuthManager: NSObject, ObservableObject {
    @Published private(set) var user: FirebaseAuth.User?
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// Set when `deleteAccount()` is rejected because the session is too old — Firebase
    /// requires a *recently* established sign-in for account deletion, not just a valid one, so
    /// this routinely happens even for a user who never signed out. SettingsView watches this to
    /// present the matching reauth flow for whichever provider the account uses.
    @Published var needsReauthToDelete = false

    /// Wired by the app. Account deletion must silence cloud sync before deleting the document
    /// (or the store's listener would upload it again), and sign-out / deletion wipe this
    /// device's copy of the account.
    weak var dataStore: ShiftStore?

    private var authStateHandle: AuthStateDidChangeListenerHandle?
    private var remoteDeletionCheck: Task<Void, Never>?
    private var currentNonce: String?

    init(restoreSession: Bool = true) {
        super.init()
        guard restoreSession else { return }
        user = Auth.auth().currentUser
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self else { return }
            if self.user !== user {
                self.remoteDeletionCheck?.cancel()
                self.remoteDeletionCheck = nil
            }
            self.user = user
        }
    }

    deinit {
        remoteDeletionCheck?.cancel()
        if let handle = authStateHandle { Auth.auth().removeStateDidChangeListener(handle) }
    }

    // MARK: - Email / password

    func signUp(email: String, password: String) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await Auth.auth().createUser(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    func signIn(email: String, password: String) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            _ = try await Auth.auth().signIn(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    func sendPasswordReset(email: String) async {
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            try await Auth.auth().sendPasswordReset(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines))
            errorMessage = "パスワード再設定メールを送信しました。"
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    // MARK: - Google

    func signInWithGoogle() async {
        errorMessage = nil
        guard let rootVC = Self.topViewController() else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Googleログインに失敗しました。"
                return
            }
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            _ = try await Auth.auth().signIn(with: credential)
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    // MARK: - Apple

    /// Called from `SignInWithAppleButton`'s `onRequest`.
    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentNonce = nonce
        request.requestedScopes = [.email, .fullName]
        request.nonce = Self.sha256(nonce)
    }

    /// Called from `SignInWithAppleButton`'s `onCompletion`.
    func handleAppleCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            // Cancelling the sheet is reported as an error too — don't surface that as one.
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = Self.friendlyMessage(error)
            }
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = appleIDCredential.identityToken,
                  let idTokenString = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Appleログインに失敗しました。"
                return
            }
            let credential = OAuthProvider.credential(
                withProviderID: "apple.com",
                idToken: idTokenString,
                rawNonce: nonce,
                accessToken: nil
            )
            Task {
                isLoading = true
                defer { isLoading = false }
                do {
                    _ = try await Auth.auth().signIn(with: credential)
                } catch {
                    errorMessage = Self.friendlyMessage(error)
                }
            }
        }
    }

    // MARK: - Delete account

    private func performAccountDeletion(for user: FirebaseAuth.User) async throws {
        guard self.user?.uid == user.uid, let dataStore else { return }
        do {
            if dataStore.hasInterruptedAccountDeletion { try await dataStore.recoverAccountDataAfterFailedDeletion() }
            try await dataStore.prepareAccountDeletion()
            try await user.delete()
        } catch {
            // A lost response can mean Auth deletion succeeded. Confirm Auth still exists
            // before restoring any cloud data; offline failures retain the backup for retry.
            do {
                try await user.reload()
                try await dataStore.recoverAccountDataAfterFailedDeletion()
            } catch let recoveryError as NSError {
                if Self.isDeletedAuthSession(recoveryError) {
                    dataStore.wipeLocalData()
                    try? Auth.auth().signOut()
                    return
                }
                errorMessage = "削除を完了できませんでした。記録はこの端末に保管しています。通信環境を確認して、アカウント削除を再開してください。"
                throw recoveryError
            }
            throw error
        }
        if self.user == nil || self.user?.uid == user.uid { dataStore.wipeLocalData() }
    }

    func deleteAccount() async {
        guard user != nil, !isLoading else { return }
        errorMessage = nil
        // Always establish a fresh provider session BEFORE changing cloud records.
        needsReauthToDelete = true
    }

    static func isDeletedAuthSession(_ error: NSError) -> Bool {
        guard error.domain == AuthErrorDomain else { return false }
        return [AuthErrorCode.userNotFound.rawValue, AuthErrorCode.invalidUserToken.rawValue,
                AuthErrorCode.userTokenExpired.rawValue].contains(error.code)
    }

    /// The cloud marker is set before Auth deletion. Keep another device's unsent
    /// journal until Auth confirms deletion; a rollback must be able to resume that work.
    func watchRemoteAccountDeletion() {
        guard remoteDeletionCheck == nil, let uid = user?.uid else { return }
        remoteDeletionCheck = Task { [weak self] in
            defer { if !Task.isCancelled { self?.remoteDeletionCheck = nil } }
            while !Task.isCancelled, let self, let user = self.user,
                  user.uid == uid, self.dataStore?.remoteDeletionPending == true {
                do { try await user.reload() }
                catch let error as NSError {
                    guard !Task.isCancelled, self.user === user,
                          self.dataStore?.isAttached(to: uid) == true,
                          self.dataStore?.remoteDeletionPending == true else { return }
                    if Self.isDeletedAuthSession(error) { self.signOut(); return }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func recoverInterruptedAccountDeletion() async {
        guard let user, let dataStore, dataStore.hasInterruptedAccountDeletion else { return }
        do {
            try await user.reload()
            try await dataStore.recoverAccountDataAfterFailedDeletion()
        } catch let error as NSError {
            if Self.isDeletedAuthSession(error) { signOut() }
            else { errorMessage = "アカウント削除の確認が必要です。通信環境を確認し、削除を再開してください。" }
        }
    }

    func reauthenticateWithPasswordAndDeleteAccount(password: String) async {
        guard let user = self.user, let email = user.email else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let credential = EmailAuthProvider.credential(withEmail: email.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            try await user.reauthenticate(with: credential)
            try await performAccountDeletion(for: user)
            needsReauthToDelete = false
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    func reauthenticateWithGoogleAndDeleteAccount() async {
        guard let user = self.user, let rootVC = Self.topViewController() else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Googleログインに失敗しました。"
                return
            }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            try await user.reauthenticate(with: credential)
            try await performAccountDeletion(for: user)
            needsReauthToDelete = false
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    /// Mirrors `handleAppleCompletion`, but reauthenticates the current user and deletes instead
    /// of signing in. Reuses `prepareAppleRequest` for the request side — the nonce/scope setup
    /// is identical either way.
    func handleAppleReauthCompletion(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = Self.friendlyMessage(error)
            }
        case .success(let authorization):
            guard let user = self.user,
                  let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let nonce = currentNonce,
                  let tokenData = appleIDCredential.identityToken,
                  let idTokenString = String(data: tokenData, encoding: .utf8) else {
                errorMessage = "Appleログインに失敗しました。"
                return
            }
            let credential = OAuthProvider.credential(
                withProviderID: "apple.com",
                idToken: idTokenString,
                rawNonce: nonce,
                accessToken: nil
            )
            Task {
                isLoading = true; errorMessage = nil
                defer { isLoading = false }
                do {
                    try await user.reauthenticate(with: credential)
                    guard let codeData = appleIDCredential.authorizationCode,
                          let code = String(data: codeData, encoding: .utf8) else {
                        errorMessage = "Appleログインに失敗しました。"
                        return
                    }
                    try await Auth.auth().revokeToken(withAuthorizationCode: code)
                    try await performAccountDeletion(for: user)
                    needsReauthToDelete = false
                } catch {
                    errorMessage = Self.friendlyMessage(error)
                }
            }
        }
    }

    // MARK: - Sign out

    func signOut() {
        remoteDeletionCheck?.cancel(); remoteDeletionCheck = nil
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            dataStore?.wipeLocalData()
        } catch {
            errorMessage = Self.friendlyMessage(error)
        }
    }

    // MARK: - Helpers

    private static func topViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return nil }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        return top
    }

    private static func friendlyMessage(_ error: Error) -> String {
        let error = error as NSError
        // Only domain/code: never log entered email, password or tokens.
        print("Authentication failure: \(error.domain) [\(error.code)]")
        if error.domain == ASAuthorizationError.errorDomain {
            if error.code == ASAuthorizationError.canceled.rawValue {
                return "Appleログインをキャンセルしました。"
            }
            return "Appleログインを完了できませんでした。端末のApple Accountとアプリの署名・設定を確認してください。メールまたはGoogleでもログインできます。"
        }
        guard error.domain == AuthErrorDomain else {
            return "\(error.localizedDescription) (\(error.domain): \(error.code))"
        }
        switch AuthErrorCode.Code(rawValue: error.code) {
        case .invalidEmail:
            return "メールアドレスの形式を確認してください。"
        case .emailAlreadyInUse:
            return "このメールアドレスは登録済みです。「ログインはこちら」からログインしてください。"
        case .wrongPassword, .invalidCredential:
            return "メールアドレスまたはパスワードが正しくありません。"
        case .userNotFound:
            return "アカウントが見つかりません。先にメールアドレスで新規登録してください。"
        case .weakPassword:
            return "パスワードは6文字以上で入力してください。"
        case .keychainError:
            return "端末に認証情報を保存できませんでした。アプリの署名設定を確認する必要があります。"
        case .networkError:
            return "通信できませんでした。インターネット接続を確認して、もう一度お試しください。"
        case .operationNotAllowed:
            return "このログイン方法は現在利用できません。アプリの認証設定を確認する必要があります。"
        case .tooManyRequests:
            return "試行回数が多いため一時的に制限されています。少し待ってからお試しください。"
        default:
            return "\(error.localizedDescription) (認証エラー: \(error.code))"
        }
    }

    /// Standard nonce + SHA256 helpers from Apple/Firebase's Sign in with Apple guide — the
    /// nonce round-trips through Apple's servers, so it must be unguessable and its hash must
    /// match what we send Firebase.
    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            fatalError("Unable to generate nonce.")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.map { String(format: "%02x", $0) }.joined()
    }
}
