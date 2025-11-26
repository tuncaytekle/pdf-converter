import SwiftUI
import Combine
import VisionKit
import PhotosUI
import PDFKit
import UIKit
import UniformTypeIdentifiers
import LocalAuthentication
import PencilKit
import StoreKit

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

/// Root container view that orchestrates tabs, quick actions, and all modal flows.
struct ContentView: View {
    private let cloudBackup = CloudBackupManager.shared
    private let client = GotenbergClient(
        baseURL: URL(string: "https://gotenberg-6a3w.onrender.com")!,
        retryPolicy: RetryPolicy(maxRetries: 2, baseDelay: 0.5, exponential: true),
        timeout: 120
    )

    @State private var selection: Tab = .files
    @State private var showCreateActions = false
    @State private var files: [PDFFile] = []
    @State private var activeScanFlow: ScanFlow?
    @State private var pendingDocument: ScannedDocument?
    @State fileprivate var shareItem: ShareItem?
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
    @State private var showWebURLPrompt = false
    @State private var webURLInput: String = ""
    @State private var showEditSelector = false
    @State private var editingContext: PDFEditingContext?
    @State private var createButtonPulse = false
    @State private var didAnimateCreateButtonCue = false
    @State private var isConvertingFile = false
    @SceneStorage("requireBiometrics") private var requireBiometrics = false
    @Environment(\.colorScheme) private var scheme
    @State private var hasAttemptedCloudRestore = false

    var body: some View {
        rootContent
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
        .sheet(isPresented: $showWebURLPrompt) {
            WebConversionPrompt(
                urlString: $webURLInput,
                onConvert: { input in
                    await handleWebConversion(urlString: input)
                },
                onCancel: {
                    showWebURLPrompt = false
                }
            )
        }
        .sheet(isPresented: $showEditSelector) {
            NavigationView {
                PDFEditorSelectionView(
                    files: $files,
                    onSelect: { file in
                        beginEditing(file)
                    },
                    onCancel: {
                        showEditSelector = false
                    }
                )
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: $editingContext) { context in
            NavigationView {
                PDFEditorView(
                    context: context,
                    onSave: {
                        saveEditedDocument(context)
                    },
                    onCancel: {
                        editingContext = nil
                    }
                )
            }
            .navigationViewStyle(.stack)
        }
        .background(
            EmptyView()
                .id(importerTrigger)
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
        .overlay {
            if isConvertingFile {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Converting…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .shadow(radius: 8)
                }
            }
        }
    }

    // MARK: - Body Builders

    /// Outer container holding the tab interface and floating compose button.
    private var rootContent: some View {
        ZStack {
            tabInterface
            floatingCreateButton
        }
    }

    /// Hosts the four main tabs and wires callbacks back into `ContentView`.
    private var tabInterface: some View {
        TabView(selection: $selection) {
            FilesView(
                files: $files,
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
    }

    /// Floating action button anchored to the bottom bar that surfaces quick actions.
    private var floatingCreateButton: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                CenterActionButton {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                    createButtonPulse = false
                    showCreateActions = true
                }
                .accessibilityLabel("Create")
                .accessibilityAddTraits(.isButton)
                .scaleEffect(createButtonPulse ? 1.06 : 1)
                .shadow(color: Color.blue.opacity(createButtonPulse ? 0.35 : 0.25), radius: createButtonPulse ? 18 : 8, y: createButtonPulse ? 10 : 2)
                .task {
                    await animateCreateButtonCueIfNeeded()
                }
            }
            .padding(.trailing, 28)
            .padding(.bottom, 10)
        }
        // Taps outside the button should fall through to the tab bar underneath.
        .allowsHitTesting(true)
    }
    
    // MARK: - Quick Action Routing

    /// Presents the document camera flow when the hardware supports it.
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

    /// Opens the shared photo picker so the user can turn images into a PDF.
    private func convertPhotosToPDF() {
        activeScanFlow = .photoLibrary
    }

    /// Opens the "convert files" importer after collapsing the quick action sheet.
    private func convertFilesToPDF() {
        showCreateActions = false
        showConvertPicker = true
    }

    // MARK: - Attention Cues

    @MainActor
    private func animateCreateButtonCueIfNeeded() async {
        guard !didAnimateCreateButtonCue else { return }
        didAnimateCreateButtonCue = true

        try? await Task.sleep(nanoseconds: 650_000_000)

        let animation = Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
        withAnimation(animation) {
            createButtonPulse = true
        }

        try? await Task.sleep(nanoseconds: 6_000_000_000)
        withAnimation(.easeOut(duration: 0.4)) {
            createButtonPulse = false
        }
    }

    // MARK: - Import & Conversion Flows

