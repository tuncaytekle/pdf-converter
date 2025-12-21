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
    var contentTopPadding: CGFloat { 557 * scale }
    var badgeInnerSpacing: CGFloat { 4 * scale }
    var starContainerHeight: CGFloat { 24 * scale }
    var chevronSize: CGFloat { 14 * scale }
    var buttonPadding: CGFloat { 16 * scale }
    var tagHorizontalPadding: CGFloat { 6 * scale }
    var tagVerticalPadding: CGFloat { 2 * scale }
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
