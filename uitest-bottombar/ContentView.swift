import SwiftUI
import VisionKit
import PhotosUI
import PDFKit
import UIKit

enum Tab: Hashable {
    case files, tools, settings, account
}

enum ToolAction: Hashable {
    case convertFiles
    case scanDocuments
    case convertPhotos
    case importDocuments
    case convertWebPage
    case editDocuments
}

private enum ScanFlow: Identifiable {
    case documentCamera
    case photoLibrary

    var id: Int {
        switch self {
        case .documentCamera: return 0
        case .photoLibrary: return 1
        }
    }
}

struct ContentView: View {
    @State private var selection: Tab = .files
    @State private var showCreateActions = false
    @State private var files: [PDFFile] = []
    @State private var activeScanFlow: ScanFlow?
    @State private var pendingDocument: ScannedDocument?
    @State private var shareItem: ShareItem?
    @State private var alertContext: ScanAlert?
    @State private var hasLoadedInitialFiles = false
    @State private var previewFile: PDFFile?
    @State private var renameTarget: PDFFile?
    @State private var renameText: String = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 1) Native TabView
            TabView(selection: $selection) {
                FilesView(
                    files: $files,
                    onScanDocuments: { scanDocumentsToPDF() },
                    onConvertFiles: { convertPhotosToPDF() },
                    onPreview: { previewSavedFile($0) },
                    onShare: { shareSavedFile($0) },
                    onRename: { beginRenamingFile($0) }
                )
                .tabItem { Label("Files", systemImage: "doc") }
                .tag(Tab.files)

                ToolsView(onAction: handleToolAction)
                    .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                    .tag(Tab.tools)

                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                    .tag(Tab.settings)

                AccountView()
                    .tabItem { Label("Account", systemImage: "person.crop.circle") }
                    .tag(Tab.account)
            }

            // 2) Floating center button overlay
            VStack {
                Spacer()

                HStack {
                    Spacer()

                    CenterActionButton {
                        // Haptic feedback (optional)
                        let gen = UIImpactFeedbackGenerator(style: .medium)
                        gen.impactOccurred()
                        showCreateActions = true
                    }
                    .accessibilityLabel("Create")
                    .accessibilityAddTraits(.isButton)

                    Spacer()
                }
                // Lift the button slightly above the tab bar
                .padding(.bottom, 10)
            }
            // Ensure taps pass through where the button isn't
            .allowsHitTesting(true)
        }
        .onAppear(perform: loadInitialFiles)
        // Present whatever flow you need
        .sheet(item: $activeScanFlow) { flow in
            switch flow {
            case .documentCamera:
                DocumentScannerView { result in
                    handleScanResult(result, suggestedName: defaultFileName(prefix: "Scan"))
                }
            case .photoLibrary:
                PhotoPickerView { result in
                    handleScanResult(result, suggestedName: defaultFileName(prefix: "Photos"))
                }
            }
        }
        .sheet(item: $pendingDocument) { document in
            ScanReviewSheet(
                document: document,
                onSave: { saveScannedDocument($0) },
                onShare: { shareScannedDocument($0) },
                onCancel: { discardTemporaryDocument($0) }
            )
        }
        .sheet(item: $previewFile) { file in
            NavigationView {
                SavedPDFDetailView(file: file)
            }
        }
        .sheet(item: $renameTarget) { file in
            RenameFileSheet(fileName: $renameText) {
                renameTarget = nil
                renameText = file.name
            } onSave: {
                applyRename(for: file, newName: renameText)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url]) {
                item.cleanupHandler?()
                shareItem = nil
            }
        }
        .alert(item: $alertContext) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text("OK"), action: context.onDismiss)
            )
        }
        .confirmationDialog("", isPresented: $showCreateActions, titleVisibility: .hidden) {
            Button("📄 Scan Documents to PDF") { scanDocumentsToPDF() }
            Button("🖼️ Convert Photos to PDF") { convertPhotosToPDF() }
            Button("Cancel", role: .cancel) { }
        }
    }
    
    private func scanDocumentsToPDF() {
        guard VNDocumentCameraViewController.isSupported else {
            alertContext = ScanAlert(
                title: "Scanner Unavailable",
                message: "Document scanning is not supported on this device.",
                onDismiss: nil
            )
            return
        }
        activeScanFlow = .documentCamera
    }

    private func convertPhotosToPDF() {
        activeScanFlow = .photoLibrary
    }

    private func handleToolAction(_ action: ToolAction) {
        switch action {
        case .scanDocuments:
            scanDocumentsToPDF()
        case .convertPhotos:
            convertPhotosToPDF()
        case .convertFiles:
            showCreateActions = true
        case .importDocuments, .convertWebPage, .editDocuments:
            break
        }
    }

    private func previewSavedFile(_ file: PDFFile) {
        previewFile = file
    }

    private func shareSavedFile(_ file: PDFFile) {
        shareItem = nil
        shareItem = ShareItem(url: file.url, cleanupHandler: nil)
    }

    private func beginRenamingFile(_ file: PDFFile) {
        renameText = file.name
        renameTarget = file
    }

    private func loadInitialFiles() {
        guard !hasLoadedInitialFiles else { return }
        files = PDFStorage.loadSavedFiles().sorted { $0.date > $1.date }
        hasLoadedInitialFiles = true
    }

    private func handleScanResult(_ result: Result<[UIImage], ScanWorkflowError>, suggestedName: String) {
        activeScanFlow = nil

        switch result {
        case .success(let images):
            guard !images.isEmpty else {
                alertContext = ScanAlert(
                    title: "No Pages Captured",
                    message: "Try scanning again and press Done when you have captured all pages.",
                    onDismiss: nil
                )
                return
            }
            do {
                let pdfURL = try PDFGenerator.makePDF(from: images)
                pendingDocument = ScannedDocument(pdfURL: pdfURL, fileName: suggestedName)
                showCreateActions = false
            } catch {
                alertContext = ScanAlert(
                    title: "PDF Error",
                    message: "We couldn't create a PDF from the scanned pages. Please try again.",
                    onDismiss: nil
                )
            }
        case .failure(let error):
            if error.shouldDisplayAlert {
                alertContext = ScanAlert(
                    title: "Scan Failed",
                    message: error.message,
                    onDismiss: nil
                )
            }
        }
    }

    private func saveScannedDocument(_ document: ScannedDocument) {
        do {
            let savedFile = try PDFStorage.save(document: document)
            files.insert(savedFile, at: 0)
            pendingDocument = nil
            cleanupTemporaryFile(at: document.pdfURL)
        } catch {
            alertContext = ScanAlert(
                title: "Save Failed",
                message: "We couldn't save the PDF. Please try again.",
                onDismiss: nil
            )
        }
    }

    private func shareScannedDocument(_ document: ScannedDocument) {
        do {
            let shareURL = try PDFStorage.prepareShareURL(for: document)
            shareItem = nil
            shareItem = ShareItem(url: shareURL, cleanupHandler: {
                try? FileManager.default.removeItem(at: shareURL)
            })
        } catch {
            alertContext = ScanAlert(
                title: "Share Failed",
                message: "We couldn't prepare the PDF for sharing. Please try again.",
                onDismiss: nil
            )
        }
    }

    private func discardTemporaryDocument(_ document: ScannedDocument) {
        pendingDocument = nil
        cleanupTemporaryFile(at: document.pdfURL)
    }

    private func defaultFileName(prefix: String) -> String {
        let timestamp = Self.fileNameFormatter.string(from: Date())
        return "\(prefix) \(timestamp)"
    }

    private func cleanupTemporaryFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func applyRename(for file: PDFFile, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertContext = ScanAlert(
                title: "Invalid Name",
                message: "Please enter a file name before saving.",
                onDismiss: nil
            )
            return
        }

        do {
            let renamed = try PDFStorage.rename(file: file, to: trimmed)
            if let index = files.firstIndex(where: { $0.url == file.url }) {
                files[index] = renamed
            }
            renameText = renamed.name
            renameTarget = nil
        } catch {
            alertContext = ScanAlert(
                title: "Rename Failed",
                message: "We couldn't rename the PDF. Please try again.",
                onDismiss: nil
            )
        }
    }

    private static let fileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - FilesView (replaces HomeView)

