//
//  RatingPromptManager.swift
//  pdf-converter
//
//  Created by Claude Code on 1/3/26.
//

import Foundation
import Observation

/// Manages rating prompt state and business logic for when to show rating requests
@Observable
@MainActor
final class RatingPromptManager {

    // MARK: - UserDefaults Keys

    private let hasRatedKey = "hasRatedApp"
    private let firstAppOpenDateKey = "firstAppOpenDate"
    private let appOpenCountKey = "appOpenCount"
    private let firstConversionCompletedKey = "firstConversionCompleted"
    private let lastRatingPromptDateKey = "lastRatingPromptDate"
    private let hasShownOnboardingStep3PromptKey = "hasShownOnboardingStep3Prompt"
    private let hasShownSecondOpenPromptKey = "hasShownSecondOpenPrompt"

    // MARK: - Private Properties

    private let defaults = UserDefaults.standard

    // MARK: - Public Properties

    /// Whether the user has rated the app (master override flag)
    var hasRated: Bool {
        defaults.bool(forKey: hasRatedKey)
    }

    /// Current app open count
    var appOpenCount: Int {
        defaults.integer(forKey: appOpenCountKey)
    }

    // MARK: - App Lifecycle

    /// Records an app open and increments the counter
    /// Call this on app launch
    func recordAppOpen() {
        // Set first open date if not set
        if defaults.object(forKey: firstAppOpenDateKey) == nil {
            defaults.set(Date(), forKey: firstAppOpenDateKey)
        }

        // Increment open count
        let currentCount = defaults.integer(forKey: appOpenCountKey)
        defaults.set(currentCount + 1, forKey: appOpenCountKey)
    }

    // MARK: - Prompt Decision Logic

    /// Check if should show rating prompt after subscription purchase
    func shouldShowAfterSubscriptionPurchase() -> Bool {
        // Master override: never show if already rated
        guard !hasRated else { return false }

        // Always show after subscription purchase
        return true
    }

    /// Check if should show rating prompt after onboarding step 3
    func shouldShowAfterOnboardingStep3() -> Bool {
        // Master override
        guard !hasRated else { return false }

        // Only show once
        guard !defaults.bool(forKey: hasShownOnboardingStep3PromptKey) else { return false }

        return true
    }

    /// Check if should show rating prompt on first conversion
    func shouldShowOnFirstConversion() -> Bool {
        // Master override
        guard !hasRated else { return false }

        // Only show if first conversion hasn't been completed yet
        guard !defaults.bool(forKey: firstConversionCompletedKey) else { return false }

        return true
    }

    /// Check if should show enjoyment prompt on second app open (after save/share)
    func shouldShowEnjoymentPromptOnSecondOpen() -> Bool {
        // Master override
        guard !hasRated else { return false }

        // Only on second open
        guard appOpenCount == 2 else { return false }

        // Only show once
        guard !defaults.bool(forKey: hasShownSecondOpenPromptKey) else { return false }

        return true
    }

    /// Check if should show recurring enjoyment prompt
    /// Shows on every 3rd open (3, 6, 9...) AND 1 week after first open (whichever is later)
    func shouldShowRecurringEnjoymentPrompt() -> Bool {
        // Master override
        guard !hasRated else { return false }

        // Must be a 3rd open (3, 6, 9, 12...)
        let isThirdOpen = appOpenCount % 3 == 0 && appOpenCount >= 3
        guard isThirdOpen else { return false }

        // Must be at least 1 week since first open
        guard let firstOpenDate = defaults.object(forKey: firstAppOpenDateKey) as? Date else {
            return false
        }
        let weekHasPassed = Date().timeIntervalSince(firstOpenDate) >= 7 * 24 * 60 * 60
        guard weekHasPassed else { return false }

        // Don't show if recently shown (within last 7 days)
        if let lastPromptDate = defaults.object(forKey: lastRatingPromptDateKey) as? Date {
            let daysSinceLastPrompt = Date().timeIntervalSince(lastPromptDate) / (24 * 60 * 60)
            guard daysSinceLastPrompt >= 7 else { return false }
        }

        return true
    }

    // MARK: - State Mutations

    /// Mark that the first conversion was completed
    func markFirstConversionCompleted() {
        defaults.set(true, forKey: firstConversionCompletedKey)
    }

    /// Mark that the user has rated the app
    /// This is the master override - once set, no prompts will show again
    func markUserRated() {
        defaults.set(true, forKey: hasRatedKey)
        recordRatingPromptShown()
    }

    /// Record that a rating prompt was shown (updates last shown date)
    func recordRatingPromptShown() {
        defaults.set(Date(), forKey: lastRatingPromptDateKey)
    }

    /// Mark that onboarding step 3 prompt was shown
    func markOnboardingStep3PromptShown() {
        defaults.set(true, forKey: hasShownOnboardingStep3PromptKey)
        recordRatingPromptShown()
    }

    /// Mark that second open prompt was shown
    func markSecondOpenPromptShown() {
        defaults.set(true, forKey: hasShownSecondOpenPromptKey)
        recordRatingPromptShown()
    }

    // MARK: - Debug/Testing

    #if DEBUG
    /// Reset all rating prompt state (for testing only)
    func resetAllState() {
        defaults.removeObject(forKey: hasRatedKey)
        defaults.removeObject(forKey: firstAppOpenDateKey)
        defaults.removeObject(forKey: appOpenCountKey)
        defaults.removeObject(forKey: firstConversionCompletedKey)
        defaults.removeObject(forKey: lastRatingPromptDateKey)
        defaults.removeObject(forKey: hasShownOnboardingStep3PromptKey)
        defaults.removeObject(forKey: hasShownSecondOpenPromptKey)
    }
    #endif
}
