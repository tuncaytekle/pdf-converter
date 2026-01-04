import SwiftUI
import Combine
import StoreKit
import OSLog
import UIKit

@MainActor
final class SubscriptionManager: ObservableObject {
    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case pending
        case purchased
        case failed(String)
    }

    @Published private(set) var product: Product?
    @Published private(set) var isSubscribed = false
    @Published var purchaseState: PurchaseState = .idle

    private let productID: String
    private let hasEverPurchasedKey = "hasEverPurchasedSubscription"
    private let cachedSubscriptionStateKey = "cachedSubscriptionState"
    private let cachedExpirationDateKey = "cachedExpirationDate"
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.roguewaveapps.pdfconverter",
        category: "Subscription"
    )
    private var loadProductTask: Task<Void, Never>?
    private var monitorEntitlementsTask: Task<Void, Never>?
    private var transactionUpdatesTask: Task<Void, Never>?
    private var validationTimer: Timer?

    init() {
        productID = Bundle.main.subscriptionProductID

        // Load cached subscription state for immediate UI rendering
        isSubscribed = loadCachedSubscriptionState()

        loadProductTask = Task { [weak self] in
            await self?.loadProduct()
        }
        monitorEntitlementsTask = Task { [weak self] in
            await self?.monitorEntitlements()
        }
        transactionUpdatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }

        // Start periodic expiration validation
        startPeriodicValidation()
    }

#if DEBUG
    /// Debug-only initializer for SwiftUI previews
    init(mockSubscribed: Bool) {
        productID = Bundle.main.subscriptionProductID
        isSubscribed = mockSubscribed
        // Don't start monitoring tasks for mock instances
    }