struct FilesView: View {
    // Backed by files persisted in the app's documents directory
    @Binding var files: [PDFFile]

    // Callbacks provided by parent to trigger creation flows
    let onScanDocuments: () -> Void
    let onConvertFiles: () -> Void
    let onPreview: (PDFFile) -> Void
    let onShare: (PDFFile) -> Void
    let onRename: (PDFFile) -> Void

    var body: some View {
        NavigationView {
            filesContent
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        if files.isEmpty {
            EmptyFilesView(onScanDocuments: onScanDocuments, onConvertFiles: onConvertFiles)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Files")
        } else {
            List {
                ForEach(files) { file in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.richtext")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.accentColor)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name)
                                .font(.headline)
                            Text(file.formattedDate)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        Menu {
                            Button("Preview") { onPreview(file) }
                            Button("Share") { onShare(file) }
                            Button("Rename") { onRename(file) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 6)
                                .contentShape(Rectangle())
                                .accessibilityLabel("More actions")
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onPreview(file)
                    }
                }
            }
            .navigationTitle("Files")
        }
    }
}

private struct EmptyFilesView: View {
    let onScanDocuments: () -> Void
    let onConvertFiles: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            // Friendly illustration
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.blue.opacity(0.08))
                    .frame(width: 140, height: 140)
                Image(systemName: "doc.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.blue)
            }
            .padding(.bottom, 6)

