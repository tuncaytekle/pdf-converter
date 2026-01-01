import SwiftUI
import Combine

/// Centralized subscription gating system that manages paywall presentation and subscription checks
@MainActor
final class SubscriptionGate: ObservableObject {
    private let subscriptionManager: SubscriptionManager

    /// Analytics source for the current paywall presentation
    @Published var paywallSource: String = "onboarding"

    /// Whether the paywall should be shown
    @Published var showPaywall = false

    /// Action to execute after successful paywall dismissal
    private var pendingAction: (() -> Void)?

    init(subscriptionManager: SubscriptionManager) {
        self.subscriptionManager = subscriptionManager
    }

    /// Gates an action behind subscription check. Returns true if action executed, false if paywall shown
    @discardableResult
    func requireSubscription(for source: String, action: @escaping () -> Void) -> Bool {
        if subscriptionManager.isSubscribed {
            action()
            return true
        } else {
            paywallSource = source
            pendingAction = action
            showPaywall = true
            return false
        }
    }

    /// Called when paywall is dismissed to execute any pending action
    func handlePaywallDismissal() {
        if subscriptionManager.isSubscribed, let action = pendingAction {
            pendingAction = nil
            // Small delay to allow sheet dismissal animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                action()
            }
        } else {
            pendingAction = nil
        }
    }

    /// Convenience property to check subscription status
    var isSubscribed: Bool { subscriptionManager.isSubscribed }
}

