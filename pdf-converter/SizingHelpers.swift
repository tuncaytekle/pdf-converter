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

    // Spacing / paddings
    var horizontalPadding: CGFloat { 20 * scale }
    var cardCornerRadius: CGFloat { 16 }
    var featureCornerRadius: CGFloat { 4 }
    var buttonHeight: CGFloat { 60 * scale }
    
    var checkmarkLeadingPadding: CGFloat { 18 * scale }
    var checkmarkTrailingPadding: CGFloat { 12 * scale }
    var dividerTrailingPadding: CGFloat { 40 * scale }

    var verticalSpacingLarge: CGFloat { 64 * scale }
    var verticalSpacingIntraSection: CGFloat { 16 * scale }
    
    var separatorWidth: CGFloat { 174.60318 * scale }
    var separatorHeight: CGFloat { 2 * scale }
}
