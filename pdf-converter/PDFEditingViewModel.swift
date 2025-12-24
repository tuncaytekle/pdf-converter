//
//  PDFEditingViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class PDFEditingViewModel: ObservableObject {
    private var didTrackEditStart = false
    private var didDrawSignature = false

    let fileId: String
    let hasExistingSignature: Bool

    init(fileId: String, hasExistingSignature: Bool) {
        self.fileId = fileId
        self.hasExistingSignature = hasExistingSignature
    }

    func trackEditStarted(analytics: AnalyticsTracking) {
        guard !didTrackEditStart else { return }
        didTrackEditStart = true

        analytics.capture("pdf_edit_started", properties: [
            "file_id": fileId,
            "has_existing_signature": hasExistingSignature
        ])

        analytics.screen("PDF Editor", properties: ["file_id": fileId])
    }

    func trackSignatureDrawStarted(analytics: AnalyticsTracking) {
        guard !didDrawSignature else { return }
        didDrawSignature = true

        analytics.capture("signature_draw_started", properties: [:])
    }

    func trackSignatureSaved(analytics: AnalyticsTracking) {
        analytics.capture("signature_saved", properties: [:])
    }

    func trackSignaturePlaced(analytics: AnalyticsTracking, page: Int) {
        analytics.capture("signature_placed", properties: ["page": page])
    }

    func trackEditSaved(analytics: AnalyticsTracking, signatureAdded: Bool) {
        guard didTrackEditStart else { return }

        analytics.capture("pdf_edit_saved", properties: [
            "file_id": fileId,
            "signature_added": signatureAdded
        ])
    }

    func trackEditCancelled(analytics: AnalyticsTracking) {
        guard didTrackEditStart else { return }

        analytics.capture("pdf_edit_cancelled", properties: ["file_id": fileId])
    }
}