    /// Forces SwiftUI to re-present the file importer by toggling a hidden anchor view.
    @MainActor
    private func presentImporter() {
        importerTrigger = UUID()
        let alreadyPresenting = showImporter
        showImporter = false

        Task { @MainActor in
            if alreadyPresenting {
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            showImporter = true
        }
    }

    /// Entry point for `Import Documents` that routes through the shared importer.
    @MainActor
    private func importDocuments() {
        showCreateActions = false
        presentImporter()
    }

    /// Prompts the user for a URL that will later be rendered into a placeholder PDF.
    @MainActor
    private func promptWebConversion() {
        showCreateActions = false
        showWebURLPrompt = true
    }

    /// Ensures PDFs are loaded, then surfaces the edit selection sheet.
    @MainActor
    private func promptEditDocuments() {
        showCreateActions = false
        refreshFilesFromDisk()
        guard !files.isEmpty else {
            alertContext = ScanAlert(
                title: "No PDFs Available",
                message: "Add or import a PDF before trying to edit it.",
                onDismiss: nil
            )
            return
        }
        showEditSelector = true
    }

    /// Loads the selected PDF into the editing context and presents the editor sheet.
    @MainActor
    private func beginEditing(_ file: PDFFile) {
        guard let document = PDFDocument(url: file.url) else {
            alertContext = ScanAlert(
                title: "Open Failed",
                message: "We couldn't load that PDF for editing.",
                onDismiss: nil
            )
            return
        }

        showEditSelector = false
        let context = PDFEditingContext(file: file, document: document)
        DispatchQueue.main.async {
            editingContext = context
        }
    }

    /// Writes the edited PDF to disk, replacing the original file atomically.
    @MainActor
    private func saveEditedDocument(_ context: PDFEditingContext) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        do {
            guard context.document.write(to: tempURL) else {
                throw PDFEditingError.writeFailed
            }

            _ = try FileManager.default.replaceItemAt(context.file.url, withItemAt: tempURL)
            try? FileManager.default.removeItem(at: tempURL)
            refreshFilesFromDisk()
            editingContext = nil
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            alertContext = ScanAlert(
                title: "Save Failed",
                message: "We couldn't save your edits. Please try again.",
                onDismiss: nil
            )
        }
    }

