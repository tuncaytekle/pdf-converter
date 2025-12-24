//
//  ConversionViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class ConversionViewModel: ObservableObject {
    // MARK: - Floating Button

    func trackCreateButtonTapped(analytics: AnalyticsTracking, action: String) {
        analytics.capture("create_button_tapped", properties: ["action": action])
    }

    // MARK: - Scan Flows

    func trackScanStarted(analytics: AnalyticsTracking, source: String) {
        analytics.capture("scan_started", properties: ["source": source])
    }

    func trackScanCompleted(analytics: AnalyticsTracking, source: String, pageCount: Int) {
        analytics.capture("scan_completed", properties: [
            "source": source,
            "page_count": pageCount
        ])
    }

    func trackScanCancelled(analytics: AnalyticsTracking, source: String) {
        analytics.capture("scan_cancelled", properties: ["source": source])
    }

    // MARK: - File Conversion

    func trackFileConversionStarted(analytics: AnalyticsTracking, source: String, fileType: String?) {
        var props: [String: Any] = ["source": source]
        if let fileType = fileType {
            props["file_type"] = fileType
        }
        analytics.capture("file_conversion_started", properties: props)
    }

    func trackFileConversionResult(
        analytics: AnalyticsTracking,
        source: String,
        result: String,
        failureCategory: String?,
        durationMs: Int?
    ) {
        var props: [String: Any] = [
            "source": source,
            "result": result
        ]
        if let failureCategory = failureCategory {
            props["failure_category"] = failureCategory
        }
        if let durationMs = durationMs {
            props["duration_ms"] = durationMs
        }
        analytics.capture("file_conversion_result", properties: props)
    }

    // MARK: - Web Conversion

    func trackWebURLPromptOpened(analytics: AnalyticsTracking) {
        analytics.capture("web_url_prompt_opened", properties: [:])
    }

    func trackWebURLSubmitted(analytics: AnalyticsTracking, hasURL: Bool) {
        analytics.capture("web_url_submitted", properties: ["has_url": hasURL])
    }
}
