//
//  FileOperationsViewModel.swift
//  pdf-converter
//
//  Created by Claude on 12/24/25.
//

import Foundation
import Combine

@MainActor
final class FileOperationsViewModel: ObservableObject {
    // MARK: - Search

    func trackSearchStarted(analytics: AnalyticsTracking) {
        analytics.capture("search_started", properties: [:])
    }

    func trackSearchCompleted(analytics: AnalyticsTracking, queryLength: Int, resultsCount: Int) {
        analytics.capture("search_completed", properties: [
            "query_length": queryLength,
            "results_count": resultsCount
        ])
    }

    func trackSearchCancelled(analytics: AnalyticsTracking) {
        analytics.capture("search_cancelled", properties: [:])
    }

    // MARK: - Sorting

    func trackFilesSorted(analytics: AnalyticsTracking, sortBy: String, direction: String) {
        analytics.capture("files_sorted", properties: [
            "sort_by": sortBy,
            "direction": direction
        ])
    }

    // MARK: - File Actions

    func trackFilePreviewTapped(analytics: AnalyticsTracking, fileId: String, inFolder: Bool) {
        analytics.capture("file_preview_tapped", properties: [
            "file_id": fileId,
            "in_folder": inFolder
        ])
    }

    func trackFileShareTapped(analytics: AnalyticsTracking, fileId: String, from: String) {
        analytics.capture("file_share_tapped", properties: [
            "file_id": fileId,
            "from": from
        ])
    }

    func trackFileRenameStarted(analytics: AnalyticsTracking, fileId: String) {
        analytics.capture("file_rename_started", properties: ["file_id": fileId])
    }

    func trackFileRenamed(analytics: AnalyticsTracking, fileId: String, nameChanged: Bool) {
        analytics.capture("file_renamed", properties: [
            "file_id": fileId,
            "name_changed": nameChanged
        ])
    }

    func trackFileDeleteTapped(analytics: AnalyticsTracking, fileId: String) {
        analytics.capture("file_delete_tapped", properties: ["file_id": fileId])
    }

    func trackFileDeleted(analytics: AnalyticsTracking, fileId: String) {
        analytics.capture("file_deleted", properties: ["file_id": fileId])
    }

    func trackFileMoveStarted(analytics: AnalyticsTracking, fileId: String) {
        analytics.capture("file_move_started", properties: ["file_id": fileId])
    }

    func trackFileMoved(analytics: AnalyticsTracking, fileId: String, toFolderId: String?) {
        var props: [String: Any] = ["file_id": fileId]
        if let toFolderId = toFolderId {
            props["to_folder_id"] = toFolderId
        }
        analytics.capture("file_moved", properties: props)
    }

    // MARK: - Folder Actions

    func trackFolderCreated(analytics: AnalyticsTracking, nameLength: Int) {
        analytics.capture("folder_created", properties: ["folder_name_length": nameLength])
    }

    func trackFolderOpened(analytics: AnalyticsTracking, folderId: String, fileCount: Int) {
        analytics.capture("folder_opened", properties: [
            "folder_id": folderId,
            "file_count": fileCount
        ])
    }

    func trackFolderBackTapped(analytics: AnalyticsTracking) {
        analytics.capture("folder_back_tapped", properties: [:])
    }

    func trackFolderRenameStarted(analytics: AnalyticsTracking, folderId: String) {
        analytics.capture("folder_rename_started", properties: ["folder_id": folderId])
    }

    func trackFolderRenamed(analytics: AnalyticsTracking, folderId: String) {
        analytics.capture("folder_renamed", properties: ["folder_id": folderId])
    }

    func trackFolderDeleteTapped(analytics: AnalyticsTracking, folderId: String, fileCount: Int) {
        analytics.capture("folder_delete_tapped", properties: [
            "folder_id": folderId,
            "file_count": fileCount
        ])
    }

    func trackFolderDeleted(analytics: AnalyticsTracking, folderId: String, fileCount: Int) {
        analytics.capture("folder_deleted", properties: [
            "folder_id": folderId,
            "file_count": fileCount
        ])
    }

    // MARK: - Import

    func trackFileImportStarted(analytics: AnalyticsTracking) {
        analytics.capture("file_import_started", properties: [:])
    }

    func trackFileImportResult(analytics: AnalyticsTracking, result: String, fileCount: Int?, failureCategory: String?) {
        var props: [String: Any] = ["result": result]
        if let fileCount = fileCount {
            props["file_count"] = fileCount
        }
        if let failureCategory = failureCategory {
            props["failure_category"] = failureCategory
        }
        analytics.capture("file_import_result", properties: props)
    }
}
