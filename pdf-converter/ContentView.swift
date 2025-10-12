import SwiftUI
import VisionKit
import PhotosUI
import PDFKit
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication

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
    @State private var deleteTarget: PDFFile?
    @State private var showDeleteDialog = false
    @State private var showImporter = false
    @State private var importerTrigger = UUID()
    @State private var showConvertPicker = false
    @SceneStorage("requireBiometrics") private var requireBiometrics = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 1) Native TabView
            TabView(selection: $selection) {
                FilesView(
                    files: $files,
                    onScanDocuments: { scanDocumentsToPDF() },
                    onConvertPhotos: { convertPhotosToPDF() },
                    onConvertFiles: { convertFilesToPDF() },
                    onPreview: { previewSavedFile($0) },
                    onShare: { shareSavedFile($0) },
                    onRename: { beginRenamingFile($0) },
                    onDelete: { confirmDeletion(for: $0) }
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
        .background(                                    // <- isolated host for “Import Documents”
            EmptyView()
                .fileImporter(
                    isPresented: $showImporter,
                    allowedContentTypes: [.pdf],
                    allowsMultipleSelection: true,
                    onCompletion: handleImportResult
                )
        )
        .background(                                    // <- isolated host for “Convert Files to PDF”
            EmptyView()
                .fileImporter(
                    isPresented: $showConvertPicker,
                    allowedContentTypes: Self.convertibleContentTypes,
                    allowsMultipleSelection: false,
                    onCompletion: handleConvertResult
                )
        )
        .confirmationDialog("Delete PDF?", isPresented: $showDeleteDialog, presenting: deleteTarget) { file in
            Button("🗑️ Delete", role: .destructive) {
                deleteFile(file)
            }
            Button("Cancel", role: .cancel) {
                deleteTarget = nil
                showDeleteDialog = false
            }
        } message: { file in
            Text("This will remove \"\(file.name)\" from your device.")
        }
        .alert(item: $alertContext) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text("OK")) {
                    alertContext = nil
                    context.onDismiss?()
                }
            )
        }
        .confirmationDialog("", isPresented: $showCreateActions, titleVisibility: .hidden) {
            Button("📄 Scan Documents to PDF") { scanDocumentsToPDF() }
            Button("🖼️ Convert Photos to PDF") { convertPhotosToPDF() }
            Button("📁 Convert Files to PDF") { convertFilesToPDF() }
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

    private func convertFilesToPDF() {
        showCreateActions = false
        showConvertPicker = true
    }

    @MainActor
    private func presentImporter() {
        // no UUID/id hacks — just present
        showImporter = true
    }

    @MainActor
    private func importDocuments() {
        showCreateActions = false
        presentImporter()
    }

    @MainActor
    private func handleToolAction(_ action: ToolAction) {
        switch action {
        case .scanDocuments:
            scanDocumentsToPDF()
        case .convertPhotos:
            convertPhotosToPDF()
        case .convertFiles:
            convertFilesToPDF()
        case .importDocuments:
            showCreateActions = false
            importDocuments()
        case .convertWebPage, .editDocuments:
            break
        }
    }

    @MainActor
    private func previewSavedFile(_ file: PDFFile) {
        guard requireBiometrics else {
            previewFile = file
            return
        }

        Task { @MainActor in
            await authenticateForPreview(file)
        }
    }

    @MainActor
    private func authenticateForPreview(_ file: PDFFile) async {
        let result = await BiometricAuthenticator.authenticate(reason: "Preview requires Face ID / Passcode")

        switch result {
        case .success:
            handleBiometricResult(granted: true, file: file)
        case .failed:
            handleBiometricResult(granted: false, file: file)
        case .cancelled:
            break
        case .unavailable(let message):
            alertContext = ScanAlert(
                title: "Authentication Unavailable",
                message: message,
                onDismiss: nil
            )
        case .error(let message):
            alertContext = ScanAlert(
                title: "Authentication Error",
                message: message,
                onDismiss: nil
            )
        }
    }

    @MainActor
    private func handleBiometricResult(granted: Bool, file: PDFFile) {
        if granted {
            previewFile = file
        } else {
            alertContext = ScanAlert(
                title: "Authentication Failed",
                message: "We couldn't verify your identity.",
                onDismiss: nil
            )
        }
    }


    private func shareSavedFile(_ file: PDFFile) {
        shareItem = nil
        shareItem = ShareItem(url: file.url, cleanupHandler: nil)
    }

    private func beginRenamingFile(_ file: PDFFile) {
        renameText = file.name
        renameTarget = file
    }

    private func confirmDeletion(for file: PDFFile) {
        deleteTarget = file
        showDeleteDialog = true
    }

    private func deleteFile(_ file: PDFFile) {
        do {
            try PDFStorage.delete(file: file)
            files.removeAll { $0.url == file.url }
            deleteTarget = nil
            showDeleteDialog = false
        } catch {
            alertContext = ScanAlert(
                title: "Delete Failed",
                message: "We couldn't remove the PDF. Please try again.",
                onDismiss: {
                    deleteTarget = nil
                    showDeleteDialog = false
                }
            )
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        showImporter = false
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            do {
                let imported = try PDFStorage.importDocuments(at: urls)
                if imported.isEmpty {
                    alertContext = ScanAlert(
                        title: "No PDFs Imported",
                        message: "We couldn't add any of the selected files. Please choose PDFs and try again.",
                        onDismiss: nil
                    )
                    return
                }
                // Merge new files and keep list sorted by date desc
                files.append(contentsOf: imported)
                files.sort { $0.date > $1.date }
                alertContext = ScanAlert(
                    title: "Import Complete",
                    message: imported.count == 1 ? "Added 1 PDF to your library." : "Added \(imported.count) PDFs to your library.",
                    onDismiss: nil
                )
            } catch {
                alertContext = ScanAlert(
                    title: "Import Failed",
                    message: "We couldn't import the selected files. Please try again.",
                    onDismiss: nil
                )
            }
        case .failure(let error):
            if let nsError = error as NSError?, nsError.code == NSUserCancelledError {
                // user cancelled, no action
                return
            }
            alertContext = ScanAlert(
                title: "Import Failed",
                message: "We couldn't access the selected files. Please try again.",
                onDismiss: nil
            )
        }
    }

    private func handleConvertResult(_ result: Result<[URL], Error>) {
        showConvertPicker = false
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let placeholder = try makePlaceholderPDF(for: url)
                let baseName = url.deletingPathExtension().lastPathComponent
                let suggestedName = "\(baseName) PDF"
                pendingDocument = ScannedDocument(pdfURL: placeholder, fileName: suggestedName)
            } catch {
                alertContext = ScanAlert(
                    title: "Conversion Failed",
                    message: "We couldn't prepare a PDF preview. Please try again.",
                    onDismiss: nil
                )
            }
        case .failure(let error):
            if let nsError = error as NSError?, nsError.code == NSUserCancelledError {
                return
            }
            alertContext = ScanAlert(
                title: "Conversion Failed",
                message: "We couldn't access the selected file. Please try again.",
                onDismiss: nil
            )
        }
    }

    private func makePlaceholderPDF(for originalURL: URL) throws -> URL {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter-ish
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            context.beginPage()

            let title = originalURL.deletingPathExtension().lastPathComponent
            let subtitle = originalURL.pathExtension.isEmpty ? "Original file" : "Original file: .\(originalURL.pathExtension.lowercased())"
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                .paragraphStyle: paragraphStyle
            ]

            let subtitleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle
            ]

            let messageAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel,
                .paragraphStyle: paragraphStyle
            ]

            let titleString = "PDF Converter"
            let convertedTitle = "\(title)\n"
            let message = "Placeholder preview\nThe actual conversion will happen once the online service is connected."

            let titleRect = CGRect(x: 40, y: 150, width: pageRect.width - 80, height: 40)
            titleString.draw(in: titleRect, withAttributes: titleAttributes)

            let subtitleRect = CGRect(x: 60, y: titleRect.maxY + 16, width: pageRect.width - 120, height: 24)
            subtitle.draw(in: subtitleRect, withAttributes: subtitleAttributes)

            let fileRect = CGRect(x: 60, y: subtitleRect.maxY + 12, width: pageRect.width - 120, height: 26)
            convertedTitle.draw(in: fileRect, withAttributes: titleAttributes)

            let messageRect = CGRect(x: 60, y: fileRect.maxY + 20, width: pageRect.width - 120, height: 80)
            message.draw(in: messageRect, withAttributes: messageAttributes)
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: tempURL, options: .atomic)
        return tempURL
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

    private static let convertibleExtensions: [String] = [
        "123","602","abw","bib","bmp","cdr","cgm","cmx","csv","cwk","dbf","dif","doc","docm","docx","dot","dotm","dotx","dxf","emf","eps","epub","fodg","fodp","fods","fodt","fopd","gif","htm","html","hwp","jpeg","jpg","key","ltx","lwp","mcw","met","mml","mw","numbers","odd","odg","odm","odp","ods","odt","otg","oth","otp","ots","ott","pages","pbm","pcd","pct","pcx","pdb","pdf","pgm","png","pot","potm","potx","ppm","pps","ppt","pptm","pptx","psd","psw","pub","pwp","pxl","ras","rtf","sda","sdc","sdd","sdp","sdw","sgl","slk","smf","stc","std","sti","stw","svg","svm","swf","sxc","sxd","sxg","sxi","sxm","sxw","tga","tif","tiff","txt","uof","uop","uos","uot","vdx","vor","vsd","vsdm","vsdx","wb2","wk1","wks","wmf","wpd","wpg","wps","xbm","xhtml","xls","xlsb","xlsm","xlsx","xlt","xltm","xltx","xlw","xml","xpm","zabw"
    ]

    private static let convertibleContentTypes: [UTType] = {
        var types = Set<UTType>()
        for ext in convertibleExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.insert(type)
            } else if let type = UTType(filenameExtension: ext, conformingTo: .data) {
                types.insert(type)
            }
        }
        types.insert(.pdf)
        if types.isEmpty {
            types.insert(.data)
        }
        return Array(types)
    }()
}

