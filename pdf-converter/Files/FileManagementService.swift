import Foundation
import Observation

/// Service responsible for managing PDF files and folders, coordinating with local storage and cloud backup.
@Observable
@MainActor
final class FileManagementService {
    // MARK: - Published State

    /// All PDF files in the library, sorted by date (newest first)
    var files: [PDFFile] = []

    /// All folder containers
    var folders: [PDFFolder] = []

    // MARK: - Loading State

    /// Whether a background file operation is in progress
    private(set) var isLoading = false

    /// Tracks whether initial file loading has completed
    private(set) var hasLoadedInitialFiles = false

    /// Prevents duplicate cloud restore attempts
    private var hasAttemptedCloudRestore = false

    /// Active page count loading task
    private var pageCountLoadingTask: Task<Void, Never>?
    private let metadataActor = PDFMetadataActor()

    // MARK: - Dependencies

    /// Cloud backup manager for sync operations
    private let cloudBackup: CloudBackupManager

    /// Cloud sync status for user feedback (optional)
    private weak var syncStatus: CloudSyncStatus?

    // MARK: - Initialization

    init(cloudBackup: CloudBackupManager = .shared, syncStatus: CloudSyncStatus? = nil) {
        self.cloudBackup = cloudBackup
        self.syncStatus = syncStatus
    }

    /// Sets the sync status reporter (called after initialization)
    func setSyncStatus(_ status: CloudSyncStatus?) {
        self.syncStatus = status
    }

    nonisolated deinit {
        // Note: Cannot access @MainActor properties from deinit
        // Task cancellation will happen when instance is deallocated
    }

    // MARK: - Lifecycle

    /// Loads all PDF files from disk on first launch
    func loadInitialFiles() async {
        guard !hasLoadedInitialFiles else { return }
        hasLoadedInitialFiles = true
        await refreshFromDisk()
    }

    /// Reloads all files and folders from disk, updating the in-memory arrays
    func refreshFromDisk() async {
        isLoading = true
        defer { isLoading = false }

        // Cancel any existing page count loading task
        pageCountLoadingTask?.cancel()

        let loadedFiles = await PDFStorage.loadSavedFiles().sorted { $0.date > $1.date }
        files = loadedFiles
        folders = PDFStorage.loadFolders()

        // Start loading page counts in the background
        // As each page count loads, update the corresponding file
        pageCountLoadingTask = Task {
            for file in loadedFiles {
                // Check for cancellation before each file
                guard !Task.isCancelled else { return }

                let fileURL = file.url
                let fileStableID = file.stableID

                // Compute page count off-main via a background actor to avoid UI stalls.
                let pageCount = await metadataActor.pageCount(for: fileURL)

                // Check again after computation
                guard !Task.isCancelled else { return }

                // Update UI state on MainActor, validating stableID to avoid races.
                if let index = files.firstIndex(where: { $0.stableID == fileStableID }),
                   files[index].stableID == fileStableID {
                    let current = files[index]
                    files[index] = PDFFile(
                        url: current.url,
                        name: current.name,
                        date: current.date,
                        pageCount: pageCount,
                        fileSize: current.fileSize,
                        folderId: current.folderId,
                        stableID: current.stableID  // Preserve stable ID
                    )
                }
            }
        }
    }

    /// Fetches any remote backups and merges them into the local library once
    func attemptCloudRestore() async {
        guard !hasAttemptedCloudRestore else { return }
        hasAttemptedCloudRestore = true

        #if DEBUG
        // DIAGNOSTIC: Check CloudKit environment and records
        await cloudBackup.printEnvironmentDiagnostics()
        #endif

        // Restore folders
        let existingFolderIds = Set(PDFStorage.loadFolders().map { $0.id })
        let restoredFolders = await cloudBackup.restoreMissingFolders(existingFolderIds: existingFolderIds)
        if !restoredFolders.isEmpty {
            var folders = PDFStorage.loadFolders()
            folders.append(contentsOf: restoredFolders)
            PDFStorage.saveFolders(folders)
        }

        // Restore files
        let existingRecordIDs = Set(files.map(\.stableID)) // Stable IDs drive CloudKit record identity.
        let restored = await cloudBackup.restoreMissingFiles(existingRecordNames: existingRecordIDs)
        guard !restored.isEmpty else { return }

        // Get file-folder mappings from CloudKit
        let mappings = await cloudBackup.getFileFolderMappings()

        // Apply folder mappings to restored files
        let restoredWithFolders = restored.map { file -> PDFFile in
            let folderId = mappings[file.stableID] // Use recordName == stableID for mappings.
            return PDFFile(
                url: file.url,
                name: file.name,
                date: file.date,
                pageCount: file.pageCount,
                fileSize: file.fileSize,
                folderId: folderId,
                stableID: file.stableID  // Preserve stable ID
            )
        }

        // Save folder mappings for restored files
        for file in restoredWithFolders {
            if let folderId = file.folderId {
                PDFStorage.updateFileFolderId(file: file, folderId: folderId)
            }
        }

        files.append(contentsOf: restoredWithFolders)
        files.sort { $0.date > $1.date }
    }

    // MARK: - File Operations

