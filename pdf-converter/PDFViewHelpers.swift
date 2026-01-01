import SwiftUI
import PDFKit
import UIKit
import PostHog

/// Placeholder view for future create flows.
struct CreateSomethingView: View {
    var body: some View {
        NavigationView {
            Text(NSLocalizedString("placeholder.createFlow.body", comment: "Create flow placeholder"))
                .navigationTitle(NSLocalizedString("placeholder.createFlow.title", comment: "Create flow title"))
        }
    }
}

/// Simple PDFView wrapper for displaying PDF documents.
struct PDFPreviewView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = .systemBackground
        return pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.document = PDFDocument(url: url)
    }
}

/// Async thumbnail renderer that caches results via `PDFThumbnailGenerator`.
struct PDFThumbnailView: View {
    let file: PDFFile
    let size: CGSize

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.combined(with: .scale))
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: file.url) {
            await loadThumbnail()
        }
        .onChange(of: file.url) { _, _ in
            image = nil
        }
    }

    /// Requests a cached thumbnail (or renders a new one) and updates the SwiftUI view.
    private func loadThumbnail() async {
        if image != nil { return }
        if let generated = await PDFThumbnailGenerator.shared.thumbnail(for: file.url, size: size) {
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.2)) {
                    image = generated
                }
            }
        }
    }
}

/// Full-screen PDF viewer with share functionality.
struct SavedPDFDetailView: View {
    let file: PDFFile
    @State private var showShareSheet = false
    @EnvironmentObject private var subscriptionGate: SubscriptionGate

    var body: some View {
        PDFPreviewView(url: file.url)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        subscriptionGate.requireSubscription(for: "pdf_preview_share") {
                            showShareSheet = true
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .postHogLabel("pdf_preview_share")
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = try? PDFStorage.prepareShareURL(for: ScannedDocument(pdfURL: file.url, fileName: file.name)) {
                    ShareSheet(activityItems: [url]) {
                        showShareSheet = false
                    }
                }
            }
            .postHogScreenView("PDF Preview", [
                "file_name": file.name
            ])
    }
}

/// Simple form for renaming PDFs with validation and autofocus.
struct RenameFileSheet: View {
    @Binding var fileName: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isFieldFocused: Bool

    private var isSaveDisabled: Bool {
        fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationView {
            Form {
        Section(header: Text(NSLocalizedString("rename.section.title", comment: "Rename section title"))) {
            TextField(NSLocalizedString("rename.field.placeholder", comment: "Rename field placeholder"), text: $fileName)
                .focused($isFieldFocused)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
        }
            }
            .navigationTitle(NSLocalizedString("rename.title", comment: "Rename title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action"), action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.save", comment: "Save action"), action: onSave)
                        .disabled(isSaveDisabled)
                }
            }
        }
        .onAppear {
            DispatchQueue.main.async {
                isFieldFocused = true
            }
        }
    }
}

/// Wrapper around `UIActivityViewController` that hands completion back to SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let completion: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            DispatchQueue.main.async {
                completion()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) { }
}
