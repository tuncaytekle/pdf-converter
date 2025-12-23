//
//  AccountView.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/23/25.
//

import SwiftUI
import Combine
import VisionKit
import PhotosUI
import PDFKit
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication
import PencilKit
import StoreKit
import OSLog

/// Placeholder account screen showcasing subscription upsell copy.
struct AccountView: View {
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @Binding var showPaywall: Bool
    @State private var showManageSubscriptionsSheet = false

    private let featureList: [String] = [
        "Unlimited scans & conversions",
        "Create PDFs from photo album",
        "Sign documents",
        "Easy & instant share",
        "Organize all your files",
        "Keep your original designs"
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 24) {
                        Text(subscriptionManager.isSubscribed ? "Pro Account" : "Unlock Pro")
                            .font(.system(size: 34, weight: .bold))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image("account-community")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                        VStack(alignment: .leading, spacing: 8) {
                            Text(subscriptionManager.isSubscribed ? "Help us grow" : "Support our work")
                                .font(.title3.weight(.semibold))
                            Text(subscriptionManager.isSubscribed ? "We are a small community" : "Help us grow by subscribing")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        if subscriptionManager.isSubscribed {
                            Button {
                                requestAppReview()
                            } label: {
                                Text("Leave us a review")
                                    .font(.body.weight(.medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                            }
                            .buttonStyle(.borderedProminent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            Button {
                                showPaywall = true
                            } label: {
                                HStack {
                                    Text("View Plans")
                                        .font(.body.weight(.medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.body.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .padding(.horizontal, 20)
                            }
                            .buttonStyle(.borderedProminent)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(featureList, id: \.self) { feature in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(.blue)
                                Text(feature)
                                    .font(.body)
                                    .foregroundStyle(.primary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if subscriptionManager.isSubscribed {
                        Button {
                            presentManageSubscriptions()
                        } label: {
                            Text("Manage Subscription")
                                .font(.body)
                                .foregroundStyle(.blue)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProButton(subscriptionManager: subscriptionManager)
                }
                .hideSharedBackground
            }
        }
        .manageSubscriptionsSheetIfAvailable($showManageSubscriptionsSheet)
    }

    @MainActor
    private func presentManageSubscriptions() {
        if #available(iOS 17.0, *) {
            showManageSubscriptionsSheet = true
        } else {
            subscriptionManager.openManageSubscriptionsFallback()
        }
    }

    private func requestAppReview() {
        if #available(iOS 18.0, *) {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                AppStore.requestReview(in: windowScene)
            }
        } else {
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                SKStoreReviewController.requestReview(in: windowScene)
            }
        }
    }
}