    /// Saves a scanned document to permanent storage and inserts it at the top of the file list
    /// - Parameter document: The scanned document to save
    /// - Returns: The saved PDFFile
    /// - Throws: If the save operation fails
    func saveScannedDocument(_ document: ScannedDocument) throws -> PDFFile {
        let savedFile = try PDFStorage.save(document: document)
        files.insert(savedFile, at: 0)

        // Compute page count asynchronously for the new file
        Task {
            let fileURL = savedFile.url
            let fileStableID = savedFile.stableID

            // Compute page count off-main via a background actor
            let pageCount = await metadataActor.pageCount(for: fileURL)

            // Update the file with the computed page count
            if let index = files.firstIndex(where: { $0.stableID == fileStableID }) {
                let current = files[index]
                files[index] = PDFFile(
                    url: current.url,
                    name: current.name,
                    date: current.date,
                    pageCount: pageCount,
                    fileSize: current.fileSize,
                    folderId: current.folderId,
                    stableID: current.stableID
                )
            }
        }

        // Trigger cloud backup asynchronously
        Task {
            await backupToCloud(savedFile)
        }

        return savedFile
    }

    /// Imports PDF documents from external URLs into the app's storage
    /// - Parameter urls: The file URLs to import
    /// - Returns: Array of imported PDFFile instances
    /// - Throws: If the import operation fails
    func importDocuments(at urls: [URL]) throws -> [PDFFile] {
        let imported = try PDFStorage.importDocuments(at: urls)

        // Merge new files and keep list sorted by date desc
        files.append(contentsOf: imported)
        files.sort { $0.date > $1.date }

        // Compute page counts asynchronously for imported files
        Task {
            for file in imported {
                let fileURL = file.url
                let fileStableID = file.stableID

                // Compute page count off-main via a background actor
                let pageCount = await metadataActor.pageCount(for: fileURL)

                // Update the file with the computed page count
                if let index = files.firstIndex(where: { $0.stableID == fileStableID }) {
                    let current = files[index]
                    files[index] = PDFFile(
                        url: current.url,
                        name: current.name,
                        date: current.date,
                        pageCount: pageCount,
                        fileSize: current.fileSize,
                        folderId: current.folderId,
                        stableID: current.stableID
                    )
                }
            }
        }

        // Trigger cloud backup asynchronously
        Task {
            await backupToCloud(imported)
        }

        return imported
    }

    /// Renames a PDF file on disk and updates the in-memory representation
    /// - Parameters:
    ///   - file: The file to rename
    ///   - newName: The new name (without extension)
    /// - Returns: The renamed PDFFile
    /// - Throws: If the rename operation fails
    func renameFile(_ file: PDFFile, to newName: String) throws -> PDFFile {
        let renamed = try PDFStorage.rename(file: file, to: newName)

        // Update the local array
        if let index = files.firstIndex(where: { $0.url == file.url }) {
            files[index] = renamed
        }

        // Update cloud: same recordName (stableID) with new metadata.
        Task {
            await backupToCloud(renamed)
        }

        return renamed
    }

    /// Deletes a PDF file from both disk and the in-memory list
    /// - Parameter file: The file to delete
    /// - Throws: If the deletion fails
    func deleteFile(_ file: PDFFile) throws {
        try PDFStorage.delete(file: file)
        files.removeAll { $0.url == file.url }

        // Delete from cloud
        Task {
            await cloudBackup.deleteBackup(for: file)
        }
    }

    /// Returns the file URL for sharing (already persisted files share their existing URL)
    /// - Parameter file: The file to share
    /// - Returns: The file's URL
    func shareFile(_ file: PDFFile) -> URL {
        return file.url
    }

    /// Prepares a temporary share URL for a scanned document
    /// - Parameter document: The scanned document to share
    /// - Returns: The temporary share URL
    /// - Throws: If preparing the share URL fails
    func prepareShareURL(for document: ScannedDocument) throws -> URL {
        return try PDFStorage.prepareShareURL(for: document)
    }

    // MARK: - Folder Operations

    /// Deletes a folder and all its files from storage
    /// - Parameter folder: The folder to delete
    func deleteFolder(_ folder: PDFFolder) {
        // Get all files in the folder before deletion
        let filesInFolder = files.filter { $0.folderId == folder.id }

        // Delete each file
        for file in filesInFolder {
            try? PDFStorage.delete(file: file)
        }

        // Remove files from the array
        files.removeAll { $0.folderId == folder.id }

        // Remove the folder
        folders.removeAll { $0.id == folder.id }

        // Save updated folders list
        saveFolders()

        // Delete from CloudKit
        Task {
            await cloudBackup.deleteFolder(folder)
            // Also delete all files in the folder from CloudKit
            for file in filesInFolder {
                await cloudBackup.deleteBackup(for: file)
            }
        }
    }

    /// Persists the current folders array to disk
    func saveFolders() {
        PDFStorage.saveFolders(folders)
    }

    // MARK: - Cloud Sync

    /// Backs up a single file to CloudKit
    private func backupToCloud(_ file: PDFFile) async {
        await cloudBackup.backup(file: file, syncStatus: syncStatus)
    }

    /// Backs up multiple files to CloudKit
    private func backupToCloud(_ files: [PDFFile]) async {
        await cloudBackup.backup(files: files, syncStatus: syncStatus)
    }

    /// Deletes a file's cloud backup
    private func deleteFromCloud(_ file: PDFFile) async {
        await cloudBackup.deleteBackup(for: file)
    }
}
