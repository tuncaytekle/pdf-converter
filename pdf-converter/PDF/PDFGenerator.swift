import PDFKit
import UIKit

enum PDFGenerator {
    static func makePDF(from images: [UIImage]) throws -> URL {
        let document = PDFDocument()
        for (index, image) in images.enumerated() {
            guard let page = PDFPage(image: image) else {
                continue
            }
            document.insert(page, at: index)
        }

        guard document.pageCount > 0, let data = document.dataRepresentation() else {
            throw ScanWorkflowError.failed(NSLocalizedString("We couldn't create PDF data from the scanned pages.", comment: "Scanned PDF creation error message"))
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }
}
