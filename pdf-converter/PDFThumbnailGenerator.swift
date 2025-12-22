import UIKit
import PDFKit

actor PDFThumbnailGenerator {
    static let shared = PDFThumbnailGenerator()
    private var cache: [URL: UIImage] = [:]

    func thumbnail(for url: URL, size: CGSize) async -> UIImage? {
        if let cached = cache[url] {
            return cached
        }

        guard let document = PDFDocument(url: url),
              let page = document.page(at: 0) else {
            return nil
        }

        let scale = await MainActor.run { UIScreen.main.scale }
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let image = page.thumbnail(of: targetSize, for: .cropBox)
        cache[url] = image
        return image
    }
}
