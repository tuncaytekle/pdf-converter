import SwiftUI

struct OnboardingFlowView: View {
    @Binding var isPresented: Bool
    @State private var currentPage = 0

    private let totalPages = 6 // 1 welcome + 4 features + 1 formats

    var body: some View {
        GeometryReader { proxy in
            let metrics = OnboardingMetrics(size: proxy.size)

            TabView(selection: $currentPage) {
                // Page 0: Welcome screen
                welcomePage(metrics: metrics, size: proxy.size)
                    .tag(0)

                // Pages 1-4: Feature screens
                ForEach(1...4, id: \.self) { index in
                    featurePage(for: index - 1, metrics: metrics)
                        .tag(index)
                }

                // Page 5: Formats page
                formatsPage(metrics: metrics)
                    .tag(5)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
    }

    // MARK: - Welcome Page

    private func welcomePage(metrics: OnboardingMetrics, size: CGSize) -> some View {
        ZStack {
            // Background image
            Image("onboarding-background")
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
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
                welcomeContent(metrics: metrics)
                .padding(.top, metrics.contentTopPadding)
            }
            .ignoresSafeArea()

        }
    }

    private func welcomeContent(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            // Laurel badge section
            badgeSection(metrics: metrics)

            // Welcome message + tags
            messageSection(metrics: metrics)

            // Continue button
            continueButton(metrics: metrics, isLastPage: false)

            // Disclaimer
            disclaimer(metrics: metrics)
        }
        .padding(.horizontal, metrics.horizontalPadding)
    }

    private func badgeSection(metrics: OnboardingMetrics) -> some View {
        HStack(spacing: 0) {
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

                Text("#1 Converter App")
                    .font(metrics.badgeTitleFont)
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
                    Text("100+ ")
                        .font(metrics.badgeSubtitleBoldFont)
                    Text("formats supported")
                        .font(metrics.badgeSubtitleLightFont)
                }
                .foregroundColor(Color(hex: "#363636"))
            }

