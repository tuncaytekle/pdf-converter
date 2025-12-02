import Foundation
import CloudKit

/// Handles uploading and restoring PDFs via the user's private CloudKit database.
actor CloudBackupManager {
    static let shared = CloudBackupManager()

    private let container: CKContainer?
    private let database: CKDatabase?
    private let recordType = "PDFDocument"
    private let folderRecordType = "PDFFolder"
    private var cachedAccountStatus: CKAccountStatus?
    private static let containerIDKey = "CloudKitContainerIdentifier"

    private init() {
        // Try to get custom container identifier from Info.plist
        if let identifier = Bundle.main.object(forInfoDictionaryKey: Self.containerIDKey) as? String,
           !identifier.isEmpty {
            let container = CKContainer(identifier: identifier)
            self.container = container
            self.database = container.privateCloudDatabase
        } else {
            // Use default container (configured via Signing & Capabilities)
            let container = CKContainer.default()
            self.container = container
            self.database = container.privateCloudDatabase
        }
    }

    /// Uploads a PDF and its metadata to CloudKit.
    func backup(file: PDFFile) async {
        await backup(files: [file])
    }

    /// Uploads multiple PDFs sequentially.
    func backup(files: [PDFFile]) async {
        guard await isCloudAvailable(), let database else {
#if DEBUG
            print("☁️ Cloud backup skipped: iCloud not available or not signed in")
#endif
            return
        }
#if DEBUG
        print("☁️ Starting cloud backup for \(files.count) file(s)")
#endif
        for file in files {
            guard FileManager.default.fileExists(atPath: file.url.path) else { continue }
            do {
                let recordID = await CKRecord.ID(recordName: CloudRecordNaming.recordName(for: file.url.lastPathComponent))
                let record = try await existingRecord(with: recordID) ?? CKRecord(recordType: recordType, recordID: recordID)
                await record[CloudRecordKey.fileName] = file.url.lastPathComponent as NSString
                await record[CloudRecordKey.displayName] = file.name as NSString
                await record[CloudRecordKey.modifiedAt] = file.date as NSDate
                await record[CloudRecordKey.fileSize] = NSNumber(value: file.fileSize)
                await record[CloudRecordKey.pageCount] = NSNumber(value: file.pageCount)
                await record[CloudRecordKey.fileAsset] = CKAsset(fileURL: file.url)
                if let folderId = file.folderId {
                    await record[CloudRecordKey.folderId] = folderId as NSString
                } else {
                    await record[CloudRecordKey.folderId] = nil
                }
                _ = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                )
#if DEBUG
                print("☁️ Successfully backed up: \(file.name)")
#endif
            } catch {
#if DEBUG
                print("☁️ Cloud backup failed for \(file.name): \(error)")
#endif
            }
        }
    }

    /// Removes the remote copy for a specific file.
    func deleteBackup(for file: PDFFile) async {
        await deleteRecord(named: CloudRecordNaming.recordName(for: file.url.lastPathComponent))
    }

    /// Removes a record by name (used when renaming files).
    func deleteRecord(named recordName: String) async {
        guard await isCloudAvailable(), let database else { return }
        do {
            try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName))
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted—safe to ignore.
        } catch {
#if DEBUG
            print("Cloud delete failed for \(recordName): \(error)")
#endif
        }
    }

    /// Downloads any PDFs that do not yet exist on disk.
    func restoreMissingFiles(existingRecordNames: Set<String>) async -> [PDFFile] {
        guard await isCloudAvailable(), database != nil else {
#if DEBUG
            print("☁️ File restore skipped: iCloud not available")
#endif
            return []
        }

#if DEBUG
        print("☁️ Starting file restore check (existing files: \(existingRecordNames.count))")
#endif

        do {
            let records = try await fetchAllRecords()
#if DEBUG
            print("☁️ Found \(records.count) file record(s) in CloudKit")
#endif
            var restored: [PDFFile] = []

            for record in records {
                let recordName = record.recordID.recordName
                guard !existingRecordNames.contains(recordName) else {
#if DEBUG
                    print("☁️ Skipping existing file: \(recordName)")
#endif
                    continue
                }
#if DEBUG
                print("☁️ Restoring missing file: \(recordName)")
#endif
                guard let asset = await record[CloudRecordKey.fileAsset] as? CKAsset,
                      let assetURL = asset.fileURL else {
#if DEBUG
                    print("☁️ No asset found for record: \(recordName)")
#endif
                    continue
                }
                let preferredName = await (record[CloudRecordKey.fileName] as? String) ?? "PDF-\(UUID().uuidString)"
                if let stored = try? await PDFStorage.storeCloudAsset(from: assetURL, preferredName: preferredName) {
                    restored.append(stored)
#if DEBUG
                    print("☁️ Successfully restored: \(preferredName)")
#endif
                } else {
#if DEBUG
                    print("☁️ Failed to store asset for: \(preferredName)")
#endif
                }
            }

#if DEBUG
            print("☁️ File restore complete: \(restored.count) file(s) restored")
#endif
            return restored
        } catch {
#if DEBUG
            print("☁️ File restore failed: \(error)")
#endif
            return []
        }
    }

    // MARK: - Folder Operations

    /// Uploads a folder to CloudKit.
    func backupFolder(_ folder: PDFFolder) async {
        await backupFolders([folder])
    }

    /// Uploads multiple folders sequentially.
    func backupFolders(_ folders: [PDFFolder]) async {
        guard await isCloudAvailable(), let database else {
#if DEBUG
            print("☁️ Folder backup skipped: iCloud not available or not signed in")
#endif
            return
        }
#if DEBUG
        print("☁️ Starting folder backup for \(folders.count) folder(s)")
#endif
        for folder in folders {
            do {
                let recordID = CKRecord.ID(recordName: "folder-\(folder.id)")
                let record = try await existingRecord(with: recordID) ?? CKRecord(recordType: folderRecordType, recordID: recordID)
                await record[CloudRecordKey.folderName] = folder.name as NSString
                await record[CloudRecordKey.folderCreatedDate] = folder.createdDate as NSDate
                _ = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                )
#if DEBUG
                print("☁️ Successfully backed up folder: \(folder.name)")
#endif
            } catch {
#if DEBUG
                print("☁️ Folder backup failed for \(folder.name): \(error)")
#endif
            }
        }
    }

    /// Removes the remote copy for a specific folder.
    func deleteFolder(_ folder: PDFFolder) async {
        guard await isCloudAvailable(), let database else { return }
        do {
            try await database.deleteRecord(withID: CKRecord.ID(recordName: "folder-\(folder.id)"))
        } catch let error as CKError where error.code == .unknownItem {
            // Already deleted—safe to ignore.
        } catch {
#if DEBUG
            print("Cloud folder delete failed for \(folder.id): \(error)")
#endif
        }
    }

    /// Downloads any folders that do not yet exist locally.
    func restoreMissingFolders(existingFolderIds: Set<String>) async -> [PDFFolder] {
        guard await isCloudAvailable(), let database else {
#if DEBUG
            print("☁️ Folder restore skipped: iCloud not available")
#endif
            return []
        }

#if DEBUG
        print("☁️ Starting folder restore check (existing folders: \(existingFolderIds.count))")
#endif

        do {
            let records = try await fetchAllFolderRecords()
#if DEBUG
            print("☁️ Found \(records.count) folder record(s) in CloudKit")
#endif
            var restored: [PDFFolder] = []

            for record in records {
                let folderId = record.recordID.recordName.replacingOccurrences(of: "folder-", with: "")
                guard !existingFolderIds.contains(folderId) else {
#if DEBUG
                    print("☁️ Skipping existing folder: \(folderId)")
#endif
                    continue
                }

                if let name = await record[CloudRecordKey.folderName] as? String,
                   let createdDate = await record[CloudRecordKey.folderCreatedDate] as? Date {
                    let folder = PDFFolder(id: folderId, name: name, createdDate: createdDate)
                    restored.append(folder)
#if DEBUG
                    print("☁️ Successfully restored folder: \(name)")
#endif
                } else {
#if DEBUG
                    print("☁️ Missing fields for folder: \(folderId)")
#endif
                }
            }

#if DEBUG
            print("☁️ Folder restore complete: \(restored.count) folder(s) restored")
#endif
            return restored
        } catch {
#if DEBUG
            print("☁️ Folder restore failed: \(error)")
#endif
            return []
        }
    }

    /// Updates file-folder mappings after restore.
    func getFileFolderMappings() async -> [String: String] {
        guard await isCloudAvailable() else { return [:] }

        do {
            let records = try await fetchAllRecords()
            var mappings: [String: String] = [:]

            for record in records {
                if let fileName = await record[CloudRecordKey.fileName] as? String,
                   let folderId = await record[CloudRecordKey.folderId] as? String {
                    mappings[fileName] = folderId
                }
            }

            return mappings
        } catch {
#if DEBUG
            print("Cloud file-folder mapping fetch failed: \(error)")
#endif
            return [:]
        }
    }

    // MARK: - Diagnostic Methods

    /// Fetches all records without using queries (doesn't require indexes)
    /// This is for diagnostic purposes to verify records exist
    func fetchAllRecordsWithoutQuery() async -> (files: Int, folders: Int) {
        guard let database else {
#if DEBUG
            print("🔍 Diagnostic: No database")
#endif
            return (0, 0)
        }

#if DEBUG
        print("🔍 DIAGNOSTIC: Fetching records without query (no indexes needed)...")
#endif

        return await withCheckedContinuation { continuation in
            var fileCount = 0
            var folderCount = 0
            var isFinished = false

            let zoneID = CKRecordZone.default().zoneID
            let operation = CKFetchRecordZoneChangesOperation(
                recordZoneIDs: [zoneID],
                configurationsByRecordZoneID: [zoneID: CKFetchRecordZoneChangesOperation.ZoneConfiguration()]
            )

            operation.recordWasChangedBlock = { recordID, result in
                switch result {
                case .success(let record):
                    if record.recordType == self.recordType {
                        fileCount += 1
#if DEBUG
                        print("🔍 Found file record: \(recordID.recordName)")
#endif
                    } else if record.recordType == self.folderRecordType {
                        folderCount += 1
#if DEBUG
                        print("🔍 Found folder record: \(recordID.recordName)")
#endif
                    }
                case .failure(let error):
#if DEBUG
                    print("🔍 Error reading record: \(error)")
#endif
                    break
                }
            }

            operation.recordZoneFetchResultBlock = { zoneID, result in
                if isFinished { return }
                switch result {
                case .success:
#if DEBUG
                    print("🔍 Zone fetch completed successfully")
#endif
                    break
                case .failure(let error):
#if DEBUG
                    print("🔍 Zone fetch failed: \(error)")
#endif
                    break
                }
            }

            operation.fetchRecordZoneChangesResultBlock = { result in
                if isFinished { return }
                isFinished = true
                switch result {
                case .success:
#if DEBUG
                    print("🔍 DIAGNOSTIC COMPLETE: Found \(fileCount) file(s) and \(folderCount) folder(s)")
#endif
                    continuation.resume(returning: (fileCount, folderCount))
                case .failure(let error):
#if DEBUG
                    print("🔍 Fetch failed: \(error)")
#endif
                    continuation.resume(returning: (0, 0))
                }
            }

            database.add(operation)
        }
    }

    // MARK: - Private helpers

    private func isCloudAvailable() async -> Bool {
        guard let container else {
#if DEBUG
            print("☁️ CloudKit container not initialized")
#endif
            return false
        }
        if let cached = cachedAccountStatus {
#if DEBUG
            if cached != .available {
                print("☁️ iCloud status (cached): \(cached.rawValue) - Not available")
            }
#endif
            return cached == .available
        }

        do {
            let status = try await container.accountStatus()
            cachedAccountStatus = status
#if DEBUG
            print("☁️ iCloud account status: \(status.rawValue)")
            switch status {
            case .available:
                print("☁️ iCloud is available and ready")
            case .noAccount:
                print("☁️ No iCloud account - Please sign in with Apple ID in Settings")
            case .restricted:
                print("☁️ iCloud is restricted on this device")
            case .couldNotDetermine:
                print("☁️ Could not determine iCloud status")
            case .temporarilyUnavailable:
                print("☁️ iCloud temporarily unavailable")
            @unknown default:
                print("☁️ Unknown iCloud status")
            }
#endif
            return status == .available
        } catch {
#if DEBUG
            print("☁️ iCloud account status check failed: \(error)")
#endif
            return false
        }
    }

    private func existingRecord(with id: CKRecord.ID) async throws -> CKRecord? {
        guard let database else { throw CloudBackupError.unavailable }
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    private func fetchAllRecords() async throws -> [CKRecord] {
        guard let database else { throw CloudBackupError.unavailable }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            var fetched: [CKRecord] = []
            var didFinish = false

            func run(with cursor: CKQueryOperation.Cursor?) {
                let operation: CKQueryOperation
                if let cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
                    query.sortDescriptors = [NSSortDescriptor(key: "createdTimestamp", ascending: false)]
                    operation = CKQueryOperation(query: query)
                }

                operation.qualityOfService = .userInitiated
                operation.recordMatchedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        fetched.append(record)
                    case .failure:
                        break
                    }
                }
                operation.queryResultBlock = { result in
                    if didFinish { return }
                    switch result {
                    case .failure(let error):
                        didFinish = true
                        // If schema is not configured yet, return empty array
                        // This happens on first install before any records are created
                        if let ckError = error as? CKError, ckError.code == .invalidArguments {
                            continuation.resume(returning: [])
                        } else {
                            continuation.resume(throwing: error)
                        }
                    case .success(let cursor):
                        if let cursor {
                            run(with: cursor)
                        } else {
                            didFinish = true
                            continuation.resume(returning: fetched)
                        }
                    }
                }
                database.add(operation)
            }

            run(with: nil)
        }
    }

    private func fetchAllFolderRecords() async throws -> [CKRecord] {
        guard let database else { throw CloudBackupError.unavailable }

        // Use fetchAllRecordZones approach to avoid queryable index requirement
        // This queries by a sortable field that CloudKit automatically indexes
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CKRecord], Error>) in
            var fetched: [CKRecord] = []
            var didFinish = false

            func run(with cursor: CKQueryOperation.Cursor?) {
                let operation: CKQueryOperation
                if let cursor {
                    operation = CKQueryOperation(cursor: cursor)
                } else {
                    // Query with TRUEPREDICATE requires queryable indexes
                    // Instead, use a query that sorts by createdTimestamp (system field, always indexed)
                    let query = CKQuery(recordType: folderRecordType, predicate: NSPredicate(value: true))
                    query.sortDescriptors = [NSSortDescriptor(key: "createdTimestamp", ascending: false)]
                    operation = CKQueryOperation(query: query)
                }

                operation.qualityOfService = .userInitiated
                operation.recordMatchedBlock = { _, result in
                    switch result {
                    case .success(let record):
                        fetched.append(record)
                    case .failure:
                        break
                    }
                }
                operation.queryResultBlock = { result in
                    if didFinish { return }
                    switch result {
                    case .failure(let error):
                        didFinish = true
                        // If still getting queryable error, return empty array
                        // This means no records exist yet or schema not configured
                        if let ckError = error as? CKError, ckError.code == .invalidArguments {
                            continuation.resume(returning: [])
                        } else {
                            continuation.resume(throwing: error)
                        }
                    case .success(let cursor):
                        if let cursor {
                            run(with: cursor)
                        } else {
                            didFinish = true
                            continuation.resume(returning: fetched)
                        }
                    }
                }
                database.add(operation)
            }

            run(with: nil)
        }
    }
}

private enum CloudRecordKey {
    static let fileName = "fileName"
    static let displayName = "displayName"
    static let modifiedAt = "modifiedAt"
    static let fileSize = "fileSize"
    static let pageCount = "pageCount"
    static let fileAsset = "file"
    static let folderId = "folderId"

    // Folder record keys
    static let folderName = "folderName"
    static let folderCreatedDate = "folderCreatedDate"
}

struct CloudRecordNaming {
    static func recordName(for fileName: String) -> String {
        let sanitized = fileName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return sanitized
    }
}

private enum CloudBackupError: Error {
    case unavailable
}
