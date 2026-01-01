//
//  GotenbergClient.swift
//  pdf-converter
//
//  Created by Tuncay Tekle on 11/25/25.
//


//
//  GotenbergClient.swift
//  Enhanced vendored client based on GotenbergKit (Apache 2.0)
//

import Foundation

// MARK: - Errors

public enum ConversionError: Error {
    case invalidURL
    case invalidResponse
    case serverError(status: Int, message: String)
    case networkError(Error)
}

// MARK: - Authentication

public enum GotenbergAuth {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case custom(headers: [String: String])
}

// MARK: - Retry Policy

public struct RetryPolicy {
    public var maxRetries: Int
    public var baseDelay: TimeInterval
    public var exponential: Bool
    
    public init(
        maxRetries: Int = 2,
        baseDelay: TimeInterval = 0.5,
        exponential: Bool = true
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.exponential = exponential
    }
}

// MARK: - Conversion Options

public struct PDFOptions {
    public var paperWidth: Double? = nil
    public var paperHeight: Double? = nil
    public var marginTop: Double? = nil
    public var marginBottom: Double? = nil
    public var marginLeft: Double? = nil
    public var marginRight: Double? = nil
    public var printBackground: Bool? = nil
    public var landscape: Bool? = nil
    public var scale: Double? = nil
    
    public init() {}
}

// MARK: - Client

public final class GotenbergClient {
    
    private let baseURL: URL
    private let session: URLSession
    private let auth: GotenbergAuth
    private let retryPolicy: RetryPolicy
    
    public init(
        baseURL: URL,
        auth: GotenbergAuth = .none,
        retryPolicy: RetryPolicy = RetryPolicy(),
        timeout: TimeInterval = 60.0
    ) {
        self.baseURL = baseURL
        self.auth = auth
        self.retryPolicy = retryPolicy
        
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        self.session = URLSession(configuration: cfg)
    }
    
    // MARK: - HTML → PDF
    
    public func convertHTMLToPDF(
        html: String,
        options: PDFOptions? = nil
    ) async throws -> Data {
        let resolvedOptions = options ?? PDFOptions()
        
        return try await uploadMultipart(
            endpoint: "/forms/chromium/convert/html",
            files: [
                MultipartFile(
                    fieldName: "files",
                    fileName: "document.html",
                    mimeType: "text/html",
                    data: Data(html.utf8)
                )
            ],
            fields: buildOptionFields(resolvedOptions)
        )
    }
    
    // MARK: - URL → PDF
    
    public func convertURLToPDF(
        url: String,
        options: PDFOptions? = nil
    ) async throws -> Data {
        let resolvedOptions = options ?? PDFOptions()
        return try await uploadMultipart(
            endpoint: "/forms/chromium/convert/url",
            files: [],
            fields: buildOptionFields(resolvedOptions)
                .merging(["url": url]) { $1 }
        )
    }
    
    // MARK: - Office Docs → PDF
    
    public func convertOfficeDocToPDF(
        fileName: String,
        data: Data
    ) async throws -> Data {
        return try await uploadMultipart(
            endpoint: "/forms/libreoffice/convert",
            files: [
                MultipartFile(
                    fieldName: "files",
                    fileName: fileName,
                    mimeType: mimeTypeForOffice(fileName),
                    data: data
                )
            ],
            fields: [:]
        )
    }
    
    // MARK: - Multipart core
    
    private func uploadMultipart(
        endpoint: String,
        files: [MultipartFile],
        fields: [String: String]
    ) async throws -> Data {
        
        guard let url = URL(string: endpoint, relativeTo: baseURL) else {
            throw ConversionError.invalidURL
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        
        applyAuth(to: &request)
        
        var body = Data()
        
        // fields
        for (k, v) in fields {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(k)\"\r\n\r\n")
            body.appendString("\(v)\r\n")
        }
        
        // files
        for file in files {
            body.appendString("--\(boundary)\r\n")
            body.appendString(
                "Content-Disposition: form-data; name=\"\(file.fieldName)\"; filename=\"\(file.fileName)\"\r\n"
            )
            body.appendString("Content-Type: \(file.mimeType)\r\n\r\n")
            body.append(file.data)
            body.appendString("\r\n")
        }
        
        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body
        
        return try await performWithRetry(request: request)
    }
    
    // MARK: - Retry Logic
    
    private func performWithRetry(request: URLRequest) async throws -> Data {
        var attempts = 0
        
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let http = response as? HTTPURLResponse else {
                    throw ConversionError.invalidResponse
                }
                
                if (200...299).contains(http.statusCode) {
                    return data
                }
                
                // Retry on 5xx
                if http.statusCode >= 500, attempts < retryPolicy.maxRetries {
                    attempts += 1
                    try await delayForRetry(attempt: attempts)
                    continue
                }
                
                let msg = String(data: data, encoding: .utf8) ?? ""
                throw ConversionError.serverError(status: http.statusCode, message: msg)
                
            } catch {
                // retry only network errors
                if attempts < retryPolicy.maxRetries {
                    attempts += 1
                    try await delayForRetry(attempt: attempts)
                    continue
                }
                throw ConversionError.networkError(error)
            }
        }
    }
    
    private func delayForRetry(attempt: Int) async throws {
        let delay: TimeInterval
        
        if retryPolicy.exponential {
            delay = retryPolicy.baseDelay * pow(2, Double(attempt - 1))
        } else {
            delay = retryPolicy.baseDelay
        }
        
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
    
    // MARK: - Authentication
    
    private func applyAuth(to request: inout URLRequest) {
        switch auth {
        case .none:
            return
            
        case .basic(let username, let password):
            let token = "\(username):\(password)"
            if let data = token.data(using: .utf8) {
                let base64 = data.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
            
        case .bearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
        case .custom(let headers):
            headers.forEach { k, v in
                request.setValue(v, forHTTPHeaderField: k)
            }
        }
    }
}

// MARK: - Helpers

private struct MultipartFile {
    let fieldName: String
    let fileName: String
    let mimeType: String
    let data: Data
}

private func mimeTypeForOffice(_ file: String) -> String {
    let ext = (file as NSString).pathExtension.lowercased()
    switch ext {
        case "doc", "docx":
            return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls", "xlsx":
            return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt", "pptx":
            return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default:
            return "application/octet-stream"
    }
}

private func buildOptionFields(_ o: PDFOptions) -> [String: String] {
    var f: [String: String] = [:]
    if let v = o.paperWidth { f["paperWidth"] = "\(v)" }
    if let v = o.paperHeight { f["paperHeight"] = "\(v)" }
    if let v = o.marginTop { f["marginTop"] = "\(v)" }
    if let v = o.marginBottom { f["marginBottom"] = "\(v)" }
    if let v = o.marginLeft { f["marginLeft"] = "\(v)" }
    if let v = o.marginRight { f["marginRight"] = "\(v)" }
    if let v = o.printBackground { f["printBackground"] = v ? "true" : "false" }
    if let v = o.landscape { f["landscape"] = v ? "true" : "false" }
    if let v = o.scale { f["scale"] = "\(v)" }
    return f
}

private extension Data {
    mutating func appendString(_ str: String) {
        append(Data(str.utf8))
    }
}
