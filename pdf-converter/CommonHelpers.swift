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

// MARK: - Markdown Text Helpers

/// Parses a localized string with Markdown and applies custom fonts to bold and normal text
/// - Parameters:
///   - key: The localization key to look up
///   - comment: The comment for the localized string
///   - boldFont: The font to apply to **bold** (strongly emphasized) text
///   - lightFont: The font to apply to normal text
///   - color: The color to apply to the entire text
/// - Returns: A Text view with the formatted attributed string
func markdownText(
    key: String,
    comment: String,
    boldFont: Font,
    lightFont: Font,
    color: Color
) -> Text {
    let localized = NSLocalizedString(key, comment: comment)

    // Parse Markdown. If parsing fails for any reason, fall back to plain text.
    var attr = (try? AttributedString(markdown: localized)) ?? AttributedString(localized)

    for run in attr.runs {
        let intent = run.inlinePresentationIntent
        let isStrong = intent?.contains(InlinePresentationIntent.stronglyEmphasized) == true

        attr[run.range].font = isStrong ? boldFont : lightFont
    }

    return Text(attr).foregroundColor(color)
}

/// A view that renders text with clickable markdown-style links
/// Example: "Accept our [Privacy Policy](privacy) and [Terms](terms)"
struct ClickableTextView: View {
    let key: String
    let comment: String
    let font: Font
    let textColor: Color
    let linkColor: Color
    let linkActions: [String: () -> Void]

    private struct TextSegment: Identifiable {
        let id = UUID()
        let text: String
        let isLink: Bool
        let linkID: String?
    }

    private var segments: [TextSegment] {
        parseMarkdownLinks(NSLocalizedString(key, comment: comment))
    }

    var body: some View {
        // Split into text before links and links section
        VStack(spacing: 0) {
            // Text before first link
            if let firstLinkIndex = segments.firstIndex(where: { $0.isLink }) {
                // All text segments before the first link
                let beforeLinkSegments = segments[..<firstLinkIndex]
                if !beforeLinkSegments.isEmpty {
                    Text(beforeLinkSegments.map { $0.text }.joined())
                        .font(font)
                        .foregroundColor(textColor)
                }

                // Links and text between/after them in HStack
                HStack(spacing: 0) {
                    ForEach(segments[firstLinkIndex...]) { segment in
                        if segment.isLink, let linkID = segment.linkID {
                            Button(action: {
                                linkActions[linkID]?()
                            }) {
                                Text(segment.text)
                                    .font(font)
                                    .foregroundColor(linkColor)
                                    .underline()
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(segment.text)
                                .font(font)
                                .foregroundColor(textColor)
                        }
                    }
                }
            } else {
                // No links, just render all text
                Text(segments.map { $0.text }.joined())
                    .font(font)
                    .foregroundColor(textColor)
            }
        }
    }

    private func parseMarkdownLinks(_ text: String) -> [TextSegment] {
        var segments: [TextSegment] = []
        let currentText = text

        let pattern = "\\[([^\\]]+)\\]\\(([^\\)]+)\\)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [TextSegment(text: text, isLink: false, linkID: nil)]
        }

        let matches = regex.matches(in: currentText, range: NSRange(currentText.startIndex..., in: currentText))

        var lastEnd = currentText.startIndex

        for match in matches {
            // Text before link
            if let matchRange = Range(match.range, in: currentText) {
                let beforeText = String(currentText[lastEnd..<matchRange.lowerBound])
                if !beforeText.isEmpty {
                    segments.append(TextSegment(text: beforeText, isLink: false, linkID: nil))
                }

                // Link text
                if let linkTextRange = Range(match.range(at: 1), in: currentText),
                   let linkIDRange = Range(match.range(at: 2), in: currentText) {
                    let linkText = String(currentText[linkTextRange])
                    let linkID = String(currentText[linkIDRange])
                    segments.append(TextSegment(text: linkText, isLink: true, linkID: linkID))
                }

                lastEnd = matchRange.upperBound
            }
        }

        // Remaining text
        if lastEnd < currentText.endIndex {
            let remainingText = String(currentText[lastEnd...])
            if !remainingText.isEmpty {
                segments.append(TextSegment(text: remainingText, isLink: false, linkID: nil))
            }
        }

        return segments.isEmpty ? [TextSegment(text: text, isLink: false, linkID: nil)] : segments
    }
}
