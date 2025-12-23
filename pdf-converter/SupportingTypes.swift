import SwiftUI
import PDFKit

/// Top-level tabs presented by the floating tab bar.
enum Tab: Hashable {
    case files, tools, settings, account
}

/// High-level tool actions surfaced inside `ToolsView`.
enum ToolAction: Hashable {
    case convertFiles
    case scanDocuments
    case convertPhotos
    case importDocuments
    case convertWebPage
    case editDocuments
}

/// Available scanning entry points controlled by the floating compose button.
enum ScanFlow: Identifiable {
    case documentCamera
    case photoLibrary

    var id: Int {
        switch self {
        case .documentCamera: return 0
        case .photoLibrary: return 1
        }
    }
}

/// Temporary representation of a scanned PDF before it's saved.
struct ScannedDocument: Identifiable {
    let id = UUID()
    let pdfURL: URL
    var fileName: String

    func withFileName(_ newName: String) -> ScannedDocument {
        var copy = self
        copy.fileName = newName
        return copy
    }
}

/// Wraps a URL that should be shared along with an optional cleanup callback.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let cleanupHandler: (() -> Void)?
}

/// Encapsulates alert metadata posted throughout the scanning pipeline.
struct ScanAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onDismiss: (() -> Void)?
}

/// Encapsulates alert metadata for settings-related notifications.
struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Error types for PDF editing operations.
enum PDFEditingError: Error {
    case writeFailed
}

/// Bridges the selected file and live `PDFDocument` into the editor sheet hierarchy.
final class PDFEditingContext: Identifiable {
    let id = UUID()
    let file: PDFFile
    let document: PDFDocument

    init(file: PDFFile, document: PDFDocument) {
        self.file = file
        self.document = document
    }
}
