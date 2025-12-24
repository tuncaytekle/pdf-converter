//
//  ToolsViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class ToolsViewModel: ObservableObject {
    func trackToolCardTapped(analytics: AnalyticsTracking, tool: ToolAction) {
        let toolName: String
        switch tool {
        case .convertFiles:
            toolName = "convert_files"
        case .scanDocuments:
            toolName = "scan_documents"
        case .convertPhotos:
            toolName = "convert_photos"
        case .importDocuments:
            toolName = "import_documents"
        case .convertWebPage:
            toolName = "convert_web"
        case .editDocuments:
            toolName = "edit_documents"
        }

        analytics.capture("tool_card_tapped", properties: ["tool": toolName])
    }
}
