import Foundation
import SwiftUI
import Combine

/// Manages cloud sync status and provides user-visible feedback
final class CloudSyncStatus: ObservableObject {
    enum State: Equatable {
        case idle
        case syncing(fileCount: Int)
        case success(message: String)
        case error(message: String)
        case unavailable(reason: String)
    }

    /// Current sync state
    @Published var state: State = .idle

    /// Last successful sync timestamp
    @Published var lastSyncDate: Date?

    /// Per-file sync status tracking
    @Published var fileSyncStatus: [URL: FileSyncState] = [:]

    /// Auto-dismiss task for success messages
    private var dismissTask: Task<Void, Never>?

    enum FileSyncState: Equatable {
        case synced
        case syncing
        case failed(error: String)
    }

    // MARK: - Global Status Updates

    @MainActor
    func setSyncing(count: Int) {
        state = .syncing(fileCount: count)
    }

    @MainActor
    func setSuccess(_ message: String, autoDismiss: Bool = true) {
        state = .success(message: message)
        lastSyncDate = Date()
        if autoDismiss {
            scheduleDismiss()
        }
    }

    @MainActor
    func setError(_ message: String) {
        state = .error(message: message)
        // Don't auto-dismiss errors - user needs to see them
    }

    @MainActor
    func setUnavailable(_ reason: String) {
        state = .unavailable(reason: reason)
    }

    @MainActor
    func dismiss() {
        dismissTask?.cancel()
        state = .idle
    }

    @MainActor
    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            if !Task.isCancelled {
                state = .idle
            }
        }
    }

    // MARK: - Per-File Status Updates

    @MainActor
    func setFileSyncing(_ url: URL) {
        fileSyncStatus[url] = .syncing
    }

    @MainActor
    func setFileSynced(_ url: URL) {
        fileSyncStatus[url] = .synced
    }

    @MainActor
    func setFileFailed(_ url: URL, error: String) {
        fileSyncStatus[url] = .failed(error: error)
    }

    @MainActor
    func clearFileStatus(_ url: URL) {
        fileSyncStatus.removeValue(forKey: url)
    }

    @MainActor
    func getFileStatus(_ url: URL) -> FileSyncState? {
        return fileSyncStatus[url]
    }
}
