import SwiftUI
import AuthenticationServices
import GoogleSignInSwift

struct LoginView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var email = ""
    @State private var password = ""
    @State private var isSignUp = false
    @FocusState private var focusedField: Field?

    private enum Field { case email, password }

    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isSignUp ? password.count >= 6 : !password.isEmpty) && !auth.isLoading
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 40)

                VStack(spacing: 6) {
                    Image("BrandMark")
                        .resizable().scaledToFit().frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .accessibilityHidden(true)
                    Text(verbatim: "Shift Builder")
                        .font(.system(.title, design: .rounded, weight: .bold))
                    Text("シフトと給料日を、ひとつに。")
                        .font(.subheadline).foregroundStyle(.secondary)
                        .padding(.top, 4)
                }

                VStack(spacing: 12) {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    SecureField(isSignUp ? "パスワード(6文字以上)" : "パスワード", text: $password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .padding(14)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let message = auth.errorMessage {
                    Text(LocalizedStringKey(message))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                Button {
                    focusedField = nil
                    Task {
                        if isSignUp {
                            await auth.signUp(email: email, password: password)
                        } else {
                            await auth.signIn(email: email, password: password)
                        }
                    }
                } label: {
                    Group {
                        if auth.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text(LocalizedStringKey(isSignUp ? "新規登録" : "ログイン")).fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)

                if email.isEmpty || password.isEmpty {
                    Text("メールで続けるには、メールアドレスとパスワードを入力してください。")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if isSignUp && password.count < 6 {
                    Text("パスワードは6文字以上で入力してください。")
                        .font(.caption).foregroundStyle(.orange)
                }

                HStack(spacing: 16) {
                    Button(isSignUp ? "ログインはこちら" : "アカウントを作成") {
                        isSignUp.toggle()
                        auth.errorMessage = nil
                    }
                    if !isSignUp {
                        Button("パスワードを忘れた場合") {
                            Task { await auth.sendPasswordReset(email: email) }
                        }
                        .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .font(.footnote)
                .disabled(auth.isLoading)

                HStack(spacing: 10) {
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                    Text("または").font(.caption).foregroundStyle(.secondary)
                    Rectangle().fill(Color(.separator)).frame(height: 1)
                }

                VStack(spacing: 12) {
                    GoogleSignInButton {
                        Task { await auth.signInWithGoogle() }
                    }
                    .frame(height: 48)
                    .disabled(auth.isLoading)

                    SignInWithAppleButton(.signIn) { request in
                        auth.prepareAppleRequest(request)
                    } onCompletion: { result in
                        auth.handleAppleCompletion(result)
                    }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .padding(24)
            // Without the cap, the sign-in fields and both provider buttons stretch the full
            // width of an iPad — a 1,000-point-wide password field is the first thing a reviewer
            // opening this app on a tablet would see.
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }
}

#Preview {
    LoginView().environmentObject(AuthManager())
}
