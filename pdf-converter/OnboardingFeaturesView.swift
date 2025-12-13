import SwiftUI

struct OnboardingFeaturesView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private let features: [FeatureInfo] = [
        FeatureInfo(
            id: 0,
            imageName: "feature-convert",
            titlePrefix: "Choose any file and ",
            titleHighlight: "Convert",
            highlightedTag: "Convert"
        ),
        FeatureInfo(
            id: 1,
            imageName: "feature-scan",
            titlePrefix: "Use your camera to ",
            titleHighlight: "Scan",
            highlightedTag: "Scan"
        ),
        FeatureInfo(
            id: 2,
            imageName: "feature-share",
            titlePrefix: "Easy & instant ",
            titleHighlight: "Share",
            highlightedTag: "Share"
        ),
        FeatureInfo(
            id: 3,
            imageName: "feature-organize",
            titlePrefix: "Keep your files ",
            titleHighlight: "Organized",
            highlightedTag: "Organize"
        )
    ]

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingMetrics(size: proxy.size)

            ZStack {
                Color.white
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer()

                    // Swipeable feature pages
                    TabView(selection: $currentPage) {
                        ForEach(features) { feature in
                            featurePage(feature: feature, metrics: metrics, size: proxy.size)
                                .tag(feature.id)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(height: proxy.size.height * 0.85)

                    Spacer()
                }
            }
        }
    }

    private func featurePage(feature: FeatureInfo, metrics: OnboardingMetrics, size: CGSize) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            Spacer()

            // Feature illustration
            Image(feature.imageName)
                .resizable()
                .scaledToFit()
                .frame(height: size.height * 0.6)

            Spacer()

            // Title and tags section
            VStack(spacing: metrics.tagSpacing) {
                // Title with highlighted feature name
                HStack(spacing: 0) {
                    Text(feature.titlePrefix)
                        .font(metrics.titleRegularFont)
                    Text(feature.titleHighlight)
                        .font(metrics.titleBoldFont)
                }
                .foregroundColor(Color(hex: "#363636"))

                // Feature tags with one highlighted
                HStack(spacing: metrics.tagSpacing) {
                    FeatureTagSelective(
                        metrics: metrics,
                        text: "Convert",
                        isHighlighted: feature.highlightedTag == "Convert",
                        color: Color(hex: "#3A7377")
                    )
                    FeatureTagSelective(
                        metrics: metrics,
                        text: "Scan",
                        isHighlighted: feature.highlightedTag == "Scan",
                        color: Color(hex: "#CE2B6F")
                    )
                    FeatureTagSelective(
                        metrics: metrics,
                        text: "Share",
                        isHighlighted: feature.highlightedTag == "Share",
                        color: Color(hex: "#9633E7")
                    )
                    FeatureTagSelective(
                        metrics: metrics,
                        text: "Organize",
                        isHighlighted: feature.highlightedTag == "Organize",
                        color: Color(hex: "#D07826")
                    )
                }
            }
            .padding(.horizontal, metrics.horizontalPadding)

            // Continue button
            continueButton(metrics: metrics)
                .padding(.top, metrics.sectionSpacing)

            // Progress indicator
            pageIndicator(metrics: metrics)
                .padding(.top, metrics.sectionSpacing / 2)
                .padding(.bottom, metrics.contentBottomPadding)
        }
    }

    private func continueButton(metrics: OnboardingMetrics) -> some View {
        Button(action: {
            if currentPage < features.count - 1 {
                withAnimation {
                    currentPage += 1
                }
            } else {
                // Last page - dismiss to show paywall
                isPresented = false
            }
        }) {
            HStack(alignment: .center){
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
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private func pageIndicator(metrics: OnboardingMetrics) -> some View {
        HStack(spacing: 8 * metrics.scaleValue) {
            ForEach(0..<features.count, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color(hex: "#363636") : Color(hex: "#ACACAC"))
                    .frame(width: 8 * metrics.scaleValue, height: 8 * metrics.scaleValue)
            }
        }
    }
}

// MARK: - Supporting Types

struct FeatureInfo: Identifiable {
    let id: Int
    let imageName: String
    let titlePrefix: String
    let titleHighlight: String
    let highlightedTag: String
}

struct FeatureTagSelective: View {
    let metrics: OnboardingMetrics
    let text: String
    let isHighlighted: Bool
    let color: Color

    var body: some View {
        Text(text)
            .font(metrics.tagFont)
            .foregroundColor(isHighlighted ? .white : Color(hex: "#535353"))
            .padding(.horizontal, metrics.tagHorizontalPadding)
            .padding(.vertical, metrics.tagVerticalPadding)
            .background(isHighlighted ? color : Color(hex: "#ACACAC"))
            .cornerRadius(metrics.tagCornerRadius)
    }
}

// MARK: - Preview

#Preview {
    OnboardingFeaturesView(isPresented: .constant(true))
}
