import Foundation
import Combine
import PDFKit

@MainActor
final class FileContentIndexer: ObservableObject {
    @Published private var cache: [URL: String] = [:]
    private var inFlight = Set<URL>()
    private var activeTasks: [URL: Task<Void, Never>] = [:]

    func text(for file: PDFFile) -> String? {
        cache[file.url]
    }

    func ensureTextIndex(for file: PDFFile) {
        guard cache[file.url] == nil, !inFlight.contains(file.url) else { return }
        inFlight.insert(file.url)

        // Use Task.detached to run heavy PDF work off the main actor
        let fileURL = file.url
        let task = Task.detached(priority: .utility) {
            let extractedText = await Self.extractText(from: fileURL)

            await MainActor.run { [weak self] in
                guard let self else { return }
                if let text = extractedText {
                    self.cache[fileURL] = text
                } else {
                    self.cache[fileURL] = ""
                }
                self.inFlight.remove(fileURL)
                self.activeTasks[fileURL] = nil
            }
        }
        activeTasks[fileURL] = task
    }

    /// Cancels all in-flight indexing tasks
    func cancelPendingWork() {
        for task in activeTasks.values {
            task.cancel()
        }
        activeTasks.removeAll()
        inFlight.removeAll()
    }

    // Nonisolated helper to perform heavy I/O and parsing off the main actor
    private nonisolated static func extractText(from url: URL) async -> String? {
        // Check for cancellation before heavy I/O
        guard !Task.isCancelled else { return nil }

        guard let document = PDFDocument(url: url) else { return nil }

        // Check again after heavy PDF load
        guard !Task.isCancelled else { return nil }

        guard let rawText = document.string?
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
