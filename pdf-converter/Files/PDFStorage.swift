import Foundation
import PDFKit
import OSLog

enum PDFStorage {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.roguewaveapps.pdfconverter",
        category: "Storage"
    )

    static func loadSavedFiles() async -> [PDFFile] {
        guard let directory = documentsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

        // Load files quickly without computing page counts
        // Page counts will be loaded lazily via PageCountCache
        return pdfs.compactMap { url in
            loadPDFFileMetadataFast(url: url)
        }
    }

    // Fast metadata loading without parsing PDF (no page count)
    private nonisolated static func loadPDFFileMetadataFast(url: URL) -> PDFFile? {
        let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        let size = Int64(resourceValues?.fileSize ?? 0)
        let folderId = loadFileFolderId(for: url)
        let stableID = getOrCreateStableID(for: url)

        // Don't compute page count here - it will be loaded lazily
        return PDFFile(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            date: date,
            pageCount: 0,  // Will be populated lazily by PageCountCache
            fileSize: size,
            folderId: folderId,
            stableID: stableID
        )
    }

    // Asynchronously compute page count for a single PDF (called on-demand)
    nonisolated static func computePageCount(for url: URL) async -> Int {
        guard let document = PDFDocument(url: url) else { return 0 }
        return document.pageCount
    }

    static func save(document: ScannedDocument) throws -> PDFFile {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
        }

        let baseName = sanitizeFileName(document.fileName)
        let destination = uniqueURL(for: baseName, in: directory)

        do {
            try FileManager.default.moveItem(at: document.pdfURL, to: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        let size = Int64(resourceValues?.fileSize ?? 0)
        let pageCount = PDFDocument(url: destination)?.pageCount ?? 0
        let stableID = getOrCreateStableID(for: destination)

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: date,
            pageCount: pageCount,
            fileSize: size,
            folderId: nil,
            stableID: stableID
        )
    }

    static func importDocuments(at urls: [URL]) throws -> [PDFFile] {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
        }

        var imported: [PDFFile] = []

        for sourceURL in urls {
            var didAccess = false
            if sourceURL.startAccessingSecurityScopedResource() {
                didAccess = true
            }
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard sourceURL.pathExtension.lowercased() == "pdf" else { continue }

            let baseName = sanitizeFileName(sourceURL.deletingPathExtension().lastPathComponent)
            let destination = uniqueURL(for: baseName, in: directory)

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let resourceValues = try? destination.resourceValues(forKeys: [.fileSizeKey])
                let date = Date()
                let size = Int64(resourceValues?.fileSize ?? 0)
                let pageCount = PDFDocument(url: destination)?.pageCount ?? 0
                let stableID = getOrCreateStableID(for: destination)
                let file = PDFFile(
                    url: destination,
                    name: destination.deletingPathExtension().lastPathComponent,
                    date: date,
                    pageCount: pageCount,
                    fileSize: size,
                    folderId: nil,
                    stableID: stableID
                )
                imported.append(file)
            } catch {
                throw ScanWorkflowError.underlying(error)
            }
        }

        return imported
    }

    static func rename(file: PDFFile, to newName: String) throws -> PDFFile {
        let sanitized = sanitizeFileName(newName)
        let directory = file.url.deletingLastPathComponent()
        let currentBase = file.url.deletingPathExtension().lastPathComponent

        if currentBase == sanitized {
            return PDFFile(
                url: file.url,
                name: sanitized,
                date: file.date,
                pageCount: file.pageCount,
                fileSize: file.fileSize,
                folderId: file.folderId,
                stableID: file.stableID  // Preserve existing stable ID
            )
        }

        let destination = uniqueURL(for: sanitized, in: directory)

        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
            // Update stable ID mapping to point to new filename
            updateStableIDMapping(oldURL: file.url, newURL: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: file.date,
            pageCount: file.pageCount,
            fileSize: file.fileSize,
            folderId: file.folderId,
            stableID: file.stableID  // Preserve existing stable ID
        )
    }

    static func delete(file: PDFFile) throws {
        try FileManager.default.removeItem(at: file.url)
    }

    static func prepareShareURL(for document: ScannedDocument) throws -> URL {
        let tempDirectory = FileManager.default.temporaryDirectory
        let sanitizedFileName = document.fileName.hasSuffix(".pdf") ? document.fileName : "\(document.fileName).pdf"
        let destination = tempDirectory.appendingPathComponent(sanitizedFileName)

        // Remove existing file if it exists to avoid conflicts
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: document.pdfURL, to: destination)
        return destination
    }

    // MARK: - Folder Management

    static func loadFolders() -> [PDFFolder] {
        guard let url = foldersFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? JSONDecoder().decode([PDFFolder].self, from: data)) ?? []
    }

    static func saveFolders(_ folders: [PDFFolder]) {
        guard let url = foldersFileURL,
              let data = try? JSONEncoder().encode(folders) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func updateFileFolderId(file: PDFFile, folderId: String?) {
        guard let url = fileFoldersFileURL else { return }

        var mapping: [String: String] = [:]

        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            mapping = existing
        }

        let key = file.url.lastPathComponent
        if let folderId = folderId {
            mapping[key] = folderId
        } else {
            mapping.removeValue(forKey: key)
        }

        if let data = try? JSONEncoder().encode(mapping) {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                logger.error("Failed to write folder mapping: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    nonisolated static func loadFileFolderId(for fileURL: URL) -> String? {
        guard let url = fileFoldersFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }

        let key = fileURL.lastPathComponent
        return mapping[key]
    }

    // MARK: - Helpers

    private nonisolated static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func sanitizeFileName(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return NSLocalizedString("Untitled", comment: "Fallback file name") }

        var sanitized = trimmed
        if sanitized.lowercased().hasSuffix(".pdf") {
            sanitized = String(sanitized.dropLast(4))
        }

        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = sanitized.components(separatedBy: invalidCharacters)
        let filtered = components.joined(separator: "-")
        if filtered.lowercased().hasSuffix(".pdf") {
            return String(filtered.dropLast(4))
        }
        return filtered
    }

    private static func uniqueURL(for baseName: String, in directory: URL) -> URL {
        var fileURL = directory.appendingPathComponent(baseName).appendingPathExtension("pdf")
        var attempt = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            let suffix = String(format: " %02d", attempt)
            fileURL = directory.appendingPathComponent(baseName + suffix).appendingPathExtension("pdf")
            attempt += 1
        }
        return fileURL
    }

    private static var foldersFileURL: URL? {
        documentsDirectory()?.appendingPathComponent(".folders.json")
    }

    private nonisolated static var fileFoldersFileURL: URL? {
        documentsDirectory()?.appendingPathComponent(".file_folders.json")
    }

    private nonisolated static var fileStableIDsFileURL: URL? {
        documentsDirectory()?.appendingPathComponent(".file_stable_ids.json")
    }

    // MARK: - Stable ID Management

    /// Get or create a stable UUID for a file
    nonisolated static func getOrCreateStableID(for fileURL: URL) -> String {
        let key = fileURL.lastPathComponent

        // Try to load existing mapping
        if let url = fileStableIDsFileURL,
           FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let mapping = try? JSONDecoder().decode([String: String].self, from: data),
           let existingID = mapping[key] {
            return existingID
        }

        // Generate new UUID for this file
        let newID = UUID().uuidString
        saveStableID(newID, for: fileURL)
        return newID
    }

    /// Save a stable ID for a file
    private nonisolated static func saveStableID(_ stableID: String, for fileURL: URL) {
        guard let url = fileStableIDsFileURL else { return }

        var mapping: [String: String] = [:]
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            mapping = existing
        }

        let key = fileURL.lastPathComponent
        mapping[key] = stableID

        if let data = try? JSONEncoder().encode(mapping) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Update stable ID mapping when a file is renamed
    static func updateStableIDMapping(oldURL: URL, newURL: URL) {
        guard let url = fileStableIDsFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              var mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return
        }

        let oldKey = oldURL.lastPathComponent
        let newKey = newURL.lastPathComponent

        // Move the stable ID to the new filename
        if let stableID = mapping[oldKey] {
            mapping.removeValue(forKey: oldKey)
            mapping[newKey] = stableID

            if let updatedData = try? JSONEncoder().encode(mapping) {
                try? updatedData.write(to: url, options: .atomic)
            }
        }
    }

    static func storeCloudAsset(from sourceURL: URL, preferredName: String, stableID: String) throws -> PDFFile {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
        }

        let baseName = sanitizeFileName(preferredName)
        let destination = uniqueURL(for: baseName, in: directory)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        let size = Int64(resourceValues?.fileSize ?? 0)
        let pageCount = PDFDocument(url: destination)?.pageCount ?? 0
        // Persist the CloudKit record identity so restores don't create duplicates.
        saveStableID(stableID, for: destination)

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: date,
            pageCount: pageCount,
            fileSize: size,
            folderId: nil,
            stableID: stableID
        )
    }
}
