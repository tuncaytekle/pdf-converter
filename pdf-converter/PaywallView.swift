import SwiftUI
import StoreKit
import PostHog


/// Animated paywall presented to users who have never purchased a subscription
struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var animationStage: AnimationStage = .toggleOff
    @State private var toggleEnabled = false
    @State private var showTrialText = false
    @State private var showFullPaywall = false

    @Environment(\.analytics) private var analytics
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var vm: PaywallViewModel
    @StateObject private var accountVM = AccountViewModel()

    init(productId: String, source: String) {
        _vm = StateObject(wrappedValue: PaywallViewModel(productId: productId, source: source))
    }

    enum AnimationStage {
        case toggleOff
        case toggleOn
        case fullPaywall
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = PaywallMetrics(size: proxy.size)
            
            ZStack {
                Color.white
                    .ignoresSafeArea()
                
                if animationStage == .fullPaywall && showFullPaywall {
                    fullPaywallContent(metrics: metrics)
                        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                } else {
                    toggleAnimationContent(metrics: metrics)
                }
            }
            .onAppear {
                // Track paywall viewed with intro offer eligibility
                let eligibleForIntro = subscriptionManager.product?.subscription?.introductoryOffer != nil
                vm.trackPaywallViewed(analytics: analytics, eligibleForIntroOffer: eligibleForIntro)

                startAnimation()
            }
            .onChange(of: subscriptionManager.purchaseState) { _, newState in
                // Track purchase result
                trackPurchaseResult(newState)

                if newState == .purchased {
                    // Dismiss paywall after successful purchase
                    dismiss()
                }
            }
            .postHogScreenView("Paywall", [
                "paywall_id": vm.paywallId,
                "source": vm.source,
                "product_id": vm.productId,
                "eligible_for_intro_offer": subscriptionManager.product?.subscription?.introductoryOffer != nil
            ])
        }
    }

    // MARK: - Toggle Animation Content

    private func toggleAnimationContent(metrics: PaywallMetrics) -> some View {
        VStack(spacing: metrics.verticalSpacingIntraSection) {
            Spacer()

            // Text appears above toggle without shifting toggle position
            Text(NSLocalizedString("7 day trial enabled", comment: "Trial enabled message"))
                .font(metrics.f3Font)
                .foregroundColor(Color(hex: "#363636"))
                .opacity(showTrialText ? 1 : 0)
                .scaleEffect(reduceMotion ? 1 : (showTrialText ? 1 : 0.8))

            // Toggle switch - stays in same position
            Toggle("", isOn: $toggleEnabled)
                .labelsHidden()
                .toggleStyle(CustomToggleStyle())
                .disabled(true)

            Spacer()
        }
        .padding()
    }

    // MARK: - Full Paywall Content

    private func fullPaywallContent(metrics: PaywallMetrics) -> some View {
        VStack(spacing: metrics.verticalSpacingLarge) {
            topSection(metrics: metrics)
            
            featuresList(metrics: metrics)
            
            bottomSection(metrics: metrics)
        }
    }
    
    private func bottomSection(metrics: PaywallMetrics) -> some View {
        VStack(spacing: metrics.verticalSpacingIntraSection) {
            trialButtonLike(metrics: metrics)
            
            continueButton(metrics: metrics)
            
            finePrint(metrics: metrics)
            
            footerLinks(metrics: metrics)
        }

    }
    
    private func footerLinks(metrics: PaywallMetrics) -> some View {
        HStack(spacing: 0) {
            Button(NSLocalizedString("Terms of Use", comment: "Terms of use link")) {
                // TODO: Open Terms of Use
            }
            
            Spacer()
            
            Button(NSLocalizedString("Privacy Policy", comment: "Privacy policy link")) {
                // TODO: Open Privacy Policy
            }
        }
        .font(metrics.f4Font)
        .foregroundColor(Color(hex: "#979494"))
        .padding(.horizontal, metrics.horizontalPadding)
    }
    
    private func trialButtonLike(metrics: PaywallMetrics) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(metrics.f3Font)
                .foregroundColor(Color(hex: "#007AFF"))
                .padding(.trailing, metrics.checkmarkTrailingPadding)
            
            Text(NSLocalizedString("7-Day Full Access", comment: "Paywall pricing option title"))
                .font(metrics.f3Font)
                .foregroundColor(Color(hex: "#363636"))

            Spacer()

            if let product = subscriptionManager.product,
               let introOffer = product.subscription?.introductoryOffer {
                Text(introOffer.displayPrice)
                    .font(metrics.f3Font)
                    .foregroundColor(Color(hex: "#363636"))
            } else {
                Text(NSLocalizedString("$0.49", comment: "Trial price"))
                    .font(metrics.f3Font)
                    .foregroundColor(Color(hex: "#363636"))
            }
         }
        .padding(metrics.verticalSpacingIntraSection)
        .frame(maxWidth: .infinity, minHeight: metrics.buttonHeight, maxHeight: metrics.buttonHeight, alignment: .center)
        .background(Color(red: 0, green: 0.48, blue: 1).opacity(0.2))
        .cornerRadius(metrics.cardCornerRadius)
        .overlay(
          RoundedRectangle(cornerRadius: metrics.cardCornerRadius)
            .inset(by: 1)
            .stroke(Color(red: 0, green: 0.48, blue: 1), lineWidth: 2)
        )
        .padding(.horizontal, metrics.horizontalPadding)
    }
    
    private func finePrint(metrics: PaywallMetrics) -> some View {
        Group {
            if let product = subscriptionManager.product,
               let subscription = product.subscription {
                let trialPrice = subscription.introductoryOffer?.displayPrice ?? "$0.49"
                let regularPrice = product.displayPrice
                Text(String(format: NSLocalizedString("paywall.finePrint.withPrices", comment: "Paywall subscription terms with prices"), trialPrice, regularPrice))
                    .font(metrics.f4Font)
                    .foregroundColor(Color(hex: "#363636"))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(NSLocalizedString("First 7 days at $0.49. Auto-renews at $9.99/week.\nNo commitment, cancel anytime!", comment: "Paywall subscription terms"))
                    .font(metrics.f4Font)
                    .foregroundColor(Color(hex: "#363636"))
                    .multilineTextAlignment(.center)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    
    
    private func topSection(metrics: PaywallMetrics) -> some View {
        VStack(spacing: metrics.verticalSpacingIntraSection) {
            HStack {
                Button(action: {
                    vm.trackPaywallDismissedIfNeeded(analytics: analytics, dismissMethod: "close_button")
                    dismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(metrics.f3Font)
                        .foregroundColor(Color(hex: "#979494"))
                }

                Spacer()

                Button(action: {
                    accountVM.trackRestorePurchasesTapped(analytics: analytics, from: "paywall")
                    Task {
                        await subscriptionManager.restorePurchases()
                    }
                }) {
                    Text(NSLocalizedString("Restore", comment: "Restore purchases button"))
                        .font(metrics.f3Font)
                        .foregroundColor(Color(hex: "#979494"))
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)
            
            markdownText(
                key: "paywall_title",
                comment: "Paywall title",
                boldFont: metrics.f1BoldFont,
                lightFont: metrics.f1LightFont,
                color: Color(hex: "#363636")
            )
            badgeSection(metrics: metrics)
            
            featureTags(metrics: metrics)
        }
        .padding(.top, metrics.verticalSpacingIntraSection)
    }

    private func badgeSection(metrics: PaywallMetrics) -> some View {
        HStack(spacing: 0) {
            // Left laurel (simplified)
            Image(systemName: "laurel.leading")
                .font(metrics.laurelFont)
                .foregroundColor(Color(hex: "#FFCE44"))
                .rotationEffect(.degrees(0))
            VStack(spacing: metrics.separatorHeight * 3) {
                // Stars
                HStack(spacing: metrics.separatorHeight * 2) {
                    ForEach(0..<5) { _ in
                        Image(systemName: "star.fill")
                            .font(metrics.f3Font)
                            .foregroundColor(Color(hex: "#FFCE44"))
                    }
                }
                // "#1 Converter App" with laurel wreaths
                Text(NSLocalizedString("#1 Converter App", comment: "App ranking badge"))
                    .font(metrics.f2BoldFont)
                    .foregroundColor(Color(hex: "#363636"))
                Rectangle()
                    .foregroundColor(.clear)
                    .frame(width: metrics.separatorWidth, height: metrics.separatorHeight)
                    .background(
                        LinearGradient(
                            stops: [
                                Gradient.Stop(color: Color(red: 0.21, green: 0.21, blue: 0.21).opacity(0), location: 0.00),
                                Gradient.Stop(color: Color(red: 0.21, green: 0.21, blue: 0.21), location: metrics.separatorHeight / 4),
                                Gradient.Stop(color: Color(red: 0.21, green: 0.21, blue: 0.21).opacity(0), location: metrics.separatorHeight / 2),
                            ],
                            startPoint: UnitPoint(x: 0, y: metrics.separatorHeight / 4),
                            endPoint: UnitPoint(x: metrics.separatorHeight / 2, y: metrics.separatorHeight / 4)
                        )
                    )
                HStack(spacing: 0) {
                    markdownText(
                        key: "100formats",
                        comment: "Formats supported",
                        boldFont: metrics.f3BoldFont,
                        lightFont: metrics.f3LightFont,
                        color: Color(hex: "#363636")
                    )
                }
                
                
            }

            
            // Right laurel (simplified)
            Image(systemName: "laurel.trailing")
                .font(metrics.laurelFont)
                .foregroundColor(Color(hex: "#FFCE44"))
                .rotationEffect(.degrees(0))
        }
    }

    private func featureTags(metrics: PaywallMetrics) -> some View {
        HStack(spacing: metrics.separatorHeight * 3) {
            FeatureTag(metrics: metrics, text: NSLocalizedString("Convert", comment: "Paywall feature tag"), color: Color(hex: "#3A7377"))
            FeatureTag(metrics: metrics, text: NSLocalizedString("Scan", comment: "Paywall feature tag"), color: Color(hex: "#CE2B6F"))
            FeatureTag(metrics: metrics, text: NSLocalizedString("Share", comment: "Paywall feature tag"), color: Color(hex: "#9633E7"))
            FeatureTag(metrics: metrics, text: NSLocalizedString("Organize", comment: "Paywall feature tag"), color: Color(hex: "#D07826"))
        }
        .padding(.horizontal, metrics.horizontalPadding)
    }
    
    private func divider(metrics: PaywallMetrics) -> some View {
        Divider().overlay(Color(hex: "#979494"))
            .padding(.trailing, metrics.dividerTrailingPadding)
            .padding(.leading, metrics.checkmarkLeadingPadding)
    }

    public func featuresList(metrics: PaywallMetrics) -> some View {
        VStack(spacing: metrics.separatorHeight * 4) {
            FeatureRow(metrics: metrics, text: NSLocalizedString("Unlimited scans & conversions", comment: "Paywall feature description"))
            divider(metrics: metrics)
            FeatureRow(metrics: metrics, text: NSLocalizedString("Create PDFs from photo album", comment: "Paywall feature description"))
            divider(metrics: metrics)
            FeatureRow(metrics: metrics, text: NSLocalizedString("Sign documents", comment: "Paywall feature description"))
            divider(metrics: metrics)
            FeatureRow(metrics: metrics, text: NSLocalizedString("Easy & instant share", comment: "Paywall feature description"))
            divider(metrics: metrics)
            FeatureRow(metrics: metrics, text: NSLocalizedString("Organize all your files", comment: "Paywall feature description"))
            divider(metrics: metrics)
            FeatureRow(metrics: metrics, text: NSLocalizedString("Keep your original designs", comment: "Paywall feature description"))
        }
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private func continueButton(metrics: PaywallMetrics) -> some View {
        Button(action: {
            vm.trackPurchaseTapped(analytics: analytics)
            subscriptionManager.purchase()
        }) {
            HStack(alignment: .center) {
                Spacer()
                Text(NSLocalizedString("Continue", comment: "Continue button"))
                    .font(metrics.f3Font)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(metrics.f3Font)
                    .foregroundColor(.white)
            }
            .padding(metrics.verticalSpacingIntraSection)
            .frame(maxWidth: .infinity, minHeight: metrics.buttonHeight, maxHeight: metrics.buttonHeight, alignment: .center)
            .background(Color(red: 0, green: 0.48, blue: 1))
            .cornerRadius(metrics.cardCornerRadius)
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .disabled(subscriptionManager.purchaseState == .purchasing)
    }

    // MARK: - Animation Logic

    private func startAnimation() {
        // If reduce motion is enabled, skip animation and show paywall immediately
        if reduceMotion {
            animationStage = .fullPaywall
            showFullPaywall = true
            return
        }

        // Stage 1: Show toggle in OFF state for 1 second
        animationStage = .toggleOff

        // Stage 2: After 1s, animate toggle to ON
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.75)) {
                toggleEnabled = true
                animationStage = .toggleOn
            }

            // Show trial text after toggle animation completes
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeIn(duration: 0.5)) {
                    showTrialText = true
                }

                // Stage 3: After 1.5s with text visible, transition to full paywall
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) {
                        animationStage = .fullPaywall
                        showFullPaywall = true
                    }
                }
            }
        }
    }

    // MARK: - Tracking Helpers

    private func trackPurchaseResult(_ purchaseState: SubscriptionManager.PurchaseState) {
        let outcome: PaywallViewModel.PurchaseOutcome
        let verified: Bool

        switch purchaseState {
        case .purchased:
            outcome = .success
            verified = true

        case .pending:
            outcome = .pending
            verified = false

        case .idle:
            // User cancelled - only track if we were in purchasing state
            outcome = .userCancelled
            verified = false

        case .failed(let errorMessage):
            // Categorize the error
            let category = categorizeError(errorMessage)
            outcome = .failed(category: category)
            verified = false

        case .purchasing:
            // Don't track intermediate state
            return
        }

        vm.trackPurchaseResult(analytics: analytics, outcome: outcome, verified: verified)
    }

    private func categorizeError(_ errorMessage: String) -> String {
        let lowercased = errorMessage.lowercased()

        if lowercased.contains("network") || lowercased.contains("connection") {
            return "network_error"
        } else if lowercased.contains("verification") || lowercased.contains("verified") {
            return "verification_failed"
        } else if lowercased.contains("product") || lowercased.contains("not found") {
            return "product_not_found"
        } else if lowercased.contains("storekit") {
            return "storekit_error"
        } else {
            return "unknown"
        }
    }
}

