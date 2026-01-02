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

    /// Optional PDF Gateway client for web and office document conversions
    private let pdfGatewayClient: PDFGatewayClient?

    /// File service for final document persistence
    private let fileService: FileManagementService

    // MARK: - Initialization

    init(
        pdfGatewayClient: PDFGatewayClient?,
        fileService: FileManagementService
    ) {
        self.pdfGatewayClient = pdfGatewayClient
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

    /// Converts a local document into a PDF using the PDF Gateway
    /// - Parameter url: The document file URL to convert
    /// - Returns: A scanned document ready for review
    /// - Throws: ScanWorkflowError if the conversion fails or service is unavailable
    func convertFileUsingLibreOffice(url: URL, progressHandler: ((String) -> Void)? = nil) async throws -> ScannedDocument {
        guard let client = pdfGatewayClient else {
            throw ScanWorkflowError.unavailable
        }

        isConverting = true
        defer {
            isConverting = false
            conversionProgress = nil
        }

        do {
            let filename = url.lastPathComponent
            let baseName = url.deletingPathExtension().lastPathComponent

            // Request security-scoped access to the file (required on real devices)
            let canAccess = url.startAccessingSecurityScopedResource()
            defer {
                if canAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            // Check for cancellation before network call
            try Task.checkCancellation()

            // Convert file to PDF via gateway with progress tracking
            let result = try await client.convert(fileURL: url, filename: filename) { [weak self] phase in
                guard let self = self else { return }
                switch phase {
                case .uploading:
                    self.conversionProgress = NSLocalizedString("conversion.uploading", comment: "Uploading file")
                    progressHandler?(self.conversionProgress!)
                case .converting:
                    self.conversionProgress = NSLocalizedString("conversion.processing", comment: "Converting file")
                    progressHandler?(self.conversionProgress!)
                }
            }

            // Check for cancellation after conversion
            try Task.checkCancellation()

            // Downloading result
            conversionProgress = NSLocalizedString("conversion.downloading", comment: "Downloading PDF")
            progressHandler?(conversionProgress!)

            let pdfData = try await downloadPDF(from: result.downloadURL)

            // Check for cancellation after download
            try Task.checkCancellation()

            let outputURL = try persistPDFData(pdfData)

            return ScannedDocument(
                pdfURL: outputURL,
                fileName: String(format: NSLocalizedString("converted.fileNameFormat", comment: "Converted file name format"), baseName)
            )
        } catch is CancellationError {
            throw ScanWorkflowError.cancelled
        } catch let error as PDFGatewayError {
            print("❌ PDF Gateway error: \(error.localizedDescription)")
            throw ScanWorkflowError.failed(error.localizedDescription)
        } catch {
            print("❌ File conversion error: \(error)")
            throw ScanWorkflowError.failed(error.localizedDescription)
        }
    }

    /// Sends a URL to the PDF Gateway for conversion
    /// - Parameter url: The web URL to convert
    /// - Returns: A scanned document ready for review
    /// - Throws: ScanWorkflowError if the conversion fails or service is unavailable
    func convertWebPage(url: URL, progressHandler: ((String) -> Void)? = nil) async throws -> ScannedDocument {
        guard let client = pdfGatewayClient else {
            throw ScanWorkflowError.unavailable
        }

        let host = url.host?
            .replacingOccurrences(of: "www.", with: "", options: [.caseInsensitive, .anchored])
            ?? NSLocalizedString("webPrompt.defaultName", comment: "Default web host name")

        do {
            // Check for cancellation before network call
            try Task.checkCancellation()

            // Convert URL to PDF via gateway with progress tracking
            let result = try await client.convert(publicURL: url) { [weak self] phase in
                guard let self = self else { return }
                switch phase {
                case .uploading:
                    break // URL conversions don't upload
                case .converting:
                    self.conversionProgress = NSLocalizedString("conversion.processing", comment: "Converting page")
                    progressHandler?(self.conversionProgress!)
                }
            }

            // Check for cancellation after conversion
            try Task.checkCancellation()

            // Downloading result
            conversionProgress = NSLocalizedString("conversion.downloading", comment: "Downloading PDF")
            progressHandler?(conversionProgress!)

            let pdfData = try await downloadPDF(from: result.downloadURL)

            // Check for cancellation after download
            try Task.checkCancellation()

            let outputURL = try persistPDFData(pdfData)

            return ScannedDocument(
                pdfURL: outputURL,
                fileName: defaultFileName(prefix: host)
            )
        } catch let error as PDFGatewayError {
            throw ScanWorkflowError.failed(error.localizedDescription)
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
        PDFStorage.deleteTemporaryFile(at: url)
    }

    // MARK: - Private Helpers

    /// Downloads a PDF from a signed URL (returned by the gateway)
    /// - Parameter url: The signed download URL
    /// - Returns: The PDF data
    /// - Throws: Error if download fails
    private func downloadPDF(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ScanWorkflowError.failed("Invalid response from server")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw ScanWorkflowError.failed("Download failed with status \(httpResponse.statusCode)")
        }

        return data
    }

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
