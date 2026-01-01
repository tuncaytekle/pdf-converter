//
//  PDFGatewayError.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 1/1/26.
//


import Foundation

// MARK: - Public Types

public enum PDFGatewayError: Error, LocalizedError {
    case invalidURL(String)
    case invalidFilename(String)
    case serverError(String)
    case unexpectedResponse
    case jobFailed(jobId: String, message: String)
    case timeout(jobId: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let s): return "Invalid URL: \(s)"
        case .invalidFilename(let s): return "Invalid filename: \(s)"
        case .serverError(let s): return "Server error: \(s)"
        case .unexpectedResponse: return "Unexpected response from server"
        case .jobFailed(let jobId, let message): return "Conversion failed (\(jobId)): \(message)"
        case .timeout(let jobId): return "Timed out waiting for conversion (\(jobId))"
        }
    }
}

public struct PDFGatewayResult: Sendable {
    public let jobId: String
    public let downloadURL: URL
}

// MARK: - Client

/// Client for your pdf-gateway service.
///
/// Supported operations:
/// - Convert a public URL to PDF (URL_TO_PDF).
/// - Convert a local file to PDF (DOC_TO_PDF or EBOOK_TO_PDF chosen automatically).
///
/// Selection logic for files:
/// - epub, mobi, azw, azw3 -> EBOOK_TO_PDF (calibre)
/// - everything else -> DOC_TO_PDF (libreoffice via gotenberg)
public final class PDFGatewayClient: @unchecked Sendable {

    public struct Config: Sendable {
        public let baseURL: URL
        public let pollInterval: TimeInterval
        public let timeout: TimeInterval
        public let userAgent: String?

        public init(
            baseURL: URL,
            pollInterval: TimeInterval = 1.0,
            timeout: TimeInterval = 120.0,
            userAgent: String? = "PDFGatewayClient/iOS"
        ) {
            self.baseURL = baseURL
            self.pollInterval = pollInterval
            self.timeout = timeout
            self.userAgent = userAgent
        }
    }

    private let config: Config
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Public API

    /// Convert a public URL to PDF.
    public func convert(publicURL: URL) async throws -> PDFGatewayResult {
        guard publicURL.scheme == "https" || publicURL.scheme == "http" else {
            throw PDFGatewayError.invalidURL(publicURL.absoluteString)
        }

        let create = try await createURLJob(url: publicURL.absoluteString)
        let jobId = create.job_id
        let final = try await waitForCompletion(jobId: jobId)
        return PDFGatewayResult(jobId: jobId, downloadURL: final)
    }

    /// Convert a local file to PDF. The client chooses calibre vs libreoffice automatically
    /// based on the file extension.
    ///
    /// - Parameters:
    ///   - fileURL: Local file URL (must be file://)
    ///   - filename: Original filename including extension (e.g. "book.epub", "doc.docx").
    ///              This is important; the backend uses the extension.
    public func convert(fileURL: URL, filename: String) async throws -> PDFGatewayResult {
        guard fileURL.isFileURL else {
            throw PDFGatewayError.invalidURL(fileURL.absoluteString)
        }
        let cleanedName = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanedName.contains("."), cleanedName.split(separator: ".").last?.isEmpty == false else {
            throw PDFGatewayError.invalidFilename("filename must include an extension, e.g. file.docx")
        }

        let type = Self.jobType(forFilename: cleanedName)

        // 1) Create job -> get signed upload URL
        let create = try await createFileJob(type: type, originalFilename: cleanedName)
        let jobId = create.job_id

        guard let uploadURLString = create.upload?.url, let uploadURL = URL(string: uploadURLString) else {
            throw PDFGatewayError.unexpectedResponse
        }

        // 2) PUT file bytes to signed URL
        try await uploadFile(to: uploadURL, fileURL: fileURL)

        // 3) Submit job (may return SUCCEEDED quickly, otherwise QUEUED)
        let submit = try await submitFileJob(jobId: jobId)

        if submit.status == "SUCCEEDED", let dl = submit.download_url, let downloadURL = URL(string: dl) {
            return PDFGatewayResult(jobId: jobId, downloadURL: downloadURL)
        }
        if submit.status == "FAILED" {
            throw PDFGatewayError.jobFailed(jobId: jobId, message: submit.error ?? "Unknown error")
        }

        // 4) Poll until complete
        let final = try await waitForCompletion(jobId: jobId)
        return PDFGatewayResult(jobId: jobId, downloadURL: final)
    }

