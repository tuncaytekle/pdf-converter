//
//  AccountViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class AccountViewModel: ObservableObject {
    func trackRestorePurchasesTapped(analytics: AnalyticsTracking, from: String) {
        analytics.capture("restore_purchases_tapped", properties: ["from": from])
    }

    func trackRestorePurchasesResult(analytics: AnalyticsTracking, result: String, failureCategory: String?) {
        var props: [String: Any] = ["result": result]
        if let failureCategory = failureCategory {
            props["failure_category"] = failureCategory
        }
        analytics.capture("restore_purchases_result", properties: props)
    }

    func trackManageSubscriptionTapped(analytics: AnalyticsTracking) {
        analytics.capture("manage_subscription_tapped", properties: [:])
    }

    func trackReviewAppTapped(analytics: AnalyticsTracking, subscribed: Bool) {
        analytics.capture("review_app_tapped", properties: ["subscribed": subscribed])
    }
}
