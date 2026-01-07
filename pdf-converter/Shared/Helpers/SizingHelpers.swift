//
//  SizingHelpers.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/23/25.
//

import SwiftUI

struct PaywallMetrics {
    private let scale: CGFloat

    init(size: CGSize) {
        let baseWidth: CGFloat = 440
        scale = size.width / baseWidth
    }

    // Fonts
    var laurelFont: Font  { .system(size: 90 * scale) }
    var f1LightFont: Font  { .system(size: 48 * scale, weight: .light) }
    var f1BoldFont: Font { .system(size: 48 * scale, weight: .bold) }
    var f2Font: Font { .system(size: 32 * scale) }
    var f2BoldFont: Font { .system(size: 32 * scale, weight: .bold) }
    var f3Font: Font { .system(size: 20 * scale) }
    var f3SemiboldFont: Font { .system(size: 20 * scale, weight: .semibold)  }
    var f3BoldFont: Font { .system(size: 20 * scale, weight: .bold)  }
    var f3LightFont: Font { .system(size: 20 * scale, weight: .light)  }
    var f4Font: Font  { .system(size: 14 * scale) }
    var f5Font: Font { .system(size: 16 * scale) }

    // Account view fonts
    var accountTitleFont: Font { .system(size: 48 * scale, weight: .bold) }
    var accountLightTitleFont: Font { .system(size: 48 * scale, weight: .light) }
    var accountSectionTitleFont: Font { .system(size: 32 * scale, weight: .semibold) }
    var accountSubtitleFont: Font { .system(size: 16 * scale) }
    var accountBodyFont: Font { .system(size: 16 * scale) }
    var accountButtonFont: Font { .system(size: 16 * scale, weight: .medium) }
    var accountViewPlansFont: Font { .system(size: 20 * scale, weight: .medium) }
    var accountReviewButtonFont: Font { .system(size: 16 * scale, weight: .medium) }
    var horizontalSmallPadding: CGFloat { 4 * scale }

    // Spacing / paddings
    var horizontalPadding: CGFloat { 20 * scale }
    var cardCornerRadius: CGFloat { 16 }
    var featureCornerRadius: CGFloat { 4 }
    var buttonHeight: CGFloat { 60 * scale }
    var dollarCardHeight: CGFloat { 96 * scale }

    var checkmarkLeadingPadding: CGFloat { 18 * scale }
    var checkmarkTrailingPadding: CGFloat { 12 * scale }
    var dividerTrailingPadding: CGFloat { 40 * scale }
    var dollardividerTrailingPadding: CGFloat { 0 * scale }
    var dollarcheckmarkLeadingPadding: CGFloat { 0 * scale }

    var verticalSpacingLarge: CGFloat { 43 * scale }
    var verticalSpacingIntraSection: CGFloat { 16 * scale }
    var verticalSpacingIntraCard: CGFloat { 10.5 * scale }
    var verticalSpacingMedium: CGFloat { 24 * scale }
    var verticalSpacingSmall: CGFloat { 8 * scale }
    var verticalSpacingExtraLarge: CGFloat { 32 * scale }

    var separatorWidth: CGFloat { 174.60318 * scale }
    var separatorHeight: CGFloat { 2 * scale }

    // Account view specific
    var accountHorizontalPadding: CGFloat { 24 * scale }
    var accountVerticalPadding: CGFloat { 20 * scale }
    var accountImageCornerRadius: CGFloat { 20 * scale }
    var accountButtonCornerRadius: CGFloat { 12 * scale }
    var accountButtonVerticalPadding: CGFloat { 14 * scale }
    var accountButtonHorizontalPadding: CGFloat { 20 * scale }
    var accountIconSize: CGFloat { 20 * scale }
    var accountReviewButtonVerticalPadding: CGFloat { 4 * scale }
    var accountReviewButtonHorizontalPadding: CGFloat { 10 * scale }
    var accountImageWidth: CGFloat { 389.6 * scale }
    var accountImageHeight: CGFloat { 300 * scale }
    var accountGradientHeight: CGFloat { 128 * scale }
}