// MARK: - FilesView (replaces HomeView)

struct FilesView: View {
    // Backed by files persisted in the app's documents directory
    @Binding var files: [PDFFile]

    // Callbacks provided by parent to trigger creation flows
    let onScanDocuments: () -> Void
    let onConvertPhotos: () -> Void
    let onConvertFiles: () -> Void
    let onPreview: (PDFFile) -> Void
    let onShare: (PDFFile) -> Void
    let onRename: (PDFFile) -> Void
    let onDelete: (PDFFile) -> Void
    private let thumbnailSize = CGSize(width: 58, height: 78)

    var body: some View {
        NavigationView {
            filesContent
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        if files.isEmpty {
            EmptyFilesView(
                onScanDocuments: onScanDocuments,
                onConvertPhotos: onConvertPhotos,
                onConvertFiles: onConvertFiles
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Files")
        } else {
            List {
                ForEach(files) { file in
                    HStack(alignment: .top, spacing: 16) {
                        PDFThumbnailView(file: file, size: thumbnailSize)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.name)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(file.detailsSummary)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Text(file.formattedDate)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)

                        Menu {
                            Button("👀 Preview") { onPreview(file) }
                            Button("📤 Share") { onShare(file) }
                            Button("✏️ Rename") { onRename(file) }
                            Divider()
                            Button("🗑️ Delete", role: .destructive) { onDelete(file) }
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
                    .padding(.vertical, 10)
                }
            }
            .navigationTitle("Files")
        }
    }
}

private struct EmptyFilesView: View {
    let onScanDocuments: () -> Void
    let onConvertPhotos: () -> Void
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

            VStack(spacing: 12) {
                Button(action: onScanDocuments) {
                    Label("Scan Documents", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(action: onConvertPhotos) {
                    Label("Convert Photos", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onConvertFiles) {
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
    let pageCount: Int
    let fileSize: Int64

    var id: URL { url }

    var formattedDate: String {
        Self.dateFormatter.string(from: date)
    }

    var pageSummary: String {
        let count = max(pageCount, 0)
        return count == 1 ? "1 Page" : "\(count) Pages"
    }

    var formattedSize: String {
        Self.sizeFormatter.string(fromByteCount: fileSize)
    }

    var detailsSummary: String {
        "\(pageSummary) - \(formattedSize)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let sizeFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
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

private enum BiometricAuthResult {
    case success
    case failed
    case cancelled
    case unavailable(String)
    case error(String)
}

private enum BiometricAuthenticator {
    @MainActor
    static func authenticate(reason: String) async -> BiometricAuthResult {
        let biometricContext = LAContext()
        biometricContext.localizedFallbackTitle = "Use Passcode"

        var biometricError: NSError?
        let canUseBiometrics = biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)

        let fallbackContext = LAContext()
        var passcodeError: NSError?
        let canUsePasscode = fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError)

        guard canUseBiometrics || canUsePasscode else {
            let message = biometricError?.localizedDescription
                ?? passcodeError?.localizedDescription
                ?? "This device cannot perform Face ID or passcode authentication."
            return .unavailable(message)
        }

        do {
            if canUseBiometrics {
                do {
                    let granted = try await evaluate(policy: .deviceOwnerAuthenticationWithBiometrics, using: biometricContext, reason: reason)
                    return granted ? .success : .failed
                } catch let laError as LAError {
                    switch laError.code {
                    case .userFallback, .biometryLockout:
                        guard canUsePasscode else { return .error(laError.localizedDescription) }
                        let granted = try await evaluate(policy: .deviceOwnerAuthentication, using: fallbackContext, reason: reason)
                        return granted ? .success : .failed
                    case .userCancel, .systemCancel:
                        return .cancelled
                    default:
                        return .error(laError.localizedDescription)
                    }
                }
            }

            let granted = try await evaluate(policy: .deviceOwnerAuthentication, using: fallbackContext, reason: reason)
            return granted ? .success : .failed
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel:
                return .cancelled
            default:
                return .error(laError.localizedDescription)
            }
        } catch {
            return .error(error.localizedDescription)
        }
    }

    @MainActor
    private static func evaluate(policy: LAPolicy, using context: LAContext, reason: String) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            context.evaluatePolicy(policy, localizedReason: reason) { success, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
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

struct SettingsView: View {
    @State private var showSignatureSheet = false
    @State private var savedSignatureName: String? = nil
    @SceneStorage("requireBiometrics") private var requireBiometrics = false
    @State private var infoSheet: InfoSheet?
    @State private var shareItem: ShareItem?
    @State private var settingsAlert: SettingsAlert?

    private enum InfoSheet: Identifiable {
        case faq, terms, privacy

        var id: Int {
            switch self {
            case .faq: return 0
            case .terms: return 1
            case .privacy: return 2
            }
        }

        var title: String {
            switch self {
            case .faq: return "FAQ"
            case .terms: return "Terms of Use"
            case .privacy: return "Privacy Policy"
            }
        }

        var message: String {
            "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Morbi commodo quam eget ligula consectetur, ut fermentum massa luctus."
        }
    }

    var body: some View {
        NavigationView {
            List {
                subscriptionSection
                settingsSection
                infoSection
                supportSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
            .sheet(item: $infoSheet) { sheet in
                NavigationView {
                    ScrollView {
                        Text(sheet.message)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .navigationTitle(sheet.title)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { infoSheet = nil }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSignatureSheet) {
                NavigationView {
                    SignaturePlaceholderView(savedSignatureName: $savedSignatureName)
                }
            }
            .sheet(item: $shareItem) { item in
                ShareSheet(activityItems: [item.url]) {
                    item.cleanupHandler?()
                    shareItem = nil
                }
            }
            .alert(item: $settingsAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK")) {
                        settingsAlert = nil
                    }
                )
            }
        }
    }

    private var subscriptionSection: some View {
        Section("Subscription") {
            Button {
                // TODO: Hook into real purchase flow
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: "sparkles")
                                .font(.headline)
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Upgrade to PDF Converter Pro")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Unlock unlimited conversions and pro tools")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("Start your free trial today and supercharge your workflow")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 56)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsSection: some View {
        Section("Settings") {
            Button {
                showSignatureSheet = true
            } label: {
                HStack {
                    Image(systemName: "signature")
                    VStack(alignment: .leading) {
                        Text(savedSignatureName == nil ? "Add signature" : "Update signature")
                        if let savedSignatureName {
                            Text("Current: \(savedSignatureName)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Toggle(isOn: Binding(
                get: { requireBiometrics },
                set: { newValue in
                    guard newValue != requireBiometrics else { return }

                    if newValue {
                        requireBiometrics = true
                    } else {
                        Task { @MainActor in
                            await promptToDisableBiometrics()
                        }
                    }
                }
            )) {
                VStack(alignment: .leading) {
                    Text("Require Face ID / Passcode")
                    Text("Ask for Face ID or passcode before previewing files")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @MainActor
    private func promptToDisableBiometrics() async {
        let result = await BiometricAuthenticator.authenticate(reason: "Turn off Face ID protection")

        switch result {
        case .success:
            requireBiometrics = false
        case .failed:
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: "Authentication Failed",
                message: "We couldn't verify your identity."
            )
        case .cancelled:
            requireBiometrics = true
        case .unavailable(let message):
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: "Authentication Unavailable",
                message: message
            )
        case .error(let message):
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: "Authentication Error",
                message: message
            )
        }
    }

    private var infoSection: some View {
        Section("Info") {
            Button { infoSheet = .faq } label: {
                Label("FAQ", systemImage: "questionmark.circle")
            }
            Button { infoSheet = .terms } label: {
                Label("Terms of Use", systemImage: "doc.append")
            }
            Button { infoSheet = .privacy } label: {
                Label("Privacy Policy", systemImage: "lock.shield")
            }
        }
    }

    private var supportSection: some View {
        Section("Support") {
            Button {
                if let shareURL = URL(string: "https://roguewaveapps.com/pdf-converter") {
                    shareItem = ShareItem(url: shareURL, cleanupHandler: nil)
                }
            } label: {
                Label("Share App", systemImage: "square.and.arrow.up")
            }

            Button {
                settingsAlert = SettingsAlert(
                    title: "Contact Support",
                    message: "Email us at pdfconverter@roguewaveapps.com and we’ll be happy to help!"
                )
            } label: {
                Label("Contact Support", systemImage: "envelope")
            }
        }
    }
}

private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct AccountView: View {
    // TODO: Replace with real subscription status
    @State private var isSubscribed = false

    private let featureList: [(String, String)] = [
        ("🚀", "Unlimited document conversions"),
        ("📸", "Batch photo to PDF conversion"),
        ("🗂️", "Cloud backup for all your files"),
        ("🖋️", "Advanced editing & annotations"),
        ("🔒", "Secure passcode-protected PDFs"),
        ("🤝", "Priority support & new features")
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    statusSection
                    featuresSection
                    actionButton
                }
                .padding()
            }
            .navigationTitle("Account")
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isSubscribed ? "You're a Pro!" : "Go Pro to unlock more")
                .font(.title2.weight(.semibold))
            Text(isSubscribed ? "Thank you for supporting PDF Converter. You currently enjoy every premium feature." : "PDF Converter Pro gives you the power tools to work with any document, anywhere.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isSubscribed ? "Your Pro features" : "Unlock these features")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(featureList, id: \.0) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.0)
                            .font(.title3)
                        Text(item.1)
                            .font(.body)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var actionButton: some View {
        if isSubscribed {
            Button {
                // Placeholder for manage subscription
            } label: {
                Label("Manage Subscription", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                // Placeholder subscribe action
            } label: {
                Label("Start Free Trial", systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct CreateSomethingView: View { var body: some View { NavigationView { Text("Create flow").navigationTitle("New Item") } } }

struct SignaturePlaceholderView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var savedSignatureName: String?
    @State private var signatureName: String = ""

    var body: some View {
        Form {
            Section("Signature") {
                TextField("Signature name", text: $signatureName)
                Text("Draw signature feature coming soon. For now, give it a name so we can remember it for documents.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Save") {
                    savedSignatureName = signatureName.isEmpty ? "My Signature" : signatureName
                    dismiss()
                }
                .buttonStyle(.borderedProminent)

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
            }
        }
        .navigationTitle("Signature")
        .onAppear {
            signatureName = savedSignatureName ?? ""
        }
    }
}

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
                includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

        return pdfs.compactMap { url in
            let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
            let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
            let size = Int64(resourceValues?.fileSize ?? 0)
            let pageCount = PDFDocument(url: url)?.pageCount ?? 0
            return PDFFile(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                date: date,
                pageCount: pageCount,
                fileSize: size
            )
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

        let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
        let size = Int64(resourceValues?.fileSize ?? 0)
        let pageCount = PDFDocument(url: destination)?.pageCount ?? 0

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: date,
            pageCount: pageCount,
            fileSize: size
        )
    }

    static func importDocuments(at urls: [URL]) throws -> [PDFFile] {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed("Unable to access the Documents folder.")
        }

        var imported: [PDFFile] = []

        for sourceURL in urls {
            var didAccess = false
            if sourceURL.startAccessingSecurityScopedResource() {
                didAccess = true
            }
            defer {
                if didAccess {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            guard sourceURL.pathExtension.lowercased() == "pdf" else { continue }

            let baseName = sanitizeFileName(sourceURL.deletingPathExtension().lastPathComponent)
            let destination = uniqueURL(for: baseName, in: directory)

            do {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
                let date = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? Date()
                let size = Int64(resourceValues?.fileSize ?? 0)
                let pageCount = PDFDocument(url: destination)?.pageCount ?? 0
                let file = PDFFile(
                    url: destination,
                    name: destination.deletingPathExtension().lastPathComponent,
                    date: date,
                    pageCount: pageCount,
                    fileSize: size
                )
                imported.append(file)
            } catch {
                throw ScanWorkflowError.underlying(error)
            }
        }

        return imported
    }

    static func rename(file: PDFFile, to newName: String) throws -> PDFFile {
        let sanitized = sanitizeFileName(newName)
        let directory = file.url.deletingLastPathComponent()
        let currentBase = file.url.deletingPathExtension().lastPathComponent

        if currentBase == sanitized {
            return PDFFile(
                url: file.url,
                name: sanitized,
                date: file.date,
                pageCount: file.pageCount,
                fileSize: file.fileSize
            )
        }

        let destination = uniqueURL(for: sanitized, in: directory, excluding: file.url)

        do {
            try FileManager.default.moveItem(at: file.url, to: destination)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }

        let resourceValues = try? destination.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let updatedDate = resourceValues?.contentModificationDate ?? resourceValues?.creationDate ?? file.date
        let size = Int64(resourceValues?.fileSize ?? Int(file.fileSize))
        let pageCount = PDFDocument(url: destination)?.pageCount ?? file.pageCount

        return PDFFile(
            url: destination,
            name: destination.deletingPathExtension().lastPathComponent,
            date: updatedDate,
            pageCount: pageCount,
            fileSize: size
        )
    }

    static func delete(file: PDFFile) throws {
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            throw ScanWorkflowError.underlying(error)
        }
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