            Text("No PDFs yet")
                .font(.title3.weight(.semibold))

            Text("You don't have any converted files yet. Scan documents or convert existing files to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button {
                    onScanDocuments()
                } label: {
                    Label("Scan Documents", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onConvertFiles()
                } label: {
                    Label("Convert Files", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.horizontal)
        }
        .padding()
    }
}

// Simple model for demo purposes
struct PDFFile: Identifiable {
    let url: URL
    var name: String
    let date: Date

    var id: URL { url }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

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

private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let cleanupHandler: (() -> Void)?
}

private struct ScanAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onDismiss: (() -> Void)?
}

enum ScanWorkflowError: Error {
    case cancelled
    case unavailable
    case noImages
    case failed(String)
    case underlying(Error)

    var message: String {
        switch self {
        case .cancelled:
            return "The scan was cancelled."
        case .unavailable:
            return "Scanning is not supported on this device."
        case .noImages:
            return "No images were selected."
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

// MARK: - Center Button

private struct CenterActionButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Circle that “floats” above the tab bar
                Circle()
                    .fill(Color.blue)
                    .frame(width: 64, height: 64)
                    .shadow(radius: 6, y: 2)

                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .background(
            // Make sure the hit area is exactly the circle, not the whole HStack
            Circle().fill(.clear).frame(width: 64, height: 64)
        )
        // Align it to sit slightly *into* the tab bar
        .offset(y: -20)
    }
}

// MARK: - Example tab content

struct SettingsView: View { var body: some View { NavigationView { Text("Settings").navigationTitle("Settings") } } }
struct AccountView: View { var body: some View { NavigationView { Text("Account").navigationTitle("Account") } } }
struct CreateSomethingView: View { var body: some View { NavigationView { Text("Create flow").navigationTitle("New Item") } } }

struct ToolsView: View {
    // Adaptive: fits as many columns as will cleanly fit (usually 2 on iPhone, 3 on iPad)
    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)
    ]
    let onAction: (ToolAction) -> Void

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ToolCard.sample) { card in
                        Button {
                            if let action = card.action {
                                onAction(action)
                            }
                        } label: {
                            ToolCardView(card: card)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.large)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
    }
}

// MARK: - Scan UI Helpers