    /// Routes each `ToolAction` tap back into the same flows used by the quick actions.
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
            importDocuments()
        case .convertWebPage:
            promptWebConversion()
        case .editDocuments:
            promptEditDocuments()
        }
    }

    // MARK: - Preview & Biometrics

    /// Handles the preview tap by optionally gating behind biometrics.
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

    /// Requests biometric authentication when required and surfaces clear alerts per scenario.
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

    /// Presents the requested file or alerts when authentication fails.
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

    // MARK: - File Management & Sharing

    /// Prepares a share sheet for an already-saved PDF.
    private func shareSavedFile(_ file: PDFFile) {
        shareItem = nil
        shareItem = ShareItem(url: file.url, cleanupHandler: nil)
    }

    /// Seeds the rename sheet with the existing file name.
    private func beginRenamingFile(_ file: PDFFile) {
        renameText = file.name
        renameTarget = file
    }

    /// Stores the pending deletion target and presents the destructive dialog.
    private func confirmDeletion(for file: PDFFile) {
        deleteTarget = file
        showDeleteDialog = true
    }

    /// Deletes a PDF from storage and reconciles the in-memory list.
    private func deleteFile(_ file: PDFFile) {
        do {
            try PDFStorage.delete(file: file)
            files.removeAll { $0.url == file.url }
            deleteTarget = nil
            showDeleteDialog = false
            Task {
                await cloudBackup.deleteBackup(for: file)
            }
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

    // MARK: - Import Helpers

    /// Finishes the document importer by persisting selected URLs into the app sandbox.
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
                Task {
                    await cloudBackup.backup(files: imported)
                }
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

    /// Handles the "convert files to PDF" importer by sending the document to Gotenberg.
    private func handleConvertResult(_ result: Result<[URL], Error>) {
        showConvertPicker = false
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                await convertFileUsingLibreOffice(url: url)
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

    /// Converts a local document into a PDF using Gotenberg's LibreOffice route.
    private func convertFileUsingLibreOffice(url: URL) async {
        await MainActor.run { isConvertingFile = true }
        defer { Task { await MainActor.run { isConvertingFile = false } } }

        do {
            let filename = url.lastPathComponent
            let baseName = url.deletingPathExtension().lastPathComponent
            let data = try readDataForSecurityScopedURL(url)
            let pdfData = try await client.convertOfficeDocToPDF(
                fileName: filename,
                data: data
            )
            let outputURL = try persistPDFData(pdfData)
            await MainActor.run {
                pendingDocument = ScannedDocument(
                    pdfURL: outputURL,
                    fileName: "\(baseName) PDF"
                )
            }
        } catch {
            await MainActor.run {
                alertContext = ScanAlert(
                    title: "Conversion Failed",
                    message: error.localizedDescription,
                    onDismiss: nil
                )
            }
        }
    }

    // MARK: - Web Conversion Helpers

    /// Validates the supplied URL, builds a placeholder PDF, and stages it inside the review sheet.
    @MainActor
    private func handleWebConversion(urlString: String) async -> Bool {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertContext = ScanAlert(
                title: "Invalid URL",
                message: "Please enter a web address to convert.",
                onDismiss: nil
            )
            return false
        }

        guard let resolvedURL = normalizedWebURL(from: trimmed) else {
            alertContext = ScanAlert(
                title: "Invalid URL",
                message: "We couldn't understand that web address. Try including the full URL (for example, https://example.com).",
                onDismiss: nil
            )
            return false
        }

        return await convertWebPage(url: resolvedURL)
    }

    /// Sends a URL to Gotenberg's Chromium route and stages the resulting PDF.
    private func convertWebPage(url: URL) async -> Bool {
        let host = url.host?
            .replacingOccurrences(of: "www.", with: "", options: [.caseInsensitive, .anchored])
            ?? "Web Page"

        do {
            let pdfData = try await client.convertURLToPDF(url: url.absoluteString)
            let outputURL = try persistPDFData(pdfData)
            await MainActor.run {
                pendingDocument = ScannedDocument(
                    pdfURL: outputURL,
                    fileName: defaultFileName(prefix: host)
                )
                webURLInput = url.absoluteString
            }
            return true
        } catch {
            await MainActor.run {
                alertContext = ScanAlert(
                    title: "Conversion Failed",
                    message: error.localizedDescription,
                    onDismiss: nil
                )
            }
            return false
        }
    }

    /// Normalizes partial URLs (missing scheme, etc.) into a canonical form we can fetch later.
    private func normalizedWebURL(from input: String) -> URL? {
        var candidate = input
        if !candidate.contains("://") {
            candidate = "https://\(candidate)"
        }

        guard var components = URLComponents(string: candidate) else {
            return nil
        }

        if components.scheme == nil || components.scheme?.isEmpty == true {
            components.scheme = "https"
        }

        guard let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        return components.url
    }

    /// Writes raw PDF data to a temporary location we can hand to the review sheet.
    private func persistPDFData(_ data: Data) throws -> URL {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Reads data from a potentially security-scoped URL.
    private func readDataForSecurityScopedURL(_ url: URL) throws -> Data {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return try Data(contentsOf: url)
    }

    // MARK: - Lifecycle & Scanning

    /// Lazily loads cached PDFs once to avoid repeated disk scans.
    private func loadInitialFiles() {
        guard !hasLoadedInitialFiles else { return }
        refreshFilesFromDisk()
        hasLoadedInitialFiles = true
        attemptCloudRestoreIfNeeded()
    }

    /// Rebuilds the in-memory file list from whatever is stored on disk.
    private func refreshFilesFromDisk() {
        files = PDFStorage.loadSavedFiles().sorted { $0.date > $1.date }
    }

    /// Fetches any remote backups and merges them into the local library once.
    private func attemptCloudRestoreIfNeeded() {
        guard !hasAttemptedCloudRestore else { return }
        hasAttemptedCloudRestore = true
        Task {
            let existingNames = Set(files.map { CloudRecordNaming.recordName(for: $0.url.lastPathComponent) })
            let restored = await cloudBackup.restoreMissingFiles(existingRecordNames: existingNames)
            guard !restored.isEmpty else { return }
            await MainActor.run {
                files.append(contentsOf: restored)
                files.sort { $0.date > $1.date }
            }
        }
    }

    /// Converts successful scan/photo results into PDFs and stages them for review.
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

    /// Persists the scanned document and removes any temporary files afterward.
    private func saveScannedDocument(_ document: ScannedDocument) {
        do {
            let savedFile = try PDFStorage.save(document: document)
            files.insert(savedFile, at: 0)
            pendingDocument = nil
            cleanupTemporaryFile(at: document.pdfURL)
            Task {
                await cloudBackup.backup(file: savedFile)
            }
        } catch {
            alertContext = ScanAlert(
                title: "Save Failed",
                message: "We couldn't save the PDF. Please try again.",
                onDismiss: nil
            )
        }
    }

    /// Produces a temporary share item for the scanned document.
    private func shareScannedDocument(_ document: ScannedDocument) -> ShareItem? {
        do {
            let shareURL = try PDFStorage.prepareShareURL(for: document)
            return ShareItem(
                url: shareURL,
                cleanupHandler: {
                    try? FileManager.default.removeItem(at: shareURL)
                }
            )
        } catch {
            alertContext = ScanAlert(
                title: "Share Failed",
                message: "We couldn't prepare the PDF for sharing. Please try again.",
                onDismiss: nil
            )
            return nil
        }
    }

    /// Cleans up a staged scan if the user bails out of the preview sheet.
    private func discardTemporaryDocument(_ document: ScannedDocument) {
        pendingDocument = nil
        cleanupTemporaryFile(at: document.pdfURL)
    }

    /// Builds a human-friendly default file name using the date and supplied prefix.
    private func defaultFileName(prefix: String) -> String {
        let timestamp = Self.fileNameFormatter.string(from: Date())
        return "\(prefix) \(timestamp)"
    }

    /// Deletes the temporary PDF sitting in `/tmp` once we no longer need it.
    private func cleanupTemporaryFile(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Performs the on-disk rename and keeps the SwiftUI list in sync.
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

        let previousRecordName = CloudRecordNaming.recordName(for: file.url.lastPathComponent)

        do {
            let renamed = try PDFStorage.rename(file: file, to: trimmed)
            if let index = files.firstIndex(where: { $0.url == file.url }) {
                files[index] = renamed
            }
            renameText = renamed.name
            renameTarget = nil
            Task {
                await cloudBackup.deleteRecord(named: previousRecordName)
                await cloudBackup.backup(file: renamed)
            }
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

/// Lists every saved PDF and surfaces contextual actions per row.
struct FilesView: View {
    // Backed by files persisted in the app's documents directory
    @Binding var files: [PDFFile]
    @State private var searchText = ""
    @StateObject private var contentIndexer = FileContentIndexer()

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
            EmptyFilesView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle("Files")
        } else {
            List {
                Section {
                    searchBar
                }
                .textCase(nil)
                .listRowBackground(Color.clear)

                let results = filteredFiles
                if results.isEmpty {
                    EmptySearchResultsView(query: searchText)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(results) { file in
                        fileRow(for: file)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Files")
            .onChange(of: files) { _, newValue in
                contentIndexer.trimCache(keeping: newValue.map(\.url))
            }
        }
    }

    private func fileRow(for file: PDFFile) -> some View {
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

    private var filteredFiles: [PDFFile] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return files }
        let query = trimmed.lowercased()
        return files.filter { file in
            if file.name.lowercased().contains(query) { return true }
            if let text = contentIndexer.text(for: file) {
                return text.contains(query)
            }
            contentIndexer.ensureTextIndex(for: file)
            return false
        }
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search PDFs", text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        .accessibilityLabel("Search files")
    }
}

/// Friendly onboarding state rendered before the user saves their first PDF.
private struct EmptyFilesView: View {
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

        }
        .padding()
    }
}

/// Message shown when a query returns zero results.
private struct EmptySearchResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(.secondary)

            Text("No matches for \"\(query.trimmingCharacters(in: .whitespacesAndNewlines))\"")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Try a different file name or keyword from the document.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
    }
}

/// Lightweight representation of a PDF stored on disk.
struct PDFFile: Identifiable, Equatable {
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

extension PDFFile {
    static func == (lhs: PDFFile, rhs: PDFFile) -> Bool {
        lhs.url == rhs.url
    }
}

/// File attachment used to build multipart requests for Gotenberg.

/// Temporary PDF built by the scanner/photo flows before persisting.
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
fileprivate struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    let cleanupHandler: (() -> Void)?
}

/// Encapsulates alert metadata posted throughout the scanning pipeline.
private struct ScanAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onDismiss: (() -> Void)?
}

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

