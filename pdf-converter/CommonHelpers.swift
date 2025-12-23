//
//  GlobalHelpers.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 12/10/25.
//

import SwiftUI

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

extension ToolbarContent {
    @ToolbarContentBuilder
    var hideSharedBackground: some ToolbarContent {
        #if compiler(>=6.2)
        if #available(iOS 26, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}


/// Lazily indexes text content for PDFs so search queries can match body text.
extension Bundle {
    var subscriptionProductID: String {
        let fallback = "com.roguewaveapps.pdfconverter.test.weekly.1"
        guard let rawValue = object(forInfoDictionaryKey: "SubscriptionProductID") as? String else {
            assertionFailure("SubscriptionProductID missing from Info.plist; falling back to test product ID.")
            return fallback
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "$(SUBSCRIPTION_PRODUCT_ID)" else {
            assertionFailure("SubscriptionProductID not configured for this build; falling back to test product ID.")
            return fallback
        }
        return trimmed
    }

    var gotenbergBaseURL: URL? {
        guard let rawValue = object(forInfoDictionaryKey: "GotenbergBaseURL") as? String else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != "$(GOTENBERG_BASE_URL)",
              let url = URL(string: trimmed) else {
            return nil
        }
        return url
    }
}