struct ScanReviewSheet: View {
    let document: ScannedDocument
    let onSave: (ScannedDocument) -> Void
    let onShare: (ScannedDocument) -> Void
    let onCancel: (ScannedDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String

    init(document: ScannedDocument,
         onSave: @escaping (ScannedDocument) -> Void,
         onShare: @escaping (ScannedDocument) -> Void,
         onCancel: @escaping (ScannedDocument) -> Void) {
        self.document = document
        self.onSave = onSave
        self.onShare = onShare
        self.onCancel = onCancel
        _fileName = State(initialValue: document.fileName)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                PDFPreviewView(url: document.pdfURL)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .padding(.horizontal)
                    .padding(.top)

                VStack(alignment: .leading, spacing: 8) {
                    Text("File name")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField("File name", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }
                .padding(.horizontal)

                Spacer()

                VStack(spacing: 12) {
                    Button {
                        let updated = sanitizedDocument()
                        onShare(updated)
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        let updated = sanitizedDocument()
                        onSave(updated)
                        dismiss()
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel(document)
                        dismiss()
                    }
                }
            }
        }
    }

    private func sanitizedDocument() -> ScannedDocument {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return document }
        return document.withFileName(trimmed)
    }
}

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

struct SavedPDFDetailView: View {
    let file: PDFFile

    var body: some View {
        PDFPreviewView(url: file.url)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
    }
}

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
                Section(header: Text("File Name")) {
                    TextField("File name", text: $fileName)
                        .focused($isFieldFocused)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
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

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) { }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

        init(completion: @escaping (Result<[UIImage], ScanWorkflowError>) -> Void) {
            self.completion = completion
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let images: [UIImage] = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    if images.isEmpty {
                        completion(.failure(.noImages))
                    } else {
                        completion(.success(images))
                    }
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    completion(.failure(.cancelled))
                }
            }
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            controller.dismiss(animated: true) { [completion] in
                DispatchQueue.main.async {
                    completion(.failure(.underlying(error)))
                }
            }
        }
    }
}

struct PhotoPickerView: UIViewControllerRepresentable {
    let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(completion: completion)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 0
        configuration.preferredAssetRepresentationMode = .current
        let controller = PHPickerViewController(configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) { }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let completion: (Result<[UIImage], ScanWorkflowError>) -> Void

        init(completion: @escaping (Result<[UIImage], ScanWorkflowError>) -> Void) {
            self.completion = completion
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !results.isEmpty else {
                picker.dismiss(animated: true) { [completion] in
                    DispatchQueue.main.async {
                        completion(.failure(.cancelled))
                    }
                }
                return
            }

            var collectedImages: [UIImage] = []
            let dispatchGroup = DispatchGroup()

            for result in results where result.itemProvider.canLoadObject(ofClass: UIImage.self) {
                dispatchGroup.enter()
                result.itemProvider.loadObject(ofClass: UIImage.self) { object, error in
                    defer { dispatchGroup.leave() }
                    if let image = object as? UIImage {
                        collectedImages.append(image)
                    }
                }
            }

            dispatchGroup.notify(queue: .main) { [completion] in
                picker.dismiss(animated: true) {
                    if collectedImages.isEmpty {
                        completion(.failure(.noImages))
                    } else {
                        completion(.success(collectedImages))
                    }
                }
            }
        }
    }
}

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
            throw ScanWorkflowError.failed("We couldn't create PDF data from the scanned pages.")
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }
}

enum PDFStorage {
    static func loadSavedFiles() -> [PDFFile] {
        guard let directory = documentsDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

        return pdfs.compactMap { url in
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
            return PDFFile(url: url, name: url.deletingPathExtension().lastPathComponent, date: date)
        }
    }

    static func save(document: ScannedDocument) throws -> PDFFile {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed("Unable to access the Documents folder.")
        }

        let baseName = sanitizeFileName(document.fileName)
        let destination = uniqueURL(for: baseName, in: directory)

        do {
            try FileManager.default.moveItem(at: document.pdfURL, to: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: Date()
        )
    }

