import SwiftUI
import FirebaseCore
import GoogleSignIn

@main
struct ShiftManagerAppApp: App {
    @StateObject private var store = ShiftStore()
    @StateObject private var notifications = NotificationLogStore()
    #if LOCAL_DEVICE_TESTING
    @StateObject private var auth = AuthManager(restoreSession: false)
    #else
    @StateObject private var auth = AuthManager(restoreSession: NSClassFromString("XCTestCase") == nil)
    #endif
    @StateObject private var subscriptions = SubscriptionManager()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppearanceKey.isDarkMode) private var isDarkMode = false
    @AppStorage(AppLanguageKey.language) private var appLanguage = "system"

    /// `nil` tells SwiftUI to use its normal system-locale resolution; an explicit `Locale`
    /// overrides it for the whole view tree below `.environment(\.locale:)`, which is how
    /// `Text("literal")` picks which `.lproj` table to resolve against — independent of the
    /// device's own Settings > Language choice.
    private var resolvedLocale: Locale? {
        switch appLanguage {
        case "ja": return Locale(identifier: "ja")
        case "en": return Locale(identifier: "en")
        default: return nil
        }
    }

    /// Runs before anything can attach, sign out or delete: deletion must be able to silence the
    /// store's cloud sync, and wiping an account's device data must reach the notification history.
    private func wireAccountCleanup() {
        auth.dataStore = store
        store.onAccountDeleted = { [weak auth] in auth?.watchRemoteAccountDeletion() }
        store.onLocalDataWiped = { [weak notifications] in notifications?.reset() }
    }

    init() {
        #if !LOCAL_DEVICE_TESTING
        FirebaseApp.configure()
        // GoogleSignIn reads its OAuth client ID from Firebase's own config rather than
        // needing a second copy of it — this must run after configure() above.
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                #if LOCAL_DEVICE_TESTING
                ContentView()
                    .environmentObject(store)
                    .environmentObject(notifications)
                    .environmentObject(auth)
                    .task {
                        wireAccountCleanup()
                        store.attachUser(uid: LocalDeviceTestTransport.accountID)
                    }
                #else
                if let user = auth.user {
                    ContentView()
                        .environmentObject(store)
                        .environmentObject(notifications)
                        .environmentObject(auth)
                        .task(id: user.uid) {
                            wireAccountCleanup()
                            store.attachUser(uid: user.uid)
                            await auth.recoverInterruptedAccountDeletion()
                        }
                } else {
                    LoginView()
                        .environmentObject(auth)
                        .task {
                            wireAccountCleanup()
                            store.detachUser()
                        }
                }
                #endif
            }
            .sheet(isPresented: $auth.needsReauthToDelete) {
                DeleteAccountReauthView().environmentObject(auth).interactiveDismissDisabled(auth.isLoading)
            }
            .environmentObject(subscriptions)
            .task { await subscriptions.prepare() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.retryCloudSync()
                    Task { await subscriptions.refreshAccess() }
                }
            }
            .environment(\.locale, resolvedLocale ?? Locale.autoupdatingCurrent)
            .preferredColorScheme(isDarkMode ? .dark : .light)
            .onOpenURL { url in
                #if !LOCAL_DEVICE_TESTING
                GIDSignIn.sharedInstance.handle(url)
                #endif
            }
        }
    }
}