/// Result wrapper for `LAContext` authentication requests.
private enum BiometricAuthResult {
    case success
    case failed
    case cancelled
    case unavailable(String)
    case error(String)
}

/// Small helper that normalizes biometric/pascode prompts for previews and settings.
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

/// Floating circular button used to route into creation flows.
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
        .offset(y: -50)
    }
}

// MARK: - Example tab content

/// Settings tab that hosts biometrics, signature management, and static info links.
struct SettingsView: View {
    @StateObject private var subscriptionManager = SubscriptionManager()
    @State private var showSignatureSheet = false
    @State private var savedSignature: SignatureStore.Signature? = SignatureStore.load()
    @SceneStorage("requireBiometrics") private var requireBiometrics = false
    @State private var infoSheet: InfoSheet?
    @State private var shareItem: ShareItem?
    @State private var settingsAlert: SettingsAlert?

    /// Light-weight presentation enum used to drive the FAQ/Terms/Privacy sheets.
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
                SignatureEditorView(signature: $savedSignature)
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
        .onChange(of: savedSignature) { _, newValue in
            if let signature = newValue {
                SignatureStore.save(signature)
            } else {
                SignatureStore.clear()
            }
        }
    }

    private var subscriptionSection: some View {
        Section("Subscription") {
            Button {
                if subscriptionManager.isSubscribed {
                    subscriptionManager.openManageSubscriptions()
                } else {
                    subscriptionManager.purchase()
                }
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.blue.opacity(0.12))
                                .frame(width: 44, height: 44)
                            Image(systemName: subscriptionManager.isSubscribed ? "checkmark.seal" : "sparkles")
                                .font(.headline)
                                .foregroundStyle(.blue)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscriptionManager.isSubscribed ? "PDF Converter Pro Active" : "Upgrade to PDF Converter Pro")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(subscriptionManager.isSubscribed ? "Enjoy unlimited conversions and pro tools" : "Unlock unlimited conversions and pro tools")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if subscriptionManager.isSubscribed {
                        Text("Manage or cancel anytime from your App Store subscriptions.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 56)
                    } else {
                        Text("Start a 1-week ad-free $0.99 subscription, then $9.99/week. Cancel anytime.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 56)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
            }
            .buttonStyle(.plain)

            if subscriptionManager.purchaseState == .purchasing {
                ProgressView("Contacting App Store...")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if case .failed(let message) = subscriptionManager.purchaseState {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
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
                        Text(savedSignature == nil ? "Add signature" : "Update signature")
                        if let savedSignature {
                            Text("Current: \(savedSignature.name)")
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

    // MARK: - Settings Helpers

    /// Requests Face ID/Touch ID authentication before letting the user disable preview protection.
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

/// Alert wrapper used by the settings screen when toggling biometrics fails.
private struct SettingsAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Placeholder account screen showcasing subscription upsell copy.
struct AccountView: View {
    @StateObject private var subscriptionManager = SubscriptionManager()

    private let featureList: [(String, String)] = [
        ("🚀", "Unlimited document conversions"),
        ("📸", "Convert existing photos to PDF"),
        ("📄", "Scan documents to PDF"),
        ("🗂️", "Cloud backup for all your files"),
        ("🖋️", "Advanced editing & annotations"),
        ("🤝", "Priority support & new features")
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    statusSection
                    featuresSection
                    actionButton
                    if case .failed(let message) = subscriptionManager.purchaseState {
                        Text(message)
                            .font(.footnote)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Account")
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subscriptionManager.isSubscribed ? "You're a Pro!" : "Go Pro to unlock more")
                .font(.title2.weight(.semibold))
            Text(subscriptionManager.isSubscribed ? "Thank you for supporting PDF Converter. You currently enjoy every premium feature." : "PDF Converter Pro gives you the power tools to work with any document, anywhere.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subscriptionManager.isSubscribed ? "Your Pro features" : "Unlock these features")
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
        if subscriptionManager.isSubscribed {
            Button {
                subscriptionManager.openManageSubscriptions()
            } label: {
                Label("Manage Subscription", systemImage: "gearshape")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        } else {
            Button {
                subscriptionManager.purchase()
            } label: {
                HStack(spacing: 12) {
                    if subscriptionManager.purchaseState == .purchasing {
                        ProgressView()
                    }
                    Label("Upgrade to Pro now", systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(subscriptionManager.purchaseState == .purchasing)

            Text("Enjoy a 7-day ad-free $0.99 trial, then $9.99/week. Cancel anytime in your App Store subscriptions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Subscriptions

/// StoreKit 2 helper that manages the weekly subscription with a 3-day free trial.
@MainActor
final class SubscriptionManager: ObservableObject {
    enum PurchaseState: Equatable {
        case idle
        case purchasing
        case pending
        case purchased
        case failed(String)
    }

    @Published private(set) var product: Product?
    @Published private(set) var isSubscribed = false
    @Published var purchaseState: PurchaseState = .idle

    private let productID = "com.roguewaveapps.pdfconverter.pro.weekly"

    init() {
        Task { await loadProduct() }
        Task { await monitorEntitlements() }
    }

    /// Initiates the purchase flow for the weekly subscription.
    func purchase() {
        guard purchaseState != .purchasing else { return }
        Task { await purchaseProduct() }
    }

    /// Sends the user to the App Store subscriptions screen to manage/cancel.
    func openManageSubscriptions() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    /// Fetches metadata for the subscription product (price, trial eligibility, etc).
    private func loadProduct() async {
        do {
            let products = try await Product.products(for: [productID])
            product = products.first
        } catch {
            purchaseState = .failed("Unable to load subscription details. \(error.localizedDescription)")
        }
    }

    /// Listens for entitlement changes so UI instantly reflects new subscription states.
    private func monitorEntitlements() async {
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            await updateSubscriptionState(from: entitlement)
        }
    }

    private func updateSubscriptionState(from result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == productID else { return }
            let isActive = transaction.revocationDate == nil &&
                (transaction.expirationDate ?? .distantFuture) > Date()
            isSubscribed = isActive
        case .unverified(_, let error):
            purchaseState = .failed("Verification failed. \(error.localizedDescription)")
        }
    }

    private func purchaseProduct() async {
        guard let product else {
            purchaseState = .failed("Subscription not available. Pull to refresh and try again.")
            return
        }

        purchaseState = .purchasing

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handlePurchaseResult(verification)
            case .pending:
                purchaseState = .pending
            case .userCancelled:
                purchaseState = .idle
            @unknown default:
                purchaseState = .failed("Unknown purchase result.")
            }
        } catch {
            purchaseState = .failed("Purchase failed. \(error.localizedDescription)")
        }
    }

    private func handlePurchaseResult(_ verification: VerificationResult<StoreKit.Transaction>) async {
        switch verification {
        case .verified(let transaction):
            isSubscribed = true
            purchaseState = .purchased
            await transaction.finish()
        case .unverified(_, let error):
            purchaseState = .failed("Verification failed. \(error.localizedDescription)")
        }
    }
}

/// Text-entry sheet that collects the URL before building a placeholder PDF.
struct WebConversionPrompt: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var urlString: String
    let onConvert: (String) async -> Bool
    let onCancel: () -> Void
    @FocusState private var isFieldFocused: Bool
    @State private var isConverting = false
    @State private var conversionError: String?

    var body: some View {
        NavigationView {
            Form {
                Section("Web Page URL") {
                    TextField("https://example.com/article", text: $urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                        .focused($isFieldFocused)
                        .disabled(isConverting)
                }

                Section {
                    Button {
                        performConversion()
                    } label: {
                        Label("Convert", systemImage: "arrow.down.doc")
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConverting)

                    Button("Cancel", role: .cancel, action: cancel)
                        .disabled(isConverting)
                }

                if isConverting {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Converting…")
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                } else if let conversionError {
                    Section {
                        Text(conversionError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Convert Web Page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancel)
                        .disabled(isConverting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert", action: performConversion)
                        .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConverting)
                }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isFieldFocused = true
                }
            }
        }
    }

    /// Validates the text field and hands the url back to `ContentView`.
    private func performConversion() {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isConverting else { return }
        conversionError = nil
        isConverting = true

        Task {
            let success = await onConvert(trimmed)
            await MainActor.run {
                isConverting = false
                if success {
                    dismiss()
                } else {
                    conversionError = "We couldn't convert that page. Check the URL and try again."
                }
            }
        }
    }

    /// Resets state and dismisses the sheet without touching pending documents.
    private func cancel() {
        guard !isConverting else { return }
        onCancel()
        dismiss()
    }
}

/// Local-only error codes raised while writing modified PDFs back to disk.
private enum PDFEditingError: Error {
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

/// Sheet listing existing PDFs so the user can choose one to edit.
struct PDFEditorSelectionView: View {
    @Binding var files: [PDFFile]
    let onSelect: (PDFFile) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sortedFiles = files.sorted { $0.date > $1.date }

        return List {
            if sortedFiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc")
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("No PDFs found")
                        .font(.headline)
                    Text("Add or import a PDF to start editing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 48)
            } else {
                ForEach(sortedFiles) { file in
                    Button {
                        select(file)
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: "doc.richtext")
                                .font(.system(size: 28, weight: .regular))
                                .foregroundStyle(Color.accentColor)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(file.name)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text(file.detailsSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(file.formattedDate)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Choose PDF")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
            }
        }
    }

    /// Dismisses the selector before calling out to the parent view, avoiding sheet conflicts.
    private func select(_ file: PDFFile) {
        dismiss()
        DispatchQueue.main.async {
            onSelect(file)
        }
    }
}

/// Full-screen PDF editor that overlays annotation tools and signature placement.
struct PDFEditorView: View {
    private struct InlineAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let context: PDFEditingContext
    let onSave: () -> Void
    let onCancel: () -> Void

    @StateObject private var controller: PDFEditorController
    @State private var inlineAlert: InlineAlert?
    @State private var cachedSignature: SignatureStore.Signature? = SignatureStore.load()

    init(context: PDFEditingContext, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.context = context
        self.onSave = onSave
        self.onCancel = onCancel
        _controller = StateObject(wrappedValue: PDFEditorController(document: context.document))
    }

    var body: some View {
        ZStack {
            PDFViewRepresentable(pdfView: controller.pdfView)
                .edgesIgnoringSafeArea(.bottom)

            if controller.hasActiveSignaturePlacement() {
                SignaturePlacementOverlay(
                    controller: controller,
                    onConfirm: {
                        if !controller.confirmSignaturePlacement() {
                            inlineAlert = InlineAlert(
                                title: "Placement Failed",
                                message: "We couldn't add the signature to this page. Please try again."
                            )
                        }
                    },
                    onCancel: {
                        controller.cancelSignaturePlacement()
                    }
                )
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .onAppear {
            cachedSignature = SignatureStore.load()
        }
        .navigationTitle(context.file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if controller.hasActiveSignaturePlacement() {
                        controller.cancelSignaturePlacement()
                    }
                    onCancel()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    if controller.hasActiveSignaturePlacement() {
                        if controller.confirmSignaturePlacement() {
                            onSave()
                        } else {
                            inlineAlert = InlineAlert(
                                title: "Placement Failed",
                                message: "We couldn't add the signature to this page. Please try again."
                            )
                        }
                    } else {
                        onSave()
                    }
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    if controller.hasActiveSignaturePlacement() {
                        controller.cancelSignaturePlacement()
                    }

                    cachedSignature = SignatureStore.load()
                    guard let signature = cachedSignature else {
                        inlineAlert = InlineAlert(
                            title: "No Signature Found",
                            message: "Add a signature in Settings before inserting it here."
                        )
                        return
                    }

                    if !controller.beginSignaturePlacement(signature) {
                        inlineAlert = InlineAlert(
                            title: "Can't Insert Signature",
                            message: "Navigate to the page where you want to place the signature, then tap Insert Signature."
                        )
                    }
                } label: {
                    Label("Insert Signature", systemImage: "signature")
                }
                .tint(controller.hasActiveSignaturePlacement() ? .orange : nil)

                Button {
                    if !controller.highlightSelection() {
                        inlineAlert = InlineAlert(
                            title: "Select Text",
                            message: "Select the text you want to highlight, then tap Highlight."
                        )
                    }
                } label: {
                    Label("Highlight", systemImage: "highlighter")
                }

            }
        }
        .alert(item: $inlineAlert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
    }
}

@MainActor
/// Mutable wrapper describing the drag/resize state for a signature being placed on a page.
final class SignaturePlacementState {
    let signature: SignatureStore.Signature
    let uiImage: UIImage
    let page: PDFPage
    var pdfRect: CGRect

    init(signature: SignatureStore.Signature, uiImage: UIImage, page: PDFPage, pdfRect: CGRect) {
        self.signature = signature
        self.uiImage = uiImage
        self.page = page
        self.pdfRect = pdfRect
    }
}

/// UIKit-backed controller that owns the `PDFView` and mutates annotations on the document.
@MainActor
final class PDFEditorController: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    let pdfView: PDFView
    private(set) var signaturePlacement: SignaturePlacementState? {
        didSet { objectWillChange.send() }
    }

    init(document: PDFDocument) {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .systemBackground
        view.usePageViewController(true, withViewOptions: nil)
        pdfView = view
    }

    func beginSignaturePlacement(_ signature: SignatureStore.Signature) -> Bool {
        guard let page = pdfView.currentPage else { return false }
        guard let image = signature.makeImage() else { return false }

        let pageBounds = page.bounds(for: .cropBox)
        let maxWidth = pageBounds.width * 0.5
        let baseWidth = min(max(image.size.width, 10), maxWidth)
        let aspect = image.size.height / max(image.size.width, 1)
        let baseHeight = max(baseWidth * aspect, 10)
        let rect = CGRect(
            x: pageBounds.midX - baseWidth / 2,
            y: pageBounds.midY - baseHeight / 2,
            width: baseWidth,
            height: baseHeight
        )

        signaturePlacement = SignaturePlacementState(signature: signature, uiImage: image, page: page, pdfRect: rect)
        return true
    }

    func viewRectForCurrentPlacement() -> CGRect? {
        guard let placement = signaturePlacement else { return nil }
        return pdfView.convert(placement.pdfRect, from: placement.page)
    }

    func updateSignaturePlacement(viewRect: CGRect) {
        guard let placement = signaturePlacement else { return }
        var pdfRect = pdfView.convert(viewRect, to: placement.page)
        let pageBounds = placement.page.bounds(for: .cropBox)

        pdfRect.size.width = max(min(pdfRect.width, pageBounds.width), 20)
        pdfRect.size.height = max(min(pdfRect.height, pageBounds.height), 20)

        pdfRect.origin.x = min(max(pdfRect.origin.x, pageBounds.minX), pageBounds.maxX - pdfRect.width)
        pdfRect.origin.y = min(max(pdfRect.origin.y, pageBounds.minY), pageBounds.maxY - pdfRect.height)

        placement.pdfRect = pdfRect
        objectWillChange.send()
    }

    func cancelSignaturePlacement() {
        signaturePlacement = nil
    }

    @discardableResult
    func confirmSignaturePlacement() -> Bool {
        guard let placement = signaturePlacement else { return true }
        let annotation = SignatureStampAnnotation(bounds: placement.pdfRect, image: placement.uiImage)
        placement.page.addAnnotation(annotation)
        signaturePlacement = nil
        return true
    }

    func hasActiveSignaturePlacement() -> Bool {
        signaturePlacement != nil
    }

    func addNote() -> Bool {
        guard let page = pdfView.currentPage else { return false }
        let pageBounds = page.bounds(for: .cropBox)
        let size = CGSize(width: 36, height: 36)
        let origin = CGPoint(
            x: pageBounds.midX - size.width / 2,
            y: pageBounds.midY - size.height / 2
        )
        let annotation = PDFAnnotation(bounds: CGRect(origin: origin, size: size), forType: .text, withProperties: nil)
        annotation.contents = "New Note"
        annotation.color = .systemYellow
        page.addAnnotation(annotation)
        return true
    }

    func undoLastAction() -> Bool {
        guard let undoManager = pdfView.undoManager, undoManager.canUndo else { return false }
        undoManager.undo()
        return true
    }

    func highlightSelection(color: UIColor = UIColor.systemYellow.withAlphaComponent(0.35)) -> Bool {
        guard let selection = pdfView.currentSelection else { return false }
        let lineSelections = selection.selectionsByLine()
        guard !lineSelections.isEmpty else { return false }
        var didAdd = false

        for line in lineSelections {
            guard let page = line.pages.first else { continue }
            let bounds = line.bounds(for: page)
            guard !bounds.isEmpty else { continue }
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = color
            page.addAnnotation(annotation)
            didAdd = true
        }

        if didAdd {
            pdfView.setCurrentSelection(nil, animate: false)
        }
        return didAdd
    }
}

/// Wraps a configured `PDFView` so it can live inside SwiftUI hierarchies.
struct PDFViewRepresentable: UIViewRepresentable {
    let pdfView: PDFView

    func makeUIView(context: Context) -> PDFView {
        pdfView
    }

    func updateUIView(_ uiView: PDFView, context: Context) { }
}

/// Interactive overlay that lets the user drag/resize the pending signature before saving.
struct SignaturePlacementOverlay: View {
    @ObservedObject var controller: PDFEditorController
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @State private var dragBaseRect: CGRect?
    @State private var scaleBaseRect: CGRect?

    var body: some View {
        GeometryReader { _ in
            if let placement = controller.signaturePlacement,
               let viewRect = controller.viewRectForCurrentPlacement() {
                let image = placement.uiImage

                let dragGesture = DragGesture()
                    .onChanged { value in
                        if dragBaseRect == nil {
                            dragBaseRect = controller.viewRectForCurrentPlacement() ?? viewRect
                        }
                        guard let base = dragBaseRect else { return }
                        let newRect = base.offsetBy(dx: value.translation.width, dy: value.translation.height)
                        controller.updateSignaturePlacement(viewRect: newRect)
                    }
                    .onEnded { _ in
                        dragBaseRect = nil
                    }

                let magnificationGesture = MagnificationGesture()
                    .onChanged { scale in
                        if scaleBaseRect == nil {
                            scaleBaseRect = controller.viewRectForCurrentPlacement() ?? viewRect
                        }
                        guard let base = scaleBaseRect else { return }
                        let clampedScale = max(scale, 0.2)
                        let width = max(base.width * clampedScale, 20)
                        let height = max(base.height * clampedScale, 20)
                        let center = CGPoint(x: base.midX, y: base.midY)
                        let newRect = CGRect(
                            x: center.x - width / 2,
                            y: center.y - height / 2,
                            width: width,
                            height: height
                        )
                        controller.updateSignaturePlacement(viewRect: newRect)
                    }
                    .onEnded { _ in
                        scaleBaseRect = nil
                    }

                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()

                    Image(uiImage: image)
                        .resizable()
                        .frame(width: viewRect.width, height: viewRect.height)
                        .position(x: viewRect.midX, y: viewRect.midY)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.accentColor.opacity(0.9), lineWidth: 2)
                        )
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                        .gesture(
                            dragGesture
                                .simultaneously(with: magnificationGesture)
                        )

                    HStack(spacing: 16) {
                        Button(role: .cancel) {
                            onCancel()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onConfirm()
                        } label: {
                            Label("Place", systemImage: "checkmark.circle")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .onDisappear {
            dragBaseRect = nil
            scaleBaseRect = nil
        }
    }
}

/// Custom PDF annotation that draws the stored signature image without borders.
final class SignatureStampAnnotation: PDFAnnotation {
    private let signatureImage: UIImage

    init(bounds: CGRect, image: UIImage) {
        self.signatureImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        color = .clear
        border = nil
    }

    required init?(coder: NSCoder) {
        signatureImage = UIImage()
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = signatureImage.cgImage else { return }

        context.saveGState()

        if let page = page {
            context.concatenate(page.transform(for: box))
        }

        let rect = bounds
        context.draw(cgImage, in: rect)

        context.restoreGState()
    }
}

struct CreateSomethingView: View { var body: some View { NavigationView { Text("Create flow").navigationTitle("New Item") } } }

/// Sheet for drawing, naming, and persisting a user's handwritten signature.
struct SignatureEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var signature: SignatureStore.Signature?
    @State private var drawing: PKDrawing
    @State private var signatureName: String
    @State private var showEmptyAlert = false

    init(signature: Binding<SignatureStore.Signature?>) {
        _signature = signature
        let existingSignature = signature.wrappedValue
        _drawing = State(initialValue: existingSignature?.drawing ?? PKDrawing())
        _signatureName = State(initialValue: existingSignature?.name ?? "My Signature")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                SignatureCanvasView(drawing: $drawing)
                    .frame(height: 260)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.05), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Signature Name")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField("My Signature", text: $signatureName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }

                Spacer()

                Text("Use Apple Pencil or your finger to draw your signature. Tap Clear to start over.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(signature == nil ? "Add Signature" : "Update Signature")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSignature() }
                        .disabled(drawing.bounds.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear", role: .destructive) { drawing = PKDrawing() }
                        .disabled(drawing.bounds.isEmpty)
                }
            }
            .alert("Empty Signature", isPresented: $showEmptyAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Please draw your signature before saving.")
            }
        }
    }

    /// Persists the composed signature to `SignatureStore`, validating input first.
    private func saveSignature() {
        guard !drawing.bounds.isEmpty else {
            showEmptyAlert = true
            return
        }

        let trimmedName = signatureName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? "My Signature" : trimmedName
        let existingID = signature?.id ?? UUID()

        let updatedSignature = SignatureStore.Signature(id: existingID, name: resolvedName, drawing: drawing)
        signature = updatedSignature
        dismiss()
    }
}

/// PencilKit canvas wrapper dedicated to collecting signature strokes.
struct SignatureCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.delegate = context.coordinator
        canvas.drawing = drawing
        if #available(iOS 14.0, *) {
            canvas.drawingPolicy = .anyInput
        } else {
            canvas.allowsFingerDrawing = true
        }
        canvas.maximumZoomScale = 1.0
        canvas.minimumZoomScale = 1.0
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.tool = PKInkingTool(.pen, color: .label, width: 5)
        return canvas
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        if uiView.drawing != drawing {
            uiView.drawing = drawing
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(drawing: $drawing)
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        private var drawing: Binding<PKDrawing>

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            drawing.wrappedValue = canvasView.drawing
        }
    }
}

/// Simple persistence helper that stores signatures in `UserDefaults`.
enum SignatureStore {
    private static let storageKey = "SignatureStore.savedSignature"

    /// Value type storing the serialized PencilKit drawing and friendly name.
    struct Signature: Codable, Identifiable, Equatable {
        let id: UUID
        var name: String
        private var drawingData: Data

        init(id: UUID = UUID(), name: String, drawing: PKDrawing) {
            self.id = id
            self.name = name
            self.drawingData = drawing.dataRepresentation()
        }

        var drawing: PKDrawing {
            get {
                (try? PKDrawing(data: drawingData)) ?? PKDrawing()
            }
            set {
                drawingData = newValue.dataRepresentation()
            }
        }

        func makeImage(scale: CGFloat = UIScreen.main.scale) -> UIImage? {
            let bounds = drawing.bounds
            guard !bounds.isEmpty else { return nil }

            let resolvedScale = max(scale, UIScreen.main.scale)
            return drawing.image(from: bounds, scale: resolvedScale)
        }
    }

    static func load() -> Signature? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Signature.self, from: data)
    }

    static func save(_ signature: Signature) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(signature) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}

/// Grid of high-level conversion/editing shortcuts surfaced on the Tools tab.
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

/// Lets the user preview, rename, share, or save a freshly generated PDF.
struct ScanReviewSheet: View {
    let document: ScannedDocument
    let onSave: (ScannedDocument) -> Void
    fileprivate let onShare: (ScannedDocument) -> ShareItem?
    let onCancel: (ScannedDocument) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var fileName: String
    @State private var shareItem: ShareItem?

    fileprivate init(
        document: ScannedDocument,
        onSave: @escaping (ScannedDocument) -> Void,
        onShare: @escaping (ScannedDocument) -> ShareItem?,
        onCancel: @escaping (ScannedDocument) -> Void
    ) {
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
                        if let item = onShare(updated) {
                            shareItem = item
                        }
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
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url]) {
                item.cleanupHandler?()
                shareItem = nil
            }
        }
    }

    /// Returns a sanitized copy to avoid saving with trailing spaces or empty names.
    private func sanitizedDocument() -> ScannedDocument {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return document }
        return document.withFileName(trimmed)
    }
}

/// Minimal PDFKit wrapper for displaying PDFs inside SwiftUI previews.
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

struct SavedPDFDetailView: View {
    let file: PDFFile

    var body: some View {
        PDFPreviewView(url: file.url)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
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

/// Bridges `VNDocumentCameraViewController` into SwiftUI while normalizing results.
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

/// PHPicker wrapper that returns the selected images via a Swift Result type.
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

/// Utility responsible for stitching captured images into a temporary PDF file.
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

/// Handles persistence, imports, and file system hygiene for saved PDFs.
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

    static func storeCloudAsset(from sourceURL: URL, preferredName: String) throws -> PDFFile {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed("Unable to access the Documents folder.")
        }

        let baseName = sanitizeFileName(preferredName)
        let destination = uniqueURL(for: baseName, in: directory)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
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

/// Actor-backed thumbnail cache so thumbnail rendering never blocks SwiftUI updates.
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

/// Renders a single colorful tool card and routes taps back to `ToolsView`.
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

/// Metadata describing each tool tile, including colors and destination action.
struct ToolCard: Identifiable {
    let id = UUID()
    let title: String
    let tint: Color
    let iconName: String
    let action: ToolAction?
}

extension ToolCard {
    static let sample: [ToolCard] = [
        .init(title: "Convert\nFiles to PDF",
              tint: Color(hex: 0x2F7F79),
              iconName: "infinity",
              action: .convertFiles),
        .init(title: "Scan\nDocuments",
              tint: Color(hex: 0xC02267),
              iconName: "camera",
              action: .scanDocuments),
        .init(title: "Convert\nPhotos to PDF",
              tint: Color(hex: 0x5C3A78),
              iconName: "photo.on.rectangle",
              action: .convertPhotos),
        .init(title: "Import\nDocuments",
              tint: Color(hex: 0x6C8FC0),
              iconName: "arrow.down.to.line",
              action: .importDocuments),
        .init(title: "Convert\nWeb Page",
              tint: Color(hex: 0xBF7426),
              iconName: "link",
              action: .convertWebPage),
        .init(title: "Edit\nDocuments",
              tint: Color(hex: 0x7B3DD3),
              iconName: "pencil.and.outline",
              action: .editDocuments)
    ]
}

// MARK: - Small Color helper

/// Convenience initializer for building SwiftUI colors from hex literals.
extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Helpers

/// Lazily indexes text content for PDFs so search queries can match body text.
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