            Image(systemName: "laurel.trailing")
                .font(metrics.laurelFont)
                .foregroundColor(Color(hex: "#FFCE44"))
        }
    }

    private func messageSection(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: metrics.tagSpacing) {
            HStack(spacing: 0) {
                Text("Welcome to ")
                    .font(metrics.titleRegularFont)
                Text("PDF Converter")
                    .font(metrics.titleBoldFont)
            }
            .foregroundColor(Color(hex: "#363636"))

            HStack(spacing: metrics.tagSpacing) {
                OnboardingFeatureTag(metrics: metrics, text: "Convert", color: Color(hex: "#3A7377"))
                OnboardingFeatureTag(metrics: metrics, text: "Scan", color: Color(hex: "#CE2B6F"))
                OnboardingFeatureTag(metrics: metrics, text: "Share", color: Color(hex: "#9633E7"))
                OnboardingFeatureTag(metrics: metrics, text: "Organize", color: Color(hex: "#D07826"))
            }
        }
    }

    private func disclaimer(metrics: OnboardingMetrics) -> some View {
        VStack(spacing: 0) {
            Text("By pressing continue you confirm that you")
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

    // MARK: - Feature Pages

    private func featurePage(for index: Int, metrics: OnboardingMetrics) -> some View {
        let feature = features[index]

        return onboardingPage(metrics: metrics, isLastPage: index == features.count - 1) {
            Image(feature.imageName)
                .resizable()
                .scaledToFit()
        } titleSection: {
            VStack(spacing: metrics.tagSpacing) {
                HStack(spacing: 0) {
                    Text(feature.titlePrefix)
                        .font(metrics.titleRegularFont)
                    Text(feature.titleHighlight)
                        .font(metrics.titleBoldFont)
                }
                .foregroundColor(Color(hex: "#363636"))

                HStack(spacing: metrics.tagSpacing) {
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Convert",
                        isHighlighted: feature.highlightedTag == "Convert",
                        color: Color(hex: "#3A7377")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Scan",
                        isHighlighted: feature.highlightedTag == "Scan",
                        color: Color(hex: "#CE2B6F")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Share",
                        isHighlighted: feature.highlightedTag == "Share",
                        color: Color(hex: "#9633E7")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Organize",
                        isHighlighted: feature.highlightedTag == "Organize",
                        color: Color(hex: "#D07826")
                    )
                }
            }
        }
    }

    // MARK: - Shared Components

    private func continueButton(metrics: OnboardingMetrics, isLastPage: Bool) -> some View {
        Button(action: {
            // Haptic feedback
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()

            if currentPage < totalPages - 1 {
                withAnimation {
                    currentPage += 1
                }
            } else {
                // Last page - dismiss to show paywall
                isPresented = false
            }
        }) {
            HStack(alignment: .center) {
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

    // MARK: - Formats Page

    private func formatsPage(metrics: OnboardingMetrics) -> some View {
        onboardingPage(metrics: metrics, isLastPage: true) {
            formatsBox(metrics: metrics)
        } titleSection: {
            VStack(spacing: metrics.tagSpacing) {
                HStack(spacing: 0) {
                    Text("100+")
                        .font(metrics.titleBoldFont)
                    Text(" Formats Supported")
                        .font(metrics.titleRegularFont)
                }
                .foregroundColor(Color(hex: "#363636"))

                HStack(spacing: metrics.tagSpacing) {
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Convert",
                        isHighlighted: true,
                        color: Color(hex: "#3A7377")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Scan",
                        isHighlighted: true,
                        color: Color(hex: "#CE2B6F")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Share",
                        isHighlighted: true,
                        color: Color(hex: "#9633E7")
                    )
                    FlowFeatureTag(
                        metrics: metrics,
                        text: "Organize",
                        isHighlighted: true,
                        color: Color(hex: "#D07826")
                    )
                }
            }
        }
    }

    private func onboardingPage<Hero: View, TitleSection: View>(
        metrics: OnboardingMetrics,
        isLastPage: Bool,
        @ViewBuilder hero: () -> Hero,
        @ViewBuilder titleSection: () -> TitleSection
    ) -> some View {
        ZStack {
            Color.white
                .ignoresSafeArea()

            VStack(spacing: metrics.sectionSpacing) {
                Spacer()

                heroContainer(metrics: metrics, content: hero)
                    .padding(.horizontal, metrics.horizontalPadding)

                titleSection()
                    .padding(.horizontal, metrics.horizontalPadding)

                continueButton(metrics: metrics, isLastPage: isLastPage)
                    .padding(.top, metrics.sectionSpacing)

                pageIndicator(metrics: metrics)
                    .padding(.top, metrics.sectionSpacing / 2)
                    .padding(.bottom, metrics.contentBottomPadding)
            }
        }
    }

    @ViewBuilder
    private func heroContainer<Content: View>(
        metrics: OnboardingMetrics,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: metrics.heroMaxWidth)
            .frame(maxWidth: .infinity)
            .frame(height: metrics.heroHeight, alignment: .center)
    }

    private func formatsBox(metrics: OnboardingMetrics) -> some View {
        // Organize formats by rows with specific items per row
        let formatRows: [[(String, String)]] = [
            [("pdf", "#614d81"), ("epub", "#6c8ec9")],
            [("docx", "#9633e7"), ("pages", "#ce2b6f")],
            [("xlsx", "#3a7377"), ("pptx", "#614d81")],
            [("numbers", "#d07826"), ("key", "#6c8ec9")],
            [("jpeg", "#ce2b6f"), ("png", "#3a7377"), ("rtf", "#d07826")],
            [("svg", "#9633e7"), ("tiff", "#ce2b6f"), ("psd", "#614d81")],
            [("mobi", "#3a7377")]
        ]

        return VStack(alignment: .leading, spacing: metrics.formatBadgeSpacing) {
            ForEach(Array(formatRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .center, spacing: metrics.formatBadgeSpacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        let (format, colorHex) = item
                        Text(format)
                            .font(metrics.formatBadgeFont)
                            .foregroundColor(.white)
                            .frame(height: metrics.formatBadgeHeight)
                            .padding(.horizontal, metrics.formatBadgeHorizontalPadding)
                            .background(Color(hex: colorHex))
                            .cornerRadius(metrics.formatBadgeCornerRadius)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .padding(.horizontal, metrics.formatsBoxHorizontalPadding)
        .padding(.vertical, metrics.formatsBoxVerticalPadding)
        .frame(maxWidth: metrics.heroMaxWidth, alignment: .topLeading)
        .frame(height: metrics.heroHeight, alignment: .topLeading)
        .background(Color(hex: "#363636"))
        .cornerRadius(metrics.formatsBoxCornerRadius)
    }

    private func pageIndicator(metrics: OnboardingMetrics) -> some View {
        HStack(spacing: 8 * metrics.scaleValue) {
            ForEach(0..<totalPages, id: \.self) { index in
                Circle()
                    .fill(index == currentPage ? Color(hex: "#363636") : Color(hex: "#ACACAC"))
                    .frame(width: 8 * metrics.scaleValue, height: 8 * metrics.scaleValue)
            }
        }
    }

    // MARK: - Feature Data

    private let features: [FlowFeatureInfo] = [
        FlowFeatureInfo(
            imageName: "feature-convert",
            titlePrefix: "Choose any file and ",
            titleHighlight: "Convert",
            highlightedTag: "Convert"
        ),
        FlowFeatureInfo(
            imageName: "feature-scan",
            titlePrefix: "Use your camera to ",
            titleHighlight: "Scan",
            highlightedTag: "Scan"
        ),
        FlowFeatureInfo(
            imageName: "feature-share",
            titlePrefix: "Easy & instant ",
            titleHighlight: "Share",
            highlightedTag: "Share"
        ),
        FlowFeatureInfo(
            imageName: "feature-organize",
            titlePrefix: "Keep your files ",
            titleHighlight: "Organized",
            highlightedTag: "Organize"
        )
    ]
}

// MARK: - Supporting Types

private struct FlowFeatureInfo {
    let imageName: String
    let titlePrefix: String
    let titleHighlight: String
    let highlightedTag: String
}

private struct FlowFeatureTag: View {
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
    OnboardingFlowView(isPresented: .constant(true))
}