// MARK: - Supporting Views

struct FeatureTag: View {
    let metrics: PaywallMetrics
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(metrics.f3SemiboldFont)
            .foregroundColor(.white)
            .padding(.horizontal, metrics.separatorHeight * 3)
            .padding(.vertical, metrics.separatorHeight)
            .background(color)
            .cornerRadius(metrics.featureCornerRadius)
    }
}

struct FeatureRow: View {
    let metrics: PaywallMetrics
    let text: String

    var body: some View {
        HStack(spacing: metrics.checkmarkTrailingPadding) {
            Image(systemName: "checkmark.circle.fill")
                .font(metrics.f3Font)
                .foregroundColor(Color(hex: "#007AFF"))

            Text(text)
                .font(metrics.f3Font)
                .foregroundColor(Color(hex: "#363636"))

            Spacer()
        }
        .padding(.leading, metrics.checkmarkLeadingPadding)
    }
}

struct CustomToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(configuration.isOn ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 51, height: 31)
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .padding(2)
                        .offset(x: configuration.isOn ? 10 : -10)
                )
        }
    }
}

// MARK: - Preview


struct PaywallView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            PaywallView(productId: "com.example.product", source: "preview")
                .environmentObject(SubscriptionManager())
                .environment(\.locale, .init(identifier: "en"))

            PaywallView(productId: "com.example.product", source: "preview")
                .environmentObject(SubscriptionManager())
                .environment(\.locale, .init(identifier: "tr"))
        }
    }
}
