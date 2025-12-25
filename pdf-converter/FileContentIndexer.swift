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

        // Use Task.detached to run heavy PDF work off the main actor
        Task.detached(priority: .utility) { [weak self] in
            let extractedText = await Self.extractText(from: file.url)

            await MainActor.run {
                guard let self else { return }
                if let text = extractedText {
                    self.cache[file.url] = text
                } else {
                    self.cache[file.url] = ""
                }
                self.inFlight.remove(file.url)
            }
        }
    }

    // Nonisolated helper to perform heavy I/O and parsing off the main actor
    private nonisolated static func extractText(from url: URL) async -> String? {
        guard let document = PDFDocument(url: url),
              let rawText = document.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawText.isEmpty else { return nil }
        let snippet = String(rawText.prefix(4000))
        return snippet.lowercased()
    }

    func trimCache(keeping urls: [URL]) {
        let keepSet = Set(urls)
        cache = cache.filter { keepSet.contains($0.key) }
        inFlight = inFlight.intersection(keepSet)
    }
}
