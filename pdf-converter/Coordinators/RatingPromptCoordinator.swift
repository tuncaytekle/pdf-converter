//
//  RatingPromptCoordinator.swift
//  pdf-converter
//
//  Created by Claude Code on 1/3/26.
//

import Foundation
import Observation

/// Coordinates rating prompt presentation and handles dialog state
@Observable
@MainActor
final class RatingPromptCoordinator {

    // MARK: - State

    /// Whether to show the enjoyment dialog
    var showEnjoymentDialog = false

    /// Whether to show the contact support website
    var showContactWebsite = false

    // MARK: - Dependencies

    let manager: RatingPromptManager

    // MARK: - Initialization

    init(manager: RatingPromptManager) {
        self.manager = manager
    }

    // MARK: - Public API

    /// Presents the enjoyment dialog flow
    /// Shows "Are you enjoying the app?" → Yes/No → Rating/Contact
    func presentEnjoymentFlow() {
        showEnjoymentDialog = true
    }

    /// Presents the system rating prompt directly
    func presentRatingPrompt() {
        RatingPromptHelper.requestAppReview()
        manager.markUserRated()
    }

    /// Presents the contact support website
    func presentContactWebsite() {
        showContactWebsite = true
    }

    // MARK: - Dialog Handlers

    /// Handle user tapping "Yes" in enjoyment dialog
    func handleEnjoymentYes() {
        // Show rating prompt
        RatingPromptHelper.requestAppReview()
        manager.markUserRated()
    }

    /// Handle user tapping "No" in enjoyment dialog
    func handleEnjoymentNo() {
        // Show contact support website
        showContactWebsite = true
    }
}
