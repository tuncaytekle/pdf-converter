import Foundation

/// Shared error surface for scanner, photo picker, and conversion flows.
enum ScanWorkflowError: Error {
    case cancelled
    case unavailable
    case noImages
    case failed(String)
    case underlying(Error)

    var message: String {
        switch self {
        case .cancelled:
            return NSLocalizedString("scanError.cancelled", comment: "Scan cancelled message")
        case .unavailable:
            return NSLocalizedString("scanError.unavailable", comment: "Scanning unavailable message")
        case .noImages:
            return NSLocalizedString("scanError.noImages", comment: "No images selected message")
        case .failed(let detail):
            return detail
        case .underlying(let error):
            return error.localizedDescription
        }
    }

    var shouldDisplayAlert: Bool {
        if case .cancelled = self { return false }
        return true
    }
}

extension ScanWorkflowError: LocalizedError {
    var errorDescription: String? {
        return message
    }
}
