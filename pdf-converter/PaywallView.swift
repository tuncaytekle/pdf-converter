import SwiftUI
import StoreKit

/// Animated paywall presented to users who have never purchased a subscription
struct PaywallView: View {
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @Environment(\.dismiss) private var dismiss

    @State private var animationStage: AnimationStage = .toggleOff
    @State private var toggleEnabled = false
    @State private var showTrialText = false
    @State private var showFullPaywall = false

    enum AnimationStage {
        case toggleOff
        case toggleOn
        case fullPaywall
    }

    var body: some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            if animationStage == .fullPaywall && showFullPaywall {
                fullPaywallContent
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                toggleAnimationContent
            }
        }
        .onAppear {
            startAnimation()
        }
        .onChange(of: subscriptionManager.purchaseState) { _, newState in
            if newState == .purchased {
                // Dismiss paywall after successful purchase
                dismiss()
            }
        }
    }

    // MARK: - Toggle Animation Content

    private var toggleAnimationContent: some View {
        VStack(spacing: 16) {
            Spacer()

            if showTrialText {
                Text("7 day trial enabled")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundColor(Color(hex: "#363636"))
                    .transition(.opacity.combined(with: .scale))
            }

            // Toggle switch
            Toggle("", isOn: $toggleEnabled)
                .labelsHidden()
                .toggleStyle(CustomToggleStyle())
                .disabled(true)

            Spacer()
        }
        .padding()
    }

    // MARK: - Full Paywall Content

    private var fullPaywallContent: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(Color(hex: "#979494"))
                }

                Spacer()

                Button(action: {
                    subscriptionManager.openManageSubscriptions()
                }) {
                    Text("Restore")
                        .font(.system(size: 17))
                        .foregroundColor(Color(hex: "#979494"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 24)

            ScrollView {
                VStack(spacing: 24) {
                    // Title
                    Text("Unlimited ")
                        .font(.system(size: 34, weight: .regular)) +
                    Text("Access")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(Color(hex: "#363636"))

                    // Badge Section
                    badgeSection

                    // Feature Tags
                    featureTags

                    // Features List
                    featuresList

                    // Pricing Card
                    pricingCard

                    // Continue Button
                    continueButton

                    // Fine Print
                    Text("First 7 days at $0.49. Auto-renews at $9.99/week.\nNo commitment, cancel anytime!")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#979494"))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    // Footer Links
                    HStack(spacing: 32) {
                        Button("Terms of Use") {
                            // TODO: Open Terms of Use
                        }

                        Button("Privacy Policy") {
                            // TODO: Open Privacy Policy
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#979494"))
                    .padding(.bottom, 32)
                }
            }
        }
    }

    private var badgeSection: some View {
        VStack(spacing: 12) {
            // Stars
            HStack(spacing: 4) {
                ForEach(0..<5) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 16))
                        .foregroundColor(Color(hex: "#FFCE44"))
                }
            }

            // "#1 Converter App" with laurel wreaths
            HStack(spacing: 12) {
                // Left laurel (simplified)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "#FFCE44"))
                    .rotationEffect(.degrees(-45))

                Text("#1 Converter App")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Color(hex: "#363636"))

                // Right laurel (simplified)
                Image(systemName: "leaf.fill")
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "#FFCE44"))
                    .rotationEffect(.degrees(45))
                    .scaleEffect(x: -1, y: 1)
            }

            Text("100+ formats supported")
                .font(.system(size: 15))
                .foregroundColor(Color(hex: "#979494"))
        }
    }

    private var featureTags: some View {
        HStack(spacing: 8) {
            FeatureTag(text: "Convert", color: Color(hex: "#3A7377"))
            FeatureTag(text: "Scan", color: Color(hex: "#CE2B6F"))
            FeatureTag(text: "Share", color: Color(hex: "#9633E7"))
            FeatureTag(text: "Organize", color: Color(hex: "#D07826"))
        }
        .padding(.horizontal, 20)
    }

    private var featuresList: some View {
        VStack(spacing: 16) {
            FeatureRow(text: "Unlimited scans & conversions")
            FeatureRow(text: "Create PDFs from photo album")
            FeatureRow(text: "Sign documents")
            FeatureRow(text: "Easy & instant share")
            FeatureRow(text: "Organize all your files")
            FeatureRow(text: "Keep your original designs")
        }
        .padding(.horizontal, 20)
    }

    private var pricingCard: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "#007AFF"))

            Text("7-Day Full Access")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(Color(hex: "#363636"))

            Spacer()

            Text("$0.49")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(hex: "#363636"))
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(hex: "#007AFF"), lineWidth: 2)
        )
        .padding(.horizontal, 20)
    }

    private var continueButton: some View {
        Button(action: {
            subscriptionManager.purchase()
        }) {
            HStack {
                Text("Continue")
                    .font(.system(size: 17, weight: .semibold))

                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(hex: "#007AFF"))
            .cornerRadius(16)
        }
        .padding(.horizontal, 20)
        .disabled(subscriptionManager.purchaseState == .purchasing)
    }

    // MARK: - Animation Logic

    private func startAnimation() {
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
}

// MARK: - Supporting Views

struct FeatureTag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color)
            .cornerRadius(6)
    }
}

struct FeatureRow: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "#007AFF"))

            Text(text)
                .font(.system(size: 17))
                .foregroundColor(Color(hex: "#363636"))

            Spacer()
        }
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

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

#Preview {
    PaywallView()
        .environmentObject(SubscriptionManager())
}
