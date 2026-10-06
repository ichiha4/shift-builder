import SwiftUI
import StoreKit
import UIKit

/// Access belongs to the Apple Account. Firebase and UserDefaults never grant Plus access.
@MainActor
final class SubscriptionManager: ObservableObject {
    static let monthlyProductID = "com.example.shiftbuilder.plus.monthly"
    static let productIDs: Set<String> = [monthlyProductID]
    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    @Published private(set) var hasPlus = false
    @Published private(set) var isCheckingAccess = true
    @Published private(set) var monthlyProduct: Product?
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isBusy = false
    @Published private(set) var errorKey: String?
    @Published private(set) var noticeKey: String?

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var refreshGeneration = UUID()

    init() {
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { return }
                switch result {
                case .verified(let transaction) where Self.productIDs.contains(transaction.productID):
                    await self.refreshAccess()
                    await transaction.finish()
                case .unverified(let transaction, _) where Self.productIDs.contains(transaction.productID):
                    self.errorKey = "購入情報を確認できませんでした。時間をおいて再試行してください。"
                default: break
                }
            }
        }
    }

    deinit {
        updatesTask?.cancel()
        expiryTask?.cancel()
    }

    func prepare() async {
        // Check cached verified entitlements even if loading products fails offline.
        await refreshAccess()
        if monthlyProduct == nil { await loadProducts() }
        await refreshAccess()
    }

    func loadProducts() async {
        guard !isLoadingProducts else { return }
        isLoadingProducts = true
        errorKey = nil
        defer { isLoadingProducts = false }
        do {
            let products = try await Product.products(for: Array(Self.productIDs))
            monthlyProduct = products.first {
                $0.id == Self.monthlyProductID && $0.type == .autoRenewable &&
                $0.subscription?.subscriptionPeriod.unit == .month &&
                $0.subscription?.subscriptionPeriod.value == 1
            }
            if monthlyProduct == nil {
                errorKey = "現在購入できません。商品情報を再読み込みするか、時間をおいてお試しください。"
            }
        } catch {
            errorKey = "商品情報を読み込めませんでした。通信環境を確認してください。"
        }
    }

    func refreshAccess() async {
        let generation = UUID()
        refreshGeneration = generation
        let now = Date()
        var accessUntil: Date?
        for await result in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.productType == .autoRenewable,
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            #if LOCAL_DEVICE_TESTING
            guard transaction.environment == .xcode else { continue }
            #endif
            if let expiry = eligibleExpiry(transaction, now: now) {
                accessUntil = max(accessUntil ?? expiry, expiry)
            } else if let status = await transaction.subscriptionStatus,
                      status.state == .inGracePeriod,
                      case .verified(let graceTransaction) = status.transaction,
                      case .verified(let renewal) = status.renewalInfo,
                      graceTransaction.originalID == transaction.originalID,
                      Self.productIDs.contains(graceTransaction.productID),
                      graceTransaction.revocationDate == nil, !graceTransaction.isUpgraded,
                      let graceExpiry = renewal.gracePeriodExpirationDate, graceExpiry > now {
                // Works without loading the product catalog. Both signed payloads must verify.
                accessUntil = max(accessUntil ?? graceExpiry, graceExpiry)
            }
        }
        guard generation == refreshGeneration else { return }
        setAccess(until: accessUntil)
        isCheckingAccess = false
    }

    func purchase() async {
        guard let product = monthlyProduct else { return }
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive }
        await purchase(using: {
            if let scene { return try await product.purchase(confirmIn: scene) }
            // Let StoreKit resolve presentation when no foreground scene is available,
            // including headless StoreKitTest sessions with confirmation dialogs disabled.
            return try await product.purchase()
        })
    }

    /// The operation boundary lets tests exercise Apple's typed cancellation result. Access
    /// still requires a verified, eligible transaction; callers cannot set an entitlement.
    func purchase(using operation: () async throws -> Product.PurchaseResult) async {
        guard !isBusy else { return }
        isBusy = true
        errorKey = nil
        noticeKey = nil
        defer { isBusy = false }
        do {
            switch try await operation() {
            case .success(let result):
                guard case .verified(let transaction) = result,
                      let expiry = eligibleExpiry(transaction, now: Date()) else {
                    errorKey = "購入情報を確認できませんでした。時間をおいて再試行してください。"
                    return
                }
                setAccess(until: expiry)
                await transaction.finish()
                await refreshAccess()
            case .pending:
                noticeKey = "購入は承認待ちです。承認されるとPlusが有効になります。"
            case .userCancelled:
                break
            @unknown default:
                errorKey = "購入を完了できませんでした。時間をおいて再試行してください。"
            }
        } catch StoreKitError.userCancelled {
            // StoreKit may throw cancellation instead of returning .userCancelled.
        } catch {
            errorKey = "購入を完了できませんでした。時間をおいて再試行してください。"
        }
    }

    func restore() async {
        guard !isBusy else { return }
        isBusy = true
        errorKey = nil
        noticeKey = nil
        defer { isBusy = false }
        do {
            try await AppStore.sync()
            if monthlyProduct == nil { await loadProducts() }
            await refreshAccess()
            noticeKey = hasPlus ? "Plusの購入を復元しました。" : "有効なPlusの購入が見つかりませんでした。"
        } catch {
            errorKey = "購入を復元できませんでした。Apple Accountと通信環境を確認してください。"
        }
    }

    private func eligibleExpiry(_ transaction: StoreKit.Transaction, now: Date) -> Date? {
        #if LOCAL_DEVICE_TESTING
        guard transaction.environment == .xcode else { return nil }
        #endif
        guard Self.productIDs.contains(transaction.productID), transaction.productType == .autoRenewable,
              transaction.revocationDate == nil, !transaction.isUpgraded,
              let expiry = transaction.expirationDate, expiry > now else { return nil }
        return expiry
    }

    private func setAccess(until expiry: Date?) {
        expiryTask?.cancel()
        hasPlus = expiry.map { $0 > Date() } ?? false
        guard let expiry, hasPlus else { return }
        expiryTask = Task { [weak self] in
            let interval = max(0, expiry.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self else { return }
            await self.refreshAccess()
        }
    }
}