    static func rename(file: PDFFile, to newName: String) throws -> PDFFile {
        let sanitized = sanitizeFileName(newName)
        let directory = file.url.deletingLastPathComponent()
        let currentBase = file.url.deletingPathExtension().lastPathComponent

        if currentBase == sanitized {
            return PDFFile(url: file.url, name: sanitized, date: file.date)
        }

        let destination = uniqueURL(for: sanitized, in: directory, excluding: file.url)

        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
        let updatedDate = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? file.date

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: updatedDate
        )
    }

    static func prepareShareURL(for document: ScannedDocument) throws -> URL {
        let baseName = sanitizeFileName(document.fileName)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(baseName)
            .appendingPathExtension("pdf")

        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }

        try FileManager.default.copyItem(at: document.pdfURL, to: destination)
        return destination
    }

    private static func documentsDirectory() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func uniqueURL(for baseName: String, in directory: URL, excluding urlToIgnore: URL? = nil) -> URL {
        var attempt = 0
        while true {
            let nameComponent = attempt == 0 ? baseName : "\(baseName) \(attempt)"
            let candidate = directory.appendingPathComponent(nameComponent).appendingPathExtension("pdf")
            if let urlToIgnore, candidate == urlToIgnore {
                return candidate
            }
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            attempt += 1
        }
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.isEmpty ? "Scan" : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = sanitized.components(separatedBy: invalidCharacters)
        let filtered = components.joined(separator: "-")
        if filtered.lowercased().hasSuffix(".pdf") {
            return String(filtered.dropLast(4))
        }
        return filtered
    }
}

struct ToolCardView: View {
    let card: ToolCard

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(card.tint)
                .shadow(radius: 4, y: 2)

            // Content
            VStack(alignment: .leading, spacing: 10) {
                // Top row: leading badge + trailing arrow
                HStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(0.95))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: card.iconName)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(card.tint)
                        )

                    Spacer(minLength: 0)

                    Circle()
                        .fill(.white.opacity(0.95))
                        .frame(width: 32, height: 32)
                        .overlay(
                            Image(systemName: "arrow.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(card.tint)
                        )
                }

                // Title
                Text(card.title)
                    .font(.title3.weight(.bold))
                    .foregroundColor(.white)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.9)

                // Subtitle
                Text(card.subtitle)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(2)
                    .minimumScaleFactor(0.9)

                Spacer()
            }
            .padding(16)
        }
        // Keep ALL cards same visual size relative to width, prevents “towering” cards
        .aspectRatio(1.05, contentMode: .fit) // ~square card; tweak between 1.0–1.2
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

// MARK: - Card Model

struct ToolCard: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let tint: Color
    let iconName: String
    let action: ToolAction?
}

extension ToolCard {
    static let sample: [ToolCard] = [
        .init(title: "Convert\nFiles to PDF",
              subtitle: "Convert Word, PowerPoint or\nExcel files to PDF",
              tint: Color(hex: 0x2F7F79),
              iconName: "infinity",
              action: .convertFiles),
        .init(title: "Scan\nDocuments",
              subtitle: "Scan multiple documents with\nyour camera",
              tint: Color(hex: 0xC02267),
              iconName: "camera",
              action: .scanDocuments),
        .init(title: "Convert\nPhotos to PDF",
              subtitle: "Choose from your photo\nlibrary to create a new PDF",
              tint: Color(hex: 0x5C3A78),
              iconName: "photo.on.rectangle",
              action: .convertPhotos),
        .init(title: "Import\nDocuments",
              subtitle: "Import PDF files from your\ndevice or web",
              tint: Color(hex: 0x6C8FC0),
              iconName: "arrow.down.to.line",
              action: .importDocuments),
        .init(title: "Convert\nWeb Page",
              subtitle: "Convert Web Pages to PDF\nusing a URL Link",
              tint: Color(hex: 0xBF7426),
              iconName: "link",
              action: .convertWebPage),
        .init(title: "Edit\nDocuments",
              subtitle: "Sign, highlight, annotate\nexisting PDF files",
              tint: Color(hex: 0x7B3DD3),
              iconName: "pencil.and.outline",
              action: .editDocuments)
    ]
}

// MARK: - Small Color helper

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}
