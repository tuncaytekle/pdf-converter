//
//  ScanReviewViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class ScanReviewViewModel: ObservableObject {
    private var didTrackView = false
    private var reviewStart: Date?

    let source: String
    let pageCount: Int

    init(source: String, pageCount: Int) {
        self.source = source
        self.pageCount = pageCount
    }

    func trackReviewViewed(analytics: AnalyticsTracking) {
        guard !didTrackView else { return }
        didTrackView = true
        reviewStart = Date()

        let props: [String: Any] = [
            "source": source,
            "page_count": pageCount
        ]

        analytics.capture("scan_review_viewed", properties: props)
        analytics.screen("Scan Review", properties: props)
    }

    func trackShareTapped(analytics: AnalyticsTracking) {
        analytics.capture("scan_review_share_tapped", properties: [
            "source": source,
            "page_count": pageCount
        ])
    }

    func trackSaveTapped(analytics: AnalyticsTracking, fileNameChanged: Bool) {
        analytics.capture("scan_review_save_tapped", properties: [
            "source": source,
            "page_count": pageCount,
            "renamed": fileNameChanged
        ])
    }

    func trackCancelled(analytics: AnalyticsTracking) {
        guard didTrackView else { return }

        analytics.capture("scan_review_cancelled", properties: [
            "source": source
        ])
    }
}
