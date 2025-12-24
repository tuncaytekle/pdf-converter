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

    var body: some View {
        NavigationView {
            GeometryReader { proxy in
                let metrics = PaywallMetrics(size: proxy.size)

                ScrollView {
                    VStack(spacing: metrics.verticalSpacingExtraLarge) {
                        VStack(spacing: metrics.verticalSpacingMedium) {
                            let key = subscriptionManager.isSubscribed ? "account.title.subscribed": "account.title.unsubscribed";
                            markdownText(key: key,
                                         comment: "account title", boldFont: metrics.accountTitleFont, lightFont: metrics.accountLightTitleFont, color: .primary)
                            .frame(maxWidth: .infinity, alignment: .center)

                            ZStack(alignment: .bottom) {
                                Image("account-community")
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: metrics.accountImageWidth, height: metrics.accountImageHeight)
                                    .clipped()

                                if subscriptionManager.isSubscribed {
                                    HStack(alignment: .bottom, spacing: 0) {
                                        VStack(alignment: .leading, spacing: 0) {
                                            Text(NSLocalizedString("account.help.title", comment: "Help us grow title"))
                                                .font(metrics.accountSectionTitleFont)
                                                .lineLimit(1)
                                            Text(NSLocalizedString("account.help.subtitle", comment: "We are a small community subtitle"))
                                                .font(metrics.accountSubtitleFont)
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()

                                        Button {
                                            requestAppReview()
                                        } label: {
                                            Text(NSLocalizedString("account.review.button", comment: "Leave us a review button"))
                                                .font(metrics.accountSubtitleFont)
                                                .lineLimit(1)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .clipShape(RoundedRectangle(cornerRadius: metrics.accountButtonCornerRadius, style: .continuous))
                                        .padding(.vertical, metrics.accountReviewButtonVerticalPadding)
                                        .padding(.horizontal, metrics.accountReviewButtonHorizontalPadding)
                                    }
                                    .padding(.horizontal, metrics.horizontalSmallPadding)
                                    .frame(maxWidth: .infinity, minHeight: metrics.accountGradientHeight, maxHeight: metrics.accountGradientHeight, alignment: .bottom)
                                    .background(
                                        LinearGradient(
                                            stops: [
                                                Gradient.Stop(color: .white.opacity(0), location: 0.00),
                                                Gradient.Stop(color: .white, location: 0.58),
                                                Gradient.Stop(color: .white, location: 1.00),
                                            ],
                                            startPoint: UnitPoint(x: 0.5, y: 0),
                                            endPoint: UnitPoint(x: 0.5, y: 1)
                                        )
                                    )
                                } else {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(NSLocalizedString("account.support.title", comment: "Support our work title"))
                                            .font(metrics.accountSectionTitleFont)
                                        Text(NSLocalizedString("account.support.subtitle", comment: "Help us grow by subscribing subtitle"))
                                            .font(metrics.accountSubtitleFont)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, metrics.horizontalPadding)
                                    .frame(maxWidth: .infinity, minHeight: metrics.accountGradientHeight, maxHeight: metrics.accountGradientHeight, alignment: .bottomLeading)
                                    .background(
                                        LinearGradient(
                                            stops: [
                                                Gradient.Stop(color: .white.opacity(0), location: 0.00),
                                                Gradient.Stop(color: .white, location: 0.58),
                                                Gradient.Stop(color: .white, location: 1.00),
                                            ],
                                            startPoint: UnitPoint(x: 0.5, y: 0),
                                            endPoint: UnitPoint(x: 0.5, y: 1)
                                        )
                                    )
                                }
                            }
                            .clipShape(
                                UnevenRoundedRectangle(
                                    topLeadingRadius: metrics.accountImageCornerRadius,
                                    bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0,
                                    topTrailingRadius: metrics.accountImageCornerRadius
                                )
                            )

                            if !subscriptionManager.isSubscribed {
                                Button {
                                    showPaywall = true
                                } label: {
                                    HStack(alignment: .center) {
                                        Spacer()
                                        Text(NSLocalizedString("account.viewplans.button", comment: "View Plans button"))
                                            .font(metrics.accountViewPlansFont)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(metrics.accountButtonFont)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, metrics.accountButtonVerticalPadding)
                                    .padding(.horizontal, metrics.accountButtonHorizontalPadding)
                                }
                                .buttonStyle(.borderedProminent)
                                .clipShape(RoundedRectangle(cornerRadius: metrics.cardCornerRadius, style: .continuous))
                            }
                        }

                        VStack(spacing: metrics.separatorHeight * 4) {
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Unlimited scans & conversions", comment: "Paywall feature description"))
                            featureDivider(metrics: metrics)
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Create PDFs from photo album", comment: "Paywall feature description"))
                            featureDivider(metrics: metrics)
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Sign documents", comment: "Paywall feature description"))
                            featureDivider(metrics: metrics)
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Easy & instant share", comment: "Paywall feature description"))
                            featureDivider(metrics: metrics)
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Organize all your files", comment: "Paywall feature description"))
                            featureDivider(metrics: metrics)
                            FeatureRow(metrics: metrics, text: NSLocalizedString("Keep your original designs", comment: "Paywall feature description"))
                        }

                        if subscriptionManager.isSubscribed {
                            Button {
                                presentManageSubscriptions()
                            } label: {
                                Text(NSLocalizedString("account.manage.button", comment: "Manage Subscription button"))
                                    .font(metrics.accountBodyFont)
                                    .foregroundStyle(Color(hex: "#363636"))
                                    .underline()
                            }
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, metrics.verticalSpacingSmall)
                        }
                    }
                    .padding(.horizontal, metrics.accountHorizontalPadding)
                    .padding(.vertical, metrics.accountVerticalPadding)
                }
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

    private func featureDivider(metrics: PaywallMetrics) -> some View {
        Divider().overlay(Color(hex: "#979494"))
            .padding(.trailing, metrics.dividerTrailingPadding)
            .padding(.leading, metrics.checkmarkLeadingPadding)
    }
}

// MARK: - Preview

#Preview("Subscribed") {
    AccountView(showPaywall: .constant(false))
        .environmentObject(SubscriptionManager(mockSubscribed: true))
}

#Preview("Not Subscribed") {
    AccountView(showPaywall: .constant(false))
        .environmentObject(SubscriptionManager(mockSubscribed: false))
}