    // MARK: - Job Type Routing

    private static func jobType(forFilename name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "epub", "mobi", "azw", "azw3":
            return "EBOOK_TO_PDF" // Calibre
        default:
            return "DOC_TO_PDF"   // LibreOffice (via Gotenberg)
        }
    }

    // MARK: - HTTP Models

    private struct CreateJobResponse: Decodable {
        let job_id: String
        let status: String
        let upload: UploadInfo?
        let error: String?

        struct UploadInfo: Decodable {
            let method: String
            let url: String
        }
    }

    private struct SubmitResponse: Decodable {
        let job_id: String
        let status: String
        let download_url: String?
        let error: String?
    }

    private struct JobStatusResponse: Decodable {
        let job_id: String
        let type: String?
        let status: String
        let download_url: String?
        let error_message: String?
        let error_code: String?
        let error: String?
    }

    // MARK: - Requests

    private func createURLJob(url: String) async throws -> CreateJobResponse {
        let body: [String: Any] = [
            "type": "URL_TO_PDF",
            "url": url
        ]
        return try await postJSON(path: "/v1/jobs", body: body, as: CreateJobResponse.self)
    }

    private func createFileJob(type: String, originalFilename: String) async throws -> CreateJobResponse {
        let body: [String: Any] = [
            "type": type,
            "original_filename": originalFilename
        ]
        return try await postJSON(path: "/v1/jobs", body: body, as: CreateJobResponse.self)
    }

    private func submitFileJob(jobId: String) async throws -> SubmitResponse {
        return try await postJSON(path: "/v1/jobs/\(jobId)/submit", body: [:], as: SubmitResponse.self)
    }

    private func getJob(jobId: String) async throws -> JobStatusResponse {
        let url = config.baseURL.appendingPathComponent("v1").appendingPathComponent("jobs").appendingPathComponent(jobId)
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyHeaders(&req)

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        return try decoder.decode(JobStatusResponse.self, from: data)
    }

    // MARK: - Upload

    private func uploadFile(to signedUploadURL: URL, fileURL: URL) async throws {
        let data = try Data(contentsOf: fileURL)

        var req = URLRequest(url: signedUploadURL)
        req.httpMethod = "PUT"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        // Do not attach auth headers; signed URL is the auth.
        let (respData, resp) = try await session.upload(for: req, from: data)
        guard let http = resp as? HTTPURLResponse else { throw PDFGatewayError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: respData, encoding: .utf8) ?? ""
            throw PDFGatewayError.serverError("Upload failed HTTP \(http.statusCode): \(body)")
        }
    }

    // MARK: - Polling

    private func waitForCompletion(jobId: String) async throws -> URL {
        let deadline = Date().addingTimeInterval(config.timeout)

        while Date() < deadline {
            let status = try await getJob(jobId: jobId)

            switch status.status {
            case "SUCCEEDED":
                if let dl = status.download_url, let url = URL(string: dl) {
                    return url
                }
                // If backend returns SUCCEEDED but no download_url, treat as error
                throw PDFGatewayError.unexpectedResponse

            case "FAILED":
                let message = status.error_message ?? status.error ?? "Unknown error"
                throw PDFGatewayError.jobFailed(jobId: jobId, message: message)

            default:
                try await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
            }
        }

        throw PDFGatewayError.timeout(jobId: jobId)
    }

    // MARK: - Generic JSON POST

    private func postJSON<T: Decodable>(path: String, body: [String: Any], as: T.Type) async throws -> T {
        let url = config.baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyHeaders(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, resp) = try await session.data(for: req)
        try validateHTTP(resp, data: data)

        // Decode either as T or as gateway error wrapper
        if let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }

        if let anyErr = try? decoder.decode([String: String].self, from: data),
           let msg = anyErr["error"] {
            throw PDFGatewayError.serverError(msg)
        }

        throw PDFGatewayError.unexpectedResponse
    }

    private func applyHeaders(_ req: inout URLRequest) {
        if let ua = config.userAgent {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        // If you add API keys / auth in front of pdf-gateway later, attach headers here.
    }

    private func validateHTTP(_ resp: URLResponse, data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw PDFGatewayError.unexpectedResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Gateway may return JSON {error: "..."} or {job_id..., status..., error...}
            throw PDFGatewayError.serverError("HTTP \(http.statusCode): \(body)")
        }
    }
}