#endif

    deinit {
        loadProductTask?.cancel()
        monitorEntitlementsTask?.cancel()
        transactionUpdatesTask?.cancel()
        validationTimer?.invalidate()
    }

    private func loadCachedSubscriptionState() -> Bool {
        guard let expirationDate = UserDefaults.standard.object(forKey: cachedExpirationDateKey) as? Date else {
            return false
        }

        // Check if cached expiration is still valid
        let isStillActive = expirationDate > Date()

        debugLog("Loaded cached subscription state: \(isStillActive ? "active" : "expired"), expires: \(expirationDate)")
        return isStillActive
    }

    private func cacheSubscriptionState(isActive: Bool, expirationDate: Date?) {
        if isActive, let expirationDate = expirationDate {
            UserDefaults.standard.set(expirationDate, forKey: cachedExpirationDateKey)
            debugLog("Cached subscription state: active until \(expirationDate)")
        } else {
            UserDefaults.standard.removeObject(forKey: cachedExpirationDateKey)
            debugLog("Cleared subscription cache (inactive or no expiration)")
        }
    }

    var shouldShowPaywall: Bool {
        return !UserDefaults.standard.bool(forKey: hasEverPurchasedKey) && !isSubscribed
    }

    private func markPurchaseCompleted() {
        UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
    }

    private func startPeriodicValidation() {
        // Validate expiration every 60 seconds
        validationTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.validateCurrentExpiration()
            }
        }
    }

    private func validateCurrentExpiration() async {
        guard isSubscribed else { return }

        // Check if we have a cached expiration date
        guard let cachedExpiration = UserDefaults.standard.object(forKey: cachedExpirationDateKey) as? Date else {
            debugLog("No cached expiration date - skipping validation")
            return
        }

        // Check if subscription has expired based on cached date
        if cachedExpiration <= Date() {
            debugLog("Subscription expired based on cached date: \(cachedExpiration)")
            isSubscribed = false
            UserDefaults.standard.removeObject(forKey: cachedExpirationDateKey)

            // Trigger entitlement refresh to get updated state from StoreKit
            await refreshEntitlements()
        }
    }

    private func refreshEntitlements() async {
        debugLog("Refreshing entitlements from StoreKit")

        var foundActiveSubscription = false
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == productID {
                let expirationDate = transaction.expirationDate ?? .distantFuture
                let isActive = transaction.revocationDate == nil && expirationDate > Date()

                if isActive {
                    foundActiveSubscription = true
                    isSubscribed = true
                    cacheSubscriptionState(isActive: true, expirationDate: expirationDate)
                    debugLog("Found active subscription during refresh, expires: \(expirationDate)")
                } else {
                    debugLog("Found expired or revoked subscription during refresh")
                }
                break
            }
        }

        // If no active subscription found, mark as unsubscribed
        if !foundActiveSubscription && isSubscribed {
            debugLog("No active subscription found during refresh - setting isSubscribed to false")
            isSubscribed = false
            cacheSubscriptionState(isActive: false, expirationDate: nil)
        }
    }

    /// Call this when app returns to foreground to refresh subscription state
    func refreshOnForeground() {
        Task { @MainActor in
            await refreshEntitlements()
        }
    }

    func purchase() {
        guard purchaseState != .purchasing else { return }
        Task { await purchaseProduct() }
    }

    func restorePurchases() async {
        debugLog("Starting restore purchases…")
        purchaseState = .purchasing

        do {
            try await AppStore.sync()
            debugLog("App Store sync completed")

            var foundActiveSubscription = false
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   transaction.productID == productID {
                    let isActive = transaction.revocationDate == nil &&
                        (transaction.expirationDate ?? .distantFuture) > Date()

                    if isActive {
                        foundActiveSubscription = true
                        isSubscribed = true
                        markPurchaseCompleted()
                        cacheSubscriptionState(isActive: true, expirationDate: transaction.expirationDate)
                        debugLog("Found active subscription during restore")
                        await transaction.finish()
                        break
                    }
                }
            }

            if foundActiveSubscription {
                purchaseState = .purchased
                debugLog("Restore successful - subscription active")
            } else {
                isSubscribed = false
                cacheSubscriptionState(isActive: false, expirationDate: nil)
                purchaseState = .failed("No active subscription found.\n\nIf you previously purchased, ensure you're signed in with the same Apple ID.")
                debugLog("No active subscription found during restore - setting isSubscribed to false")
            }
        } catch {
            logError("Restore failed: \(error.localizedDescription)")
            purchaseState = .failed("Restore failed.\n\nError: \(error.localizedDescription)")
        }
    }

    @MainActor
    func openManageSubscriptionsFallback() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    private func loadProduct() async {
        do {
            debugLog("Loading product with ID: \(productID)")
            let products = try await Product.products(for: [productID])

            if let loadedProduct = products.first {
                product = loadedProduct
                debugLog("Product loaded successfully: \(loadedProduct.displayName) - \(loadedProduct.displayPrice)")
            } else {
                logError("Product array empty – verify App Store Connect setup for \(productID)")
                purchaseState = .failed("Product not found in App Store.\n\nProduct ID: \(productID)\n\nThis usually means:\n1. Product not set up in App Store Connect\n2. Product not approved yet\n3. Product not added to this app version\n4. Wrong product ID")
            }
        } catch {
            logError("Failed to load product: \(error.localizedDescription)")
#if DEBUG
            debugLog("Error details: \(error)")
#endif

            let errorMessage = """
            Failed to load subscription.

            Product ID: \(productID)
            Error: \(error.localizedDescription)

            Debug info: \(error)

            Possible causes:
            • Network connection issue
            • App Store services unavailable
            • Invalid product configuration
            """

            purchaseState = .failed(errorMessage)
        }
    }

    private func monitorEntitlements() async {
        var foundActiveSubscription = false
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = entitlement,
               transaction.productID == productID {
                let expirationDate = transaction.expirationDate ?? .distantFuture
                let isActive = transaction.revocationDate == nil && expirationDate > Date()

                if isActive {
                    foundActiveSubscription = true
                }

                await updateSubscriptionState(from: entitlement)
            }
        }

        // If we've finished iterating and found no active subscription, mark as unsubscribed
        if !foundActiveSubscription && isSubscribed {
            debugLog("No active subscription found during monitoring - setting isSubscribed to false")
            isSubscribed = false
            cacheSubscriptionState(isActive: false, expirationDate: nil)
        }
    }

    private func listenForTransactions() async {
        for await result in StoreKit.Transaction.updates {
            await handleTransactionUpdate(result)
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == productID else { return }

            let expirationDate = transaction.expirationDate ?? .distantFuture
            let isActive = transaction.revocationDate == nil && expirationDate > Date()
            isSubscribed = isActive

            // Cache the updated state
            cacheSubscriptionState(isActive: isActive, expirationDate: expirationDate)

            if isActive {
                purchaseState = .purchased
                markPurchaseCompleted()
            }

            await transaction.finish()

        case .unverified(_, let error):
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
        }
    }

    private func updateSubscriptionState(from result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == productID else { return }

            let expirationDate = transaction.expirationDate ?? .distantFuture
            let isActive = transaction.revocationDate == nil && expirationDate > Date()

            isSubscribed = isActive

            // Cache the state for next launch
            cacheSubscriptionState(isActive: isActive, expirationDate: expirationDate)

            debugLog("Updated subscription state: \(isActive ? "active" : "inactive"), expires: \(expirationDate)")

        case .unverified(_, let error):
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
        }
    }

    private func purchaseProduct() async {
        guard let product else {
            logError("Cannot initiate purchase - product metadata missing.")
            let errorMessage = """
            Subscription not available.

            Product ID: \(productID)

            The product failed to load. Check the error message above for details.

            In TestFlight, ensure:
            • Product is approved in App Store Connect
            • Product is added to this app version
            • You're signed in with a sandbox account
            """
            purchaseState = .failed(errorMessage)
            return
        }

        debugLog("Starting purchase for: \(product.displayName)")
        purchaseState = .purchasing

        do {
            let anonIdString = AnonymousIdProvider.getOrCreate()

            guard let appAccountToken = UUID(uuidString: anonIdString) else {
                // Extremely unlikely if you always store UUID strings, but handle defensively
                throw NSError(domain: "AppAccountToken", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UUID in Keychain"])
            }
            let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])
            debugLog("Purchase result received from StoreKit")

            switch result {
            case .success(let verification):
                debugLog("Purchase successful")
                await handlePurchaseResult(verification)
            case .pending:
                debugLog("Purchase pending (waiting for approval)")
                purchaseState = .pending
            case .userCancelled:
                debugLog("Purchase cancelled by user")
                purchaseState = .idle
            @unknown default:
                logger.warning("Unknown purchase result emitted by StoreKit.")
                purchaseState = .failed("Unknown purchase result.\n\nPlease try again or contact support.")
            }
        } catch {
            logError("Purchase failed: \(error.localizedDescription)")
#if DEBUG
            debugLog("Error details: \(error)")
#endif

            let errorMessage = """
            Purchase failed.

            Error: \(error.localizedDescription)

            Debug info: \(error)
            """

            purchaseState = .failed(errorMessage)
        }
    }

    private func handlePurchaseResult(_ verification: VerificationResult<StoreKit.Transaction>) async {
        switch verification {
        case .verified(let transaction):
            let expirationDate = transaction.expirationDate ?? .distantFuture
            let isActive = transaction.revocationDate == nil && expirationDate > Date()

            isSubscribed = isActive

            if isActive {
                purchaseState = .purchased
                markPurchaseCompleted()
                cacheSubscriptionState(isActive: true, expirationDate: expirationDate)
                debugLog("Purchase completed - subscription active until \(expirationDate)")
            } else {
                purchaseState = .failed("Subscription is not active")
                debugLog("Purchase verified but subscription is not active (expired or revoked)")
            }

            await transaction.finish()
        case .unverified(_, let error):
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
        }
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

#if DEBUG
    private func debugLog(_ message: String) {
        logger.debug("\(message, privacy: .public)")
    }
#else
    private func debugLog(_ message: String) { }
#endif
}

