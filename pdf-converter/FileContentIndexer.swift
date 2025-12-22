import Foundation
import Combine
import PDFKit

@MainActor
final class FileContentIndexer: ObservableObject {
    @Published private var cache: [URL: String] = [:]
    private var inFlight = Set<URL>()

    func text(for file: PDFFile) -> String? {
        cache[file.url]
    }

    func ensureTextIndex(for file: PDFFile) {
        guard cache[file.url] == nil, !inFlight.contains(file.url) else { return }
        inFlight.insert(file.url)

        Task(priority: .utility) {
            let extractedText: String? = {
                guard let document = PDFDocument(url: file.url),
                      let rawText = document.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawText.isEmpty else { return nil }
                let snippet = String(rawText.prefix(4000))
                return snippet.lowercased()
            }()

            await MainActor.run {
                if let text = extractedText {
                    self.cache[file.url] = text
                } else {
                    self.cache[file.url] = ""
                }
                self.inFlight.remove(file.url)
            }
        }
    }

    func trimCache(keeping urls: [URL]) {
        let keepSet = Set(urls)
        cache = cache.filter { keepSet.contains($0.key) }
        inFlight = inFlight.intersection(keepSet)
    }
}
