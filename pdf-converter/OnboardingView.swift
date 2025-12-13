import SwiftUI

struct OnboardingMetrics {
    private let scale: CGFloat

    init(size: CGSize) {
        let baseWidth: CGFloat = 440
        scale = size.width / baseWidth
    }

    // Expose scale for custom calculations
    var scaleValue: CGFloat { scale }

    // Fonts
    var laurelFont: Font { .system(size: 90 * scale) }
    var titleRegularFont: Font { .system(size: 32 * scale, weight: .light) }
    var titleBoldFont: Font { .system(size: 32 * scale, weight: .bold) }
    var badgeTitleFont: Font { .system(size: 32 * scale, weight: .bold) }
    var badgeSubtitleBoldFont: Font { .system(size: 20 * scale, weight: .bold) }
    var badgeSubtitleLightFont: Font { .system(size: 20 * scale, weight: .light) }
    var tagFont: Font { .system(size: 16 * scale, weight: .semibold) }
    var buttonFont: Font { .system(size: 20 * scale) }
    var disclaimerFont: Font { .system(size: 14 * scale) }
    var starFont: Font { .system(size: 16 * scale) }

    // Spacing
    var horizontalPadding: CGFloat { 25.49 * scale }
    var sectionSpacing: CGFloat { 24 * scale }
    var tagSpacing: CGFloat { 4 * scale }
    var buttonHeight: CGFloat { 60 * scale }
    var cardCornerRadius: CGFloat { 16 * scale }
    var tagCornerRadius: CGFloat { 4 * scale }

    var separatorWidth: CGFloat { 174.603 * scale }
    var separatorHeight: CGFloat { 2 * scale }
    var gradientHeight: CGFloat { 457 * scale }
    var contentBottomPadding: CGFloat { 37 * scale }
    var badgeInnerSpacing: CGFloat { 4 * scale }
    var starContainerHeight: CGFloat { 24 * scale }
    var chevronSize: CGFloat { 14 * scale }
    var buttonPadding: CGFloat { 16 * scale }
    var tagHorizontalPadding: CGFloat { 6 * scale }
    var tagVerticalPadding: CGFloat { 2 * scale }
}

struct OnboardingView: View {
    @Binding var isPresented: Bool

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingMetrics(size: proxy.size)

            ZStack {
                // Background image
                Image("onboarding-background")
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                    .ignoresSafeArea()

                // White gradient overlay at bottom
                VStack {
                    Spacer()
                    LinearGradient(
                        stops: [
                            Gradient.Stop(color: .white.opacity(0), location: 0),
                            Gradient.Stop(color: .white, location: 0.25),
                            Gradient.Stop(color: .white, location: 0.5),
                            Gradient.Stop(color: .white, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: metrics.gradientHeight)
                }
                .ignoresSafeArea()

                // Content
                VStack(spacing: 0) {
                    Spacer()

                    contentSection(metrics: metrics)
                }
            }
        }
    }

    private func contentSection(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            // Laurel badge section
            badgeSection(metrics: metrics)

            // Welcome message + tags
            messageSection(metrics: metrics)

            // Continue button
            continueButton(metrics: metrics)

            // Disclaimer
            disclaimer(metrics: metrics)
        }
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private func badgeSection(metrics: OnboardingMetrics) -> some View {
        HStack(spacing: 0) {
            // Left laurel
            Image(systemName: "laurel.leading")
                .font(metrics.laurelFont)
                .foregroundColor(Color(hex: "#FFCE44"))

            VStack(spacing: metrics.badgeInnerSpacing) {
                // Stars
                HStack(spacing: metrics.badgeInnerSpacing) {
                    ForEach(0..<5) { _ in
                        Image(systemName: "star.fill")
                            .font(metrics.starFont)
                            .foregroundColor(Color(hex: "#FFCE44"))
                    }
                }
                .frame(height: metrics.starContainerHeight)

                // "#1 Converter App"
                Text("#1 Converter App")
                    .font(metrics.badgeTitleFont)
                    .foregroundColor(Color(hex: "#363636"))

                // Separator line
                Rectangle()
                    .frame(width: metrics.separatorWidth, height: metrics.separatorHeight)
                    .foregroundColor(Color(hex: "#363636"))

                // "100+ formats supported"
                HStack(spacing: 0) {
                    Text("100+ ")
                        .font(metrics.badgeSubtitleBoldFont)
                    Text("formats supported")
                        .font(metrics.badgeSubtitleLightFont)
                }
                .foregroundColor(Color(hex: "#363636"))
            }

            // Right laurel
            Image(systemName: "laurel.trailing")
                .font(metrics.laurelFont)
                .foregroundColor(Color(hex: "#FFCE44"))
        }
    }

    private func messageSection(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: metrics.tagSpacing) {
            // "Welcome to PDF Converter"
            HStack(spacing: 0) {
                Text("Welcome to ")
                    .font(metrics.titleRegularFont)
                Text("PDF Converter")
                    .font(metrics.titleBoldFont)
            }
            .foregroundColor(Color(hex: "#363636"))

            // Feature tags
            HStack(spacing: metrics.tagSpacing) {
                OnboardingFeatureTag(metrics: metrics, text: "Convert", color: Color(hex: "#3A7377"))
                OnboardingFeatureTag(metrics: metrics, text: "Scan", color: Color(hex: "#CE2B6F"))
                OnboardingFeatureTag(metrics: metrics, text: "Share", color: Color(hex: "#9633E7"))
                OnboardingFeatureTag(metrics: metrics, text: "Organize", color: Color(hex: "#D07826"))
            }
        }
    }

    private func continueButton(metrics: OnboardingMetrics) -> some View {
        Button(action: {
            // Just dismiss - ContentView will handle showing paywall next
            isPresented = false
        }) {
            HStack(alignment:.center) {
                Spacer()
                
                Text("Continue")
                    .font(metrics.buttonFont)
                    .foregroundColor(.white)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: metrics.chevronSize, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(metrics.buttonPadding)
            .frame(height: metrics.buttonHeight)
            .background(Color(hex: "#007AFF"))
            .cornerRadius(metrics.cardCornerRadius)
        }
    }

    private func disclaimer(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: 0) {
            Text("By pressing continue, you confirm that you")
                .font(metrics.disclaimerFont)
                .foregroundColor(Color(hex: "#898989"))
            Text("acknowledge and accept PDF Converter")
                .font(metrics.disclaimerFont)
                .foregroundColor(Color(hex: "#898989"))

            HStack(spacing: 0) {
                Button(action: {
                    // TODO: Open Privacy Policy
                }) {
                    Text("Privacy Policy")
                        .font(metrics.disclaimerFont)
                        .foregroundColor(Color(hex: "#363636"))
                        .underline()
                }

                Text(" and ")
                    .font(metrics.disclaimerFont)
                    .foregroundColor(Color(hex: "#898989"))

                Button(action: {
                    // TODO: Open Terms of Use
                }) {
                    Text("Terms of Use")
                        .font(metrics.disclaimerFont)
                        .foregroundColor(Color(hex: "#363636"))
                        .underline()
                }
            }
        }
        .multilineTextAlignment(.center)
    }
}

// MARK: - Supporting Views

struct OnboardingFeatureTag: View {
    let metrics: OnboardingMetrics
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(metrics.tagFont)
            .foregroundColor(.white)
            .padding(.horizontal, metrics.tagHorizontalPadding)
            .padding(.vertical, metrics.tagVerticalPadding)
            .background(color)
            .cornerRadius(metrics.tagCornerRadius)
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(isPresented: .constant(true))
}