extension View {
    @ViewBuilder
    func manageSubscriptionsSheetIfAvailable(_ isPresented: Binding<Bool>) -> some View {
        if #available(iOS 17.0, *) {
            self.manageSubscriptionsSheet(isPresented: isPresented)
        } else {
            self
        }
    }
}

struct ProButton: View {
    @ObservedObject var subscriptionManager: SubscriptionManager
    @Environment(\.analytics) private var analytics
    let source: String

    var body: some View {
        Button {
            guard !subscriptionManager.isSubscribed else { return }

            // Track Pro button tap
            analytics.capture("pro_button_tapped", properties: [
                "source": source,
                "product_id": subscriptionManager.product?.id ?? "unknown"
            ])

            subscriptionManager.purchase()
        } label: {
            HStack {
                Image(systemName: subscriptionManager.isSubscribed ? "checkmark.seal.fill" : "crown.fill")
                    .imageScale(.small)
                Text(subscriptionManager.isSubscribed ? NSLocalizedString("proButton.active", comment: "Active Pro label") : NSLocalizedString("proButton.upsell", comment: "Upgrade to Pro label"))
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(subscriptionManager.isSubscribed ? Color(.quaternarySystemFill) : Color.accentColor.opacity(0.15))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(subscriptionManager.isSubscribed)
        .opacity(subscriptionManager.isSubscribed ? 0.5 : 1)
    }
}
