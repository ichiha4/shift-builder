import XCTest
import StoreKit
import StoreKitTest
import SwiftUI
import UIKit
@testable import ShiftManagerApp

@MainActor
final class SubscriptionTests: XCTestCase {
    private func context() async throws -> (SKTestSession, SubscriptionManager) {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ShiftBuilderPlus", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.storefront = "JPN"
        session.locale = Locale(identifier: "ja_JP")
        session.timeRate = .realTime
        let manager = SubscriptionManager()
        await manager.prepare()
        _ = try XCTUnwrap(manager.monthlyProduct, "Local StoreKit catalog must load before testing purchase behavior")
        return (session, manager)
    }

    private func waitForAccess(_ expected: Bool, manager: SubscriptionManager) async throws {
        for _ in 0..<40 {
            await manager.refreshAccess()
            if manager.hasPlus == expected { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(manager.hasPlus, expected)
    }

    func testStartsFreeAndLoadsMonthlyProduct() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        XCTAssertFalse(manager.hasPlus)
        XCTAssertFalse(manager.isCheckingAccess)
        XCTAssertEqual(manager.monthlyProduct?.id, SubscriptionManager.monthlyProductID)
        XCTAssertEqual(manager.monthlyProduct?.price, 300)
    }

    func testVerifiedPurchaseSurvivesNewManagerAndRestore() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        await manager.purchase()
        XCTAssertTrue(manager.hasPlus)
        XCTAssertNil(manager.errorKey)
        let relaunched = SubscriptionManager()
        await relaunched.prepare()
        XCTAssertTrue(relaunched.hasPlus)
        await relaunched.restore()
        XCTAssertTrue(relaunched.hasPlus)
        XCTAssertEqual(relaunched.noticeKey, "Plusの購入を復元しました。")
    }

    func testRefundRevokesAccess() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        await manager.purchase()
        XCTAssertTrue(manager.hasPlus)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.refundTransaction(identifier: transaction.identifier)
        try await waitForAccess(false, manager: manager)
    }

    func testExpirationRevokesAccess() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        await manager.purchase()
        XCTAssertTrue(manager.hasPlus)
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        try session.expireSubscription(productIdentifier: SubscriptionManager.monthlyProductID)
        try await waitForAccess(false, manager: manager)
    }

    func testTurningOffRenewalKeepsAccessUntilExpiration() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        await manager.purchase()
        let transaction = try XCTUnwrap(session.allTransactions().last)
        try session.disableAutoRenewForTransaction(identifier: transaction.identifier)
        await manager.refreshAccess()
        XCTAssertTrue(manager.hasPlus)
        try session.expireSubscription(productIdentifier: SubscriptionManager.monthlyProductID)
        try await waitForAccess(false, manager: manager)
    }

    func testPendingApprovalDoesNotUnlockUntilApproved() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        session.askToBuyEnabled = true
        await manager.purchase()
        XCTAssertFalse(manager.hasPlus)
        XCTAssertEqual(manager.noticeKey, "購入は承認待ちです。承認されるとPlusが有効になります。")
        let pending = try XCTUnwrap(session.allTransactions().last)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        try await waitForAccess(true, manager: manager)
    }

    func testCancellationDoesNotUnlockOrReportPurchaseFailure() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        // iOS 27's simulated generic cancellation currently returns an unmapped ASD error.
        // Exercise the public typed result and thrown error without depending on private codes.
        await manager.purchase(using: { .userCancelled })
        XCTAssertFalse(manager.hasPlus)
        XCTAssertNil(manager.errorKey)
        XCTAssertNil(manager.noticeKey)
        await manager.purchase(using: { throw StoreKitError.userCancelled })
        XCTAssertFalse(manager.hasPlus)
        XCTAssertNil(manager.errorKey)
        XCTAssertNil(manager.noticeKey)
    }

    func testNetworkFailureDoesNotUnlock() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .purchase)
        await manager.purchase()
        XCTAssertFalse(manager.hasPlus)
        XCTAssertNotNil(manager.errorKey)
    }

    func testPlanningScreensRenderForVisualReview() async throws {
        let (session, manager) = try await context()
        defer { session.clearTransactions() }
        let store = ShiftStore()
        try await snapshot("Plus-paywall-ja", view: NavigationStack { PlusPaywallView() }
            .environmentObject(manager).environment(\.locale, Locale(identifier: "ja")))
        try await snapshot("Plus-hub-ja", view: NavigationStack { PlusView() }
            .environmentObject(manager).environment(\.locale, Locale(identifier: "ja")))
        try await snapshot("Plus-forecast-ja", view: NavigationStack { CashFlowForecastView() }
            .environmentObject(manager).environmentObject(store).environment(\.locale, Locale(identifier: "ja")))
        try await snapshot("Plus-paywall-en-dark", view: NavigationStack { PlusPaywallView() }
            .environmentObject(manager).environment(\.locale, Locale(identifier: "en")), dark: true)
    }

    private func snapshot<V: View>(_ name: String, view: V, dark: Bool = false) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        let controller = UIHostingController(rootView: view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        controller.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: controller.view.bounds)
        let screenshot = renderer.image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
