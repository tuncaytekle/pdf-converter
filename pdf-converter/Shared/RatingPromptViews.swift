//
//  RatingPromptViews.swift
//  pdf-converter
//
//  Created by Claude Code on 1/3/26.
//

import SwiftUI
import StoreKit

// MARK: - Enjoyment Dialog

/// Custom dialog asking if user is enjoying the app
struct EnjoymentDialog: View {
    let onYes: () -> Void
    let onNo: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    dismiss()
                }

            // Dialog card
            VStack(spacing: 24) {
                // Title
                Text(NSLocalizedString("rating.enjoyment.title", comment: "Are you enjoying the app?"))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)

                // Buttons
                HStack(spacing: 16) {
                    // No button
                    Button {
                        dismiss()
                        onNo()
                    } label: {
                        Text(NSLocalizedString("rating.enjoyment.no", comment: "No"))
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)

                    // Yes button
                    Button {
                        dismiss()
                        onYes()
                    } label: {
                        Text(NSLocalizedString("rating.enjoyment.yes", comment: "Yes"))
                            .font(.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.gray.opacity(0.2), lineWidth: 1)
            )
            .padding(.horizontal, 40)
        }
    }
}

// MARK: - Rating Prompt Helper

/// Helper to trigger the system rating prompt
struct RatingPromptHelper {
    /// Request app review using the system dialog
    @MainActor
    static func requestAppReview() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else {
            return
        }

        if #available(iOS 18.0, *) {
            AppStore.requestReview(in: windowScene)
        } else {
            SKStoreReviewController.requestReview(in: windowScene)
        }
    }
}

// MARK: - Contact Support Alert Model

/// Alert model for contact support (reuses SettingsAlert pattern)
struct ContactSupportAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func make() -> ContactSupportAlert {
        ContactSupportAlert(
            title: NSLocalizedString("settings.support.contactTitle", comment: "Contact support title"),
            message: NSLocalizedString("settings.support.contactMessage", comment: "Contact support message")
        )
    }
}

// MARK: - Preview

#Preview {
    EnjoymentDialog(
        onYes: { print("Yes tapped") },
        onNo: { print("No tapped") }
    )
}
