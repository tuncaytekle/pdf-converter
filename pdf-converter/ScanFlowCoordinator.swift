import Foundation
import UIKit
import Observation

/// Coordinator responsible for scan workflows, photo picking, and document conversions
@Observable
@MainActor
final class ScanFlowCoordinator {
    // MARK: - Conversion State

    /// Whether a conversion is currently in progress
    private(set) var isConverting = false

    /// Progress message for ongoing conversions
    private(set) var conversionProgress: String?

    // MARK: - Dependencies

    /// Optional Gotenberg client for web and office document conversions
    private let gotenbergClient: GotenbergClient?

    /// File service for final document persistence
    private let fileService: FileManagementService

    // MARK: - Initialization

    init(
        gotenbergClient: GotenbergClient?,
        fileService: FileManagementService
    ) {
        self.gotenbergClient = gotenbergClient
        self.fileService = fileService
    }

    // MARK: - Scan Result Processing

    /// Converts successful scan/photo results into PDFs and returns a scanned document for review
    /// - Parameters:
    ///   - result: The scan result containing images or error
    ///   - suggestedName: Default file name to use
    /// - Returns: A scanned document ready for review
    /// - Throws: ScanWorkflowError if the conversion fails
    func handleScanResult(
        _ result: Result<[UIImage], ScanWorkflowError>,
        suggestedName: String
    ) throws -> ScannedDocument {
        switch result {
        case .success(let images):
            guard !images.isEmpty else {
                throw ScanWorkflowError.noImages
            }

            let pdfURL = try PDFGenerator.makePDF(from: images)
            return ScannedDocument(pdfURL: pdfURL, fileName: suggestedName)

        case .failure(let error):
            // Re-throw the original error
            throw error
        }
    }

    // MARK: - Document Conversions

    /// Converts a local document into a PDF using Gotenberg's LibreOffice route
    /// - Parameter url: The document file URL to convert
    /// - Returns: A scanned document ready for review
    /// - Throws: ScanWorkflowError if the conversion fails or service is unavailable
    func convertFileUsingLibreOffice(url: URL) async throws -> ScannedDocument {
        guard let client = gotenbergClient else {
            throw ScanWorkflowError.unavailable
        }

        isConverting = true
        defer { isConverting = false }

        do {
            let filename = url.lastPathComponent
            let baseName = url.deletingPathExtension().lastPathComponent
            let data = try readDataForSecurityScopedURL(url)

            // Check for cancellation before network call
            try Task.checkCancellation()

            let pdfData = try await client.convertOfficeDocToPDF(
                fileName: filename,
                data: data
            )

            // Check for cancellation after network call
            try Task.checkCancellation()

            let outputURL = try persistPDFData(pdfData)

            return ScannedDocument(
                pdfURL: outputURL,
                fileName: String(format: NSLocalizedString("converted.fileNameFormat", comment: "Converted file name format"), baseName)
            )
        } catch {
            throw ScanWorkflowError.failed(error.localizedDescription)
        }
    }

    /// Sends a URL to Gotenberg's Chromium route and returns the resulting PDF
    /// - Parameter url: The web URL to convert
    /// - Returns: A scanned document ready for review
    /// - Throws: ScanWorkflowError if the conversion fails or service is unavailable
    func convertWebPage(url: URL) async throws -> ScannedDocument {
        guard let client = gotenbergClient else {
            throw ScanWorkflowError.unavailable
        }

        let host = url.host?
            .replacingOccurrences(of: "www.", with: "", options: [.caseInsensitive, .anchored])
            ?? NSLocalizedString("webPrompt.defaultName", comment: "Default web host name")

        do {
            // Check for cancellation before network call
            try Task.checkCancellation()

            let pdfData = try await client.convertURLToPDF(url: url.absoluteString)

            // Check for cancellation after network call
            try Task.checkCancellation()

            let outputURL = try persistPDFData(pdfData)

            return ScannedDocument(
                pdfURL: outputURL,
                fileName: defaultFileName(prefix: host)
            )
        } catch {
            throw ScanWorkflowError.failed(error.localizedDescription)
        }
    }

    /// Validates and normalizes a URL string for web conversion
    /// - Parameter input: The raw URL string from user input
    /// - Returns: A normalized URL if valid, nil otherwise
    func normalizeWebURL(from input: String) -> URL? {
        var candidate = input
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        if components.scheme == nil || components.scheme?.isEmpty == true {
            components.scheme = "https"
        }

        guard let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.url
    }

    // MARK: - Helpers

    /// Builds a human-friendly default file name using the date and supplied prefix
    /// - Parameter prefix: The prefix to use (e.g., "Scan", "Photos")
    /// - Returns: A formatted file name with timestamp
    func defaultFileName(prefix: String) -> String {
        let timestamp = Self.fileNameFormatter.string(from: Date())
        return "\(prefix) \(timestamp)"
    }

    /// Deletes the temporary PDF sitting in `/tmp` once we no longer need it
    /// - Parameter url: The URL of the temporary file to delete
    func cleanupTemporaryFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Private Helpers

    /// Writes raw PDF data to a temporary location we can hand to the review sheet
    private func persistPDFData(_ data: Data) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Reads data from a potentially security-scoped URL
    private func readDataForSecurityScopedURL(_ url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    /// Date formatter for generating default file names
    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
