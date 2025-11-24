import Foundation
import CloudKit

/// Handles uploading and restoring PDFs via the user's private CloudKit database.
actor CloudBackupManager {
    static let shared = CloudBackupManager()

    private let container: CKContainer?
    private let database: CKDatabase?
    private let recordType = "PDFDocument"
    private var cachedAccountStatus: CKAccountStatus?
    private static let containerIDKey = "CloudKitContainerIdentifier"

    private init() {
        if let identifier = Bundle.main.object(forInfoDictionaryKey: Self.containerIDKey) as? String,
           !identifier.isEmpty {
            let container = CKContainer(identifier: identifier)
            self.container = container
            self.database = container.privateCloudDatabase
        } else {
            self.container = nil
            self.database = nil
        }
    }

    /// Uploads a PDF and its metadata to CloudKit.
    func backup(file: PDFFile) async {
        await backup(files: [file])
    }

    /// Uploads multiple PDFs sequentially.
    func backup(files: [PDFFile]) async {
        guard await isCloudAvailable(), let database else { return }
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
                _ = try await database.modifyRecords(
                    saving: [record],
                    deleting: [],
                    savePolicy: .allKeys,
                    atomically: true
                )
            } catch {
#if DEBUG
                print("Cloud backup failed for \(file.name): \(error)")
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
        guard await isCloudAvailable(), database != nil else { return [] }

        do {
            let records = try await fetchAllRecords()
            var restored: [PDFFile] = []

            for record in records {
                let recordName = record.recordID.recordName
                guard !existingRecordNames.contains(recordName) else { continue }
                guard let asset = await record[CloudRecordKey.fileAsset] as? CKAsset,
                      let assetURL = asset.fileURL else { continue }
                let preferredName = await (record[CloudRecordKey.fileName] as? String) ?? "PDF-\(UUID().uuidString)"
                if let stored = try? await PDFStorage.storeCloudAsset(from: assetURL, preferredName: preferredName) {
                    restored.append(stored)
                }
            }

            return restored
        } catch {
#if DEBUG
            print("Cloud restore failed: \(error)")
#endif
            return []
        }
    }

    // MARK: - Private helpers

    private func isCloudAvailable() async -> Bool {
        guard let container else { return false }
        if let cached = cachedAccountStatus {
            return cached == .available
        }

        do {
            let status = try await container.accountStatus()
            cachedAccountStatus = status
            return status == .available
        } catch {
#if DEBUG
            print("iCloud account status failed: \(error)")
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
                        continuation.resume(throwing: error)
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
