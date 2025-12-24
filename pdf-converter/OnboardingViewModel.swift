//
//  OnboardingViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class OnboardingViewModel: ObservableObject {
    private var trackedPages = Set<Int>()
    private var didTrackCompletion = false

    func trackPageViewed(analytics: AnalyticsTracking, page: Int, feature: String?) {
        guard !trackedPages.contains(page) else { return }
        trackedPages.insert(page)

        var props: [String: Any] = ["page": page]
        if let feature = feature {
            props["feature"] = feature
        }

        analytics.capture("onboarding_page_viewed", properties: props)
    }

    func trackContinueTapped(analytics: AnalyticsTracking, fromPage: Int) {
        analytics.capture("onboarding_continue_tapped", properties: ["from_page": fromPage])
    }

    func trackCompleted(analytics: AnalyticsTracking) {
        guard !didTrackCompletion else { return }
        didTrackCompletion = true

        analytics.capture("onboarding_completed", properties: [:])
    }

    func trackLinkTapped(analytics: AnalyticsTracking, link: String) {
        analytics.capture("onboarding_\(link)_tapped", properties: [:])
    }
}
