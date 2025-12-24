//
//  PaywallViewModel.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/24/25.
//


import Foundation
import Combine

@MainActor
final class PaywallViewModel: ObservableObject {
    enum PurchaseOutcome {
        case none
        case success
        case userCancelled
        case pending
        case failed(category: String)
    }

    @Published var purchaseOutcome: PurchaseOutcome = .none

    let paywallId = "main_paywall"
    let productId: String
    let source: String

    private var didTrackView = false
    private var paywallStart: Date?
    private(set) var didPurchaseSucceed = false

    init(productId: String, source: String) {
        self.productId = productId
        self.source = source
    }

    func trackPaywallViewed(analytics: AnalyticsTracking, eligibleForIntroOffer: Bool?) {
        guard !didTrackView else { return }
        didTrackView = true
        paywallStart = Date()

        var props: [String: Any] = [
            "paywall_id": paywallId,
            "source": source,
            "product_id": productId
        ]
        if let eligibleForIntroOffer { props["eligible_for_intro_offer"] = eligibleForIntroOffer }

        analytics.capture("paywall_viewed", properties: props)
        analytics.screen("Paywall", properties: ["paywall_id": paywallId, "source": source])
    }

    func trackPurchaseTapped(analytics: AnalyticsTracking) {
        analytics.capture("purchase_tapped", properties: [
            "paywall_id": paywallId,
            "source": source,
            "product_id": productId
        ])
    }

    func trackPurchaseResult(analytics: AnalyticsTracking, outcome: PurchaseOutcome, verified: Bool) {
        let resultString: String
        var props: [String: Any] = [
            "product_id": productId,
            "verified": verified
        ]

        switch outcome {
        case .success:
            resultString = "success"
            didPurchaseSucceed = true
        case .userCancelled:
            resultString = "user_cancelled"
        case .pending:
            resultString = "pending"
        case .failed(let category):
            resultString = "failed"
            props["failure_category"] = category
        case .none:
            return
        }

        props["result"] = resultString
        analytics.capture("purchase_result", properties: props)
    }

    func trackPaywallDismissedIfNeeded(analytics: AnalyticsTracking, dismissMethod: String) {
        guard didTrackView else { return }            // only if they actually saw it
        guard !didPurchaseSucceed else { return }     // do not mark dismissal on success

        let elapsedMs: Int? = paywallStart.map { Int(Date().timeIntervalSince($0) * 1000.0) }

        var props: [String: Any] = [
            "paywall_id": paywallId,
            "dismiss_method": dismissMethod
        ]
        if let elapsedMs { props["time_on_paywall_ms"] = elapsedMs }

        analytics.capture("paywall_dismissed", properties: props)
    }
}
