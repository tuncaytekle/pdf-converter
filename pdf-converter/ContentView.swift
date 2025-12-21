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

    @StateObject private var subscriptionManager = SubscriptionManager()
    @State private var selection: Tab = .files
    @State private var showCreateActions = false
    @State private var files: [PDFFile] = []
    @State private var folders: [PDFFolder] = []
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
    @State private var deleteFolderTarget: PDFFolder?
    @State private var showDeleteFolderDialog = false
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
    @State private var showPaywall = false
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    @State private var hasCheckedPaywall = false
    @SceneStorage("requireBiometrics") private var requireBiometrics = false
    @Environment(\.colorScheme) private var scheme
    @State private var hasAttemptedCloudRestore = false

    var body: some View {
        Group {
            if hasCheckedPaywall && !showPaywall {
                rootContent
            } else {
                Color.white.ignoresSafeArea()
            }
        }
        .onAppear(perform: checkPaywallAndLoadFiles)
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
        .confirmationDialog(NSLocalizedString("dialog.deletePDF.title", comment: "Delete PDF confirmation"), isPresented: $showDeleteDialog, presenting: deleteTarget) { file in
            Button(role: .destructive) {
                deleteFile(file)
            } label: {
                Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) {
                deleteTarget = nil
                showDeleteDialog = false
            }
        } message: { file in
            Text(String(format: NSLocalizedString("dialog.deletePDF.message", comment: "Delete PDF message"), file.name))
        }
        .confirmationDialog(
            NSLocalizedString("dialog.deleteFolder.title", comment: "Delete folder confirmation title"),
            isPresented: $showDeleteFolderDialog,
            presenting: deleteFolderTarget
        ) { folder in
            Button(role: .destructive) {
                deleteFolderAction(folder)
            } label: {
                Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) {
                deleteFolderTarget = nil
                showDeleteFolderDialog = false
            }
        } message: { folder in
            let fileCount = files.filter { $0.folderId == folder.id }.count
            Text(String(format: NSLocalizedString("dialog.deleteFolder.message", comment: "Delete folder message"), fileCount))
        }
        .alert(item: $alertContext) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))) {
                    alertContext = nil
                    context.onDismiss?()
                }
            )
        }
        .fullScreenCover(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(subscriptionManager)
        }
        .onChange(of: showPaywall) { _, isShowing in
            // When paywall is dismissed after onboarding flow, mark onboarding as completed
            if !isShowing && !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlowView(isPresented: $showOnboarding)
        }
        .onChange(of: showOnboarding) { _, isShowing in
            // When onboarding flow is dismissed on first launch, show paywall
            if !isShowing && !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                showPaywall = true
            }
        }
        .confirmationDialog("", isPresented: $showCreateActions, titleVisibility: .hidden) {
            Button { scanDocumentsToPDF() } label: {
                Label(NSLocalizedString("action.scanDocuments", comment: "Scan documents to PDF"), systemImage: "doc.text.viewfinder")
            }
            Button { convertPhotosToPDF() } label: {
                Label(NSLocalizedString("action.convertPhotos", comment: "Convert photos to PDF"), systemImage: "photo.on.rectangle")
            }
            Button { convertFilesToPDF() } label: {
                Label(NSLocalizedString("action.convertFiles", comment: "Convert files to PDF"), systemImage: "folder")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) { }
        }
        .overlay {
            if isConvertingFile {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(NSLocalizedString("status.converting", comment: "Conversion in progress"))
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

            if selection == .files {
                floatingCreateButton
            }
        }
    }

    /// Hosts the four main tabs and wires callbacks back into `ContentView`.
    private var tabInterface: some View {
        TabView(selection: $selection) {
            FilesView(
                files: $files,
                folders: $folders,
                onPreview: { previewSavedFile($0) },
                onShare: { shareSavedFile($0) },
                onRename: { beginRenamingFile($0) },
                onDelete: { confirmDeletion(for: $0) },
                onDeleteFolder: { confirmFolderDeletion(for: $0) },
                cloudBackup: cloudBackup
            )
            .tabItem { Label(NSLocalizedString("tab.files", comment: "Files tab label"), systemImage: "doc") }
            .tag(Tab.files)

            ToolsView(onAction: handleToolAction)
                .tabItem { Label(NSLocalizedString("tab.tools", comment: "Tools tab label"), systemImage: "wrench.and.screwdriver") }
                .tag(Tab.tools)

            SettingsView()
                .tabItem { Label(NSLocalizedString("tab.settings", comment: "Settings tab label"), systemImage: "gearshape") }
                .tag(Tab.settings)

            AccountView()
                .tabItem { Label(NSLocalizedString("tab.account", comment: "Account tab label"), systemImage: "person.crop.circle") }
                .tag(Tab.account)
        }
        .onChange(of: selection) { _, _ in
            UISelectionFeedbackGenerator().selectionChanged()
        }
    }

    /// Floating action button anchored to the bottom bar that surfaces quick actions.
    private var floatingCreateButton: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                Menu {
                    Button {
                        scanDocumentsToPDF()
                    } label: {
                        Label(NSLocalizedString("action.scanDocuments", comment: "Scan documents to PDF"), systemImage: "doc.text.viewfinder")
                    }

                    Button {
                        convertPhotosToPDF()
                    } label: {
                        Label(NSLocalizedString("action.convertPhotos", comment: "Convert photos to PDF"), systemImage: "photo.on.rectangle")
                    }

                    Button {
                        convertFilesToPDF()
                    } label: {
                        Label(NSLocalizedString("action.convertFiles", comment: "Convert files to PDF"), systemImage: "folder")
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 64, height: 64)
                            .shadow(radius: 6, y: 2)

                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel(NSLocalizedString("accessibility.create", comment: "Create button"))
                    .scaleEffect(createButtonPulse ? 1.12 : 1)
                    .shadow(color: Color.blue.opacity(createButtonPulse ? 0.5 : 0.25), radius: createButtonPulse ? 24 : 8, y: createButtonPulse ? 12 : 2)
                    .task {
                        await animateCreateButtonCueIfNeeded()
                    }
                    .onTapGesture {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        createButtonPulse = false
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.trailing, 28)
            .padding(.bottom, 60)
        }
        // Taps outside the button should fall through to the tab bar underneath.
        .allowsHitTesting(true)
    }
    
    // MARK: - Quick Action Routing

    /// Presents the document camera flow when the hardware supports it.
    private func scanDocumentsToPDF() {
        guard VNDocumentCameraViewController.isSupported else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.scannerUnavailable.title", comment: "Scanner unavailable title"),
                message: NSLocalizedString("alert.scannerUnavailable.message", comment: "Scanner unavailable message"),
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

        let animation = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
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
                title: NSLocalizedString("alert.noPDFs.title", comment: "No PDFs available title"),
                message: NSLocalizedString("alert.noPDFs.message", comment: "No PDFs available message"),
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
                title: NSLocalizedString("alert.openFailed.title", comment: "Open failed title"),
                message: NSLocalizedString("alert.openFailed.message", comment: "Open failed message"),
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
                title: NSLocalizedString("alert.saveFailed.title", comment: "Save failed title"),
                message: NSLocalizedString("alert.saveFailed.message", comment: "Save failed message"),
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
        let result = await BiometricAuthenticator.authenticate(reason: NSLocalizedString("biometrics.reason.preview", comment: "Reason for biometric prompt"))

        switch result {
        case .success:
            handleBiometricResult(granted: true, file: file)
        case .failed:
            handleBiometricResult(granted: false, file: file)
        case .cancelled:
            break
        case .unavailable(let message):
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.authUnavailable.title", comment: "Authentication unavailable title"),
                message: message,
                onDismiss: nil
            )
        case .error(let message):
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.authError.title", comment: "Authentication error title"),
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
                title: NSLocalizedString("alert.authFailed.title", comment: "Authentication failed title"),
                message: NSLocalizedString("alert.authFailed.message", comment: "Authentication failed message"),
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
                title: NSLocalizedString("alert.deleteFailed.title", comment: "Delete failed title"),
                message: NSLocalizedString("alert.deleteFailed.message", comment: "Delete failed message"),
                onDismiss: {
                    deleteTarget = nil
                    showDeleteDialog = false
                }
            )
        }
    }

    /// Stores the pending folder deletion target and presents the destructive dialog.
    private func confirmFolderDeletion(for folder: PDFFolder) {
        deleteFolderTarget = folder
        showDeleteFolderDialog = true
    }

    /// Deletes a folder and all its files from storage.
    private func deleteFolderAction(_ folder: PDFFolder) {
        // Get all files in the folder before deletion
        let filesInFolder = files.filter { $0.folderId == folder.id }

        withAnimation(.easeInOut(duration: 0.3)) {
            // Delete each file
            for file in filesInFolder {
                try? FileManager.default.removeItem(at: file.url)
            }

            // Remove files from the array
            files.removeAll { $0.folderId == folder.id }

            // Remove the folder
            folders.removeAll { $0.id == folder.id }

            // Save updated folders list
            PDFStorage.saveFolders(folders)
        }

        // Delete from CloudKit
        Task {
            await cloudBackup.deleteFolder(folder)
            // Also delete all files in the folder from CloudKit
            for file in filesInFolder {
                await cloudBackup.deleteBackup(for: file)
            }
        }

        deleteFolderTarget = nil
        showDeleteFolderDialog = false
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
                        title: NSLocalizedString("alert.noImport.title", comment: "No PDFs imported title"),
                        message: NSLocalizedString("alert.noImport.message", comment: "No PDFs imported message"),
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
                    title: NSLocalizedString("alert.importComplete.title", comment: "Import complete title"),
                    message: imported.count == 1
                        ? NSLocalizedString("alert.importComplete.single", comment: "Single PDF imported message")
                        : String(format: NSLocalizedString("alert.importComplete.multiple", comment: "Multiple PDFs imported message"), imported.count),
                    onDismiss: nil
                )
            } catch {
                alertContext = ScanAlert(
                    title: NSLocalizedString("alert.importFailed.title", comment: "Import failed title"),
                    message: NSLocalizedString("alert.importFailed.message", comment: "Import failed message"),
                    onDismiss: nil
                )
            }
        case .failure(let error):
            if let nsError = error as NSError?, nsError.code == NSUserCancelledError {
                // user cancelled, no action
                return
            }
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.importFailed.title", comment: "Import failed title"),
                message: NSLocalizedString("alert.importAccessFailed.message", comment: "Import file access failed message"),
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
                title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
                message: NSLocalizedString("alert.conversionFileAccessFailed.message", comment: "Conversion access failed message"),
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
                    fileName: String(format: NSLocalizedString("converted.fileNameFormat", comment: "Converted file name format"), baseName)
                )
            }
        } catch {
            await MainActor.run {
                alertContext = ScanAlert(
                    title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
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
                title: NSLocalizedString("alert.invalidURL.title", comment: "Invalid URL title"),
                message: NSLocalizedString("alert.invalidURL.message", comment: "Invalid URL message"),
                onDismiss: nil
            )
            return false
        }

        guard let resolvedURL = normalizedWebURL(from: trimmed) else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.invalidURL.title", comment: "Invalid URL title"),
                message: NSLocalizedString("alert.invalidURL.unrecognized", comment: "Invalid URL unrecognized message"),
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
            ?? NSLocalizedString("webPrompt.defaultName", comment: "Default web host name")

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
                    title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
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

    /// Checks if paywall should be shown, then loads cached PDFs
    private func checkPaywallAndLoadFiles() {
        // Check if we should show the paywall (onboarding is now handled at initialization)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if hasCompletedOnboarding && subscriptionManager.shouldShowPaywall {
            showPaywall = true
        }

        // Mark that we've checked, allowing main content to render
        hasCheckedPaywall = true

        // Then load files if not already loaded
        guard !hasLoadedInitialFiles else { return }
        refreshFilesFromDisk()
        hasLoadedInitialFiles = true
        attemptCloudRestoreIfNeeded()
    }

    /// Rebuilds the in-memory file list from whatever is stored on disk.
    private func refreshFilesFromDisk() {
        files = PDFStorage.loadSavedFiles().sorted { $0.date > $1.date }
        folders = PDFStorage.loadFolders()
    }

    /// Fetches any remote backups and merges them into the local library once.
    private func attemptCloudRestoreIfNeeded() {
        guard !hasAttemptedCloudRestore else { return }
        hasAttemptedCloudRestore = true
        Task {
            // DIAGNOSTIC: Check CloudKit environment and records
            await cloudBackup.printEnvironmentDiagnostics()
            _ = await cloudBackup.fetchAllRecordsWithoutQuery()

            // Restore folders
            let existingFolderIds = Set(PDFStorage.loadFolders().map { $0.id })
            let restoredFolders = await cloudBackup.restoreMissingFolders(existingFolderIds: existingFolderIds)
            if !restoredFolders.isEmpty {
                var folders = PDFStorage.loadFolders()
                folders.append(contentsOf: restoredFolders)
                PDFStorage.saveFolders(folders)
            }

            // Restore files
            let existingNames = Set(files.map { CloudRecordNaming.recordName(for: $0.url.lastPathComponent) })
            let restored = await cloudBackup.restoreMissingFiles(existingRecordNames: existingNames)
            guard !restored.isEmpty else { return }

            // Get file-folder mappings from CloudKit
            let mappings = await cloudBackup.getFileFolderMappings()

            // Apply folder mappings to restored files
            let restoredWithFolders = restored.map { file -> PDFFile in
                let fileName = file.url.lastPathComponent
                let folderId = mappings[fileName]
                return PDFFile(
                    url: file.url,
                    name: file.name,
                    date: file.date,
                    pageCount: file.pageCount,
                    fileSize: file.fileSize,
                    folderId: folderId
                )
            }

            // Save folder mappings for restored files
            for file in restoredWithFolders {
                if let folderId = file.folderId {
                    PDFStorage.updateFileFolderId(file: file, folderId: folderId)
                }
            }

            await MainActor.run {
                files.append(contentsOf: restoredWithFolders)
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
                    title: NSLocalizedString("alert.noPages.title", comment: "No pages captured title"),
                    message: NSLocalizedString("alert.noPages.message", comment: "No pages captured message"),
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
                    title: NSLocalizedString("alert.pdfError.title", comment: "PDF error title"),
                    message: NSLocalizedString("alert.pdfError.message", comment: "PDF error message"),
                    onDismiss: nil
                )
            }
        case .failure(let error):
            if error.shouldDisplayAlert {
                alertContext = ScanAlert(
                    title: NSLocalizedString("alert.scanFailed.title", comment: "Scan failed title"),
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
                title: NSLocalizedString("alert.savePDFFailed.title", comment: "Save PDF failed title"),
                message: NSLocalizedString("alert.savePDFFailed.message", comment: "Save PDF failed message"),
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
                title: NSLocalizedString("alert.shareFailed.title", comment: "Share failed title"),
                message: NSLocalizedString("alert.shareFailed.message", comment: "Share failed message"),
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
                title: NSLocalizedString("alert.invalidName.title", comment: "Invalid name title"),
                message: NSLocalizedString("alert.invalidName.message", comment: "Invalid name message"),
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
                title: NSLocalizedString("alert.renameFailed.title", comment: "Rename failed title"),
                message: NSLocalizedString("alert.renameFailed.message", comment: "Rename failed message"),
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
/// Sorting criteria for file list
enum FileSortType {
    case date, name
}

/// Sort direction for file list
enum SortDirection {
    case ascending, descending
}

struct FilesView: View {
    // Backed by files persisted in the app's documents directory
    @Binding var files: [PDFFile]
    @Binding var folders: [PDFFolder]
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sortType: FileSortType = .date
    @State private var sortDirection: SortDirection = .descending
    @State private var currentFolderId: String? = nil // nil means at top level
    @State private var showCreateFolderDialog = false
    @State private var newFolderName = ""
    @State private var moveFileToFolder: PDFFile? = nil
    @State private var showRenameFolderDialog = false
    @State private var renameFolderTarget: PDFFolder? = nil
    @State private var renameFolderName = ""
    @StateObject private var contentIndexer = FileContentIndexer()
    @StateObject private var subscriptionManager = SubscriptionManager()

    let onPreview: (PDFFile) -> Void
    let onShare: (PDFFile) -> Void
    let onRename: (PDFFile) -> Void
    let onDelete: (PDFFile) -> Void
    let onDeleteFolder: (PDFFolder) -> Void
    let cloudBackup: CloudBackupManager
    private let thumbnailSize = CGSize(width: 58, height: 78)

    var body: some View {
        NavigationView {
            filesContent
                .toolbar {
                    if currentFolderId != nil {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button {
                                currentFolderId = nil
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text(NSLocalizedString("files.title", comment: "Files navigation title"))
                                }
                            }
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        ProButton(subscriptionManager: subscriptionManager)
                    }
                    .hideSharedBackground
                }
                .sheet(isPresented: $showCreateFolderDialog) {
                    createFolderDialog
                }
                .sheet(item: $moveFileToFolder) { file in
                    moveToFolderDialog(for: file)
                }
                .sheet(isPresented: $showRenameFolderDialog) {
                    renameFolderDialog
                }
        }
    }

    @ViewBuilder
    private var filesContent: some View {
        if files.isEmpty {
            EmptyFilesView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground))
                .navigationTitle(NSLocalizedString("files.title", comment: "Files navigation title"))
        } else {
            List {
                Section {
                    searchBar
                }
                .textCase(nil)
                .listRowBackground(Color.clear)

                Section {
                    sortingToolbar
                }
                .textCase(nil)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                // Show folders first (only at top level when not searching)
                if currentFolderId == nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(folders) { folder in
                        folderRow(for: folder)
                    }
                }

                // Show files
                let results = filteredFiles
                if results.isEmpty && (currentFolderId != nil || !folders.isEmpty) {
                    if !searchText.isEmpty {
                        EmptySearchResultsView(query: searchText)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    ForEach(results) { file in
                        fileRow(for: file)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(currentFolderName)
            .navigationBarTitleDisplayMode(currentFolderId == nil ? .large : .inline)
            .onChange(of: files) { _, newValue in
                contentIndexer.trimCache(keeping: newValue.map(\.url))
            }
        }
    }

    private var currentFolderName: String {
        guard let folderId = currentFolderId,
              let folder = folders.first(where: { $0.id == folderId }) else {
            return NSLocalizedString("files.title", comment: "Files navigation title")
        }
        return folder.name
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
                Button {
                    onPreview(file)
                } label: {
                    Label(NSLocalizedString("action.preview", comment: "Preview action"), systemImage: "eye.fill")
                }

                Button {
                    onShare(file)
                } label: {
                    Label(NSLocalizedString("action.share", comment: "Share action"), systemImage: "square.and.arrow.up")
                }

                Button {
                    onRename(file)
                } label: {
                    Label(NSLocalizedString("action.rename", comment: "Rename action"), systemImage: "pencil")
                }

                Divider()

                Menu {
                    Button(NSLocalizedString("folder.topLevel", comment: "Top level folder")) {
                        moveFile(file, to: nil)
                    }
                    ForEach(folders) { folder in
                        Button(folder.name) {
                            moveFile(file, to: folder.id)
                        }
                    }
                } label: {
                    Label(NSLocalizedString("action.moveToFolder", comment: "Move to folder"), systemImage: "folder")
                }

                Divider()

                Button(role: .destructive) {
                    onDelete(file)
                } label: {
                    Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .accessibilityLabel(NSLocalizedString("accessibility.moreActions", comment: "More actions menu"))
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
        let isSearching = !trimmed.isEmpty

        // When searching, search across ALL folders; otherwise filter by current folder
        let folderFiltered: [PDFFile]
        if isSearching {
            // Search globally across all folders
            folderFiltered = files
        } else {
            // Only show files in current folder
            folderFiltered = files.filter { file in
                file.folderId == currentFolderId
            }
        }

        // Apply search filter
        let filtered: [PDFFile]
        if trimmed.isEmpty {
            filtered = folderFiltered
        } else {
            let query = trimmed.lowercased()
            filtered = folderFiltered.filter { file in
                if file.name.lowercased().contains(query) { return true }
                if let text = contentIndexer.text(for: file) {
                    return text.contains(query)
                }
                contentIndexer.ensureTextIndex(for: file)
                return false
            }
        }

        // Apply sorting
        let sorted = filtered.sorted { file1, file2 in
            switch sortType {
            case .date:
                return sortDirection == .ascending ? file1.date < file2.date : file1.date > file2.date
            case .name:
                return sortDirection == .ascending ? file1.name < file2.name : file1.name > file2.name
            }
        }

        return sorted
    }

    private func folderRow(for folder: PDFFolder) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "folder.fill")
                .font(.system(size: 42))
                .foregroundColor(.blue)
                .frame(width: thumbnailSize.width, height: thumbnailSize.height)

            VStack(alignment: .leading, spacing: 6) {
                Text(folder.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                let filesInFolder = files.filter { $0.folderId == folder.id }
                let fileCount = filesInFolder.count
                Text(fileCount == 1 ?
                    NSLocalizedString("folder.fileCount.single", comment: "1 file") :
                    String(format: NSLocalizedString("folder.fileCount.multiple", comment: "Multiple files"), fileCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                let totalSize = filesInFolder.reduce(0) { $0 + $1.fileSize }
                Text(PDFFile.sizeFormatter.string(fromByteCount: totalSize))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            Menu {
                Button {
                    beginRenamingFolder(folder)
                } label: {
                    Label(NSLocalizedString("action.rename", comment: "Rename action"), systemImage: "pencil")
                }

                Divider()

                Button(role: .destructive) {
                    onDeleteFolder(folder)
                } label: {
                    Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .accessibilityLabel(NSLocalizedString("accessibility.moreActions", comment: "More actions menu"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            currentFolderId = folder.id
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                onDeleteFolder(folder)
            } label: {
                Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
            }
        }
        .padding(.vertical, 10)
    }

    private func moveFile(_ file: PDFFile, to folderId: String?) {
        // Update storage
        PDFStorage.updateFileFolderId(file: file, folderId: folderId)

        // Create updated file with new folder ID
        let updatedFile = PDFFile(
            url: file.url,
            name: file.name,
            date: file.date,
            pageCount: file.pageCount,
            fileSize: file.fileSize,
            folderId: folderId
        )

        // Update array by filtering out old file and adding updated one
        // This creates a structural change SwiftUI can detect
        withAnimation(.easeInOut(duration: 0.3)) {
            // Remove the old file
            files.removeAll(where: { $0.id == file.id })
            // Add the updated file
            files.append(updatedFile)
        }

        // Update CloudKit backup with new folder ID
        Task {
            await cloudBackup.backup(file: updatedFile)
        }
    }


    private var createFolderDialog: some View {
        NavigationView {
            Form {
                Section {
                    TextField(NSLocalizedString("folder.name.placeholder", comment: "Folder name placeholder"), text: $newFolderName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(NSLocalizedString("folder.new.title", comment: "New folder title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
                        showCreateFolderDialog = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.save", comment: "Save action")) {
                        createFolder()
                    }
                    .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var renameFolderDialog: some View {
        NavigationView {
            Form {
                Section {
                    TextField(NSLocalizedString("folder.name.placeholder", comment: "Folder name placeholder"), text: $renameFolderName)
                        .textInputAutocapitalization(.words)
                }
            }
            .navigationTitle(NSLocalizedString("folder.rename.title", comment: "Rename folder title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
                        showRenameFolderDialog = false
                        renameFolderTarget = nil
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.save", comment: "Save action")) {
                        renameFolder()
                    }
                    .disabled(renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func moveToFolderDialog(for file: PDFFile) -> some View {
        NavigationView {
            List {
                Button(NSLocalizedString("folder.topLevel", comment: "Top level folder")) {
                    moveFile(file, to: nil)
                    moveFileToFolder = nil
                }

                ForEach(folders) { folder in
                    Button(folder.name) {
                        moveFile(file, to: folder.id)
                        moveFileToFolder = nil
                    }
                }
            }
            .navigationTitle(NSLocalizedString("folder.move.title", comment: "Move to folder title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
                        moveFileToFolder = nil
                    }
                }
            }
        }
    }

    private func createFolder() {
        let trimmedName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newFolder = PDFFolder(name: trimmedName)
        folders.append(newFolder)
        PDFStorage.saveFolders(folders)

        // Backup folder to CloudKit
        Task {
            await cloudBackup.backupFolder(newFolder)
        }

        showCreateFolderDialog = false
        newFolderName = ""
    }

    private func beginRenamingFolder(_ folder: PDFFolder) {
        renameFolderTarget = folder
        renameFolderName = folder.name
        showRenameFolderDialog = true
    }

    private func renameFolder() {
        guard let folder = renameFolderTarget else { return }
        let trimmedName = renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        // Find and update the folder in the array
        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            let updatedFolder = PDFFolder(id: folder.id, name: trimmedName)
            folders[index] = updatedFolder
            PDFStorage.saveFolders(folders)

            // Update folder in CloudKit
            Task {
                await cloudBackup.backupFolder(updatedFolder)
            }
        }

        showRenameFolderDialog = false
        renameFolderTarget = nil
        renameFolderName = ""
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(NSLocalizedString("search.placeholder", comment: "Search placeholder"), text: $searchText)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .focused($isSearchFocused)

            if isSearchFocused || !searchText.isEmpty {
                Button {
                    searchText = ""
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("accessibility.clearSearch", comment: "Clear search accessibility label"))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 4, trailing: 0))
        .accessibilityLabel(NSLocalizedString("accessibility.searchFiles", comment: "Search files accessibility label"))
    }

    private var sortingToolbar: some View {
        HStack(spacing: 12) {
            // Left side - Sorting controls
            HStack(spacing: 8) {
                // Sort type picker
                Menu {
                    Button {
                        sortType = .date
                    } label: {
                        Label(NSLocalizedString("sort.date", comment: "Sort by date"), systemImage: sortType == .date ? "checkmark" : "")
                    }
                    Button {
                        sortType = .name
                    } label: {
                        Label(NSLocalizedString("sort.name", comment: "Sort by name"), systemImage: sortType == .name ? "checkmark" : "")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: sortType == .date ? "calendar" : "textformat.abc")
                            .font(.system(size: 14))
                        Text(sortType == .date ? NSLocalizedString("sort.date", comment: "Sort by date") : NSLocalizedString("sort.name", comment: "Sort by name"))
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(.systemGray5))
                    )
                }

                // Sort direction button
                Button {
                    sortDirection = sortDirection == .ascending ? .descending : .ascending
                } label: {
                    Image(systemName: sortDirection == .ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 14))
                        .foregroundColor(.primary)
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(.systemGray5))
                        )
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Right side - Create folder button
            Button {
                newFolderName = ""
                showCreateFolderDialog = true
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.blue.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
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

            Text(NSLocalizedString("emptyFiles.title", comment: "Empty files title"))
                .font(.title3.weight(.semibold))

            Text(NSLocalizedString("emptyFiles.message", comment: "Empty files message"))
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

            Text(String(format: NSLocalizedString("search.empty.title", comment: "No matches title"), query.trimmingCharacters(in: .whitespacesAndNewlines)))
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(NSLocalizedString("search.empty.message", comment: "No matches message"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 20)
        .padding(.horizontal, 12)
    }
}

/// Represents a folder that can contain PDF files
struct PDFFolder: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    let createdDate: Date

    init(id: String = UUID().uuidString, name: String, createdDate: Date = Date()) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
    }
}

/// Lightweight representation of a PDF stored on disk.
struct PDFFile: Identifiable, Equatable {
    let url: URL
    var name: String
    let date: Date
    let pageCount: Int
    let fileSize: Int64
    var folderId: String? // ID of the folder this file belongs to, nil if at top level

    var id: URL { url }

    var formattedDate: String {
        Self.dateFormatter.string(from: date)
    }

    var pageSummary: String {
        let count = max(pageCount, 0)
        return count == 1 ? NSLocalizedString("1 Page", comment: "Page count for single page") : String(format: NSLocalizedString("%d Pages", comment: "Page count for multiple pages"), count)
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

    fileprivate static let sizeFormatter: ByteCountFormatter = {
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
            return NSLocalizedString("scanError.cancelled", comment: "Scan cancelled message")
        case .unavailable:
            return NSLocalizedString("scanError.unavailable", comment: "Scanning unavailable message")
        case .noImages:
            return NSLocalizedString("scanError.noImages", comment: "No images selected message")
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
        biometricContext.localizedFallbackTitle = NSLocalizedString("biometrics.fallback", comment: "Fallback button title")

        var biometricError: NSError?
        let canUseBiometrics = biometricContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError)

        let fallbackContext = LAContext()
        var passcodeError: NSError?
        let canUsePasscode = fallbackContext.canEvaluatePolicy(.deviceOwnerAuthentication, error: &passcodeError)

        guard canUseBiometrics || canUsePasscode else {
            let message = biometricError?.localizedDescription
                ?? passcodeError?.localizedDescription
                ?? NSLocalizedString("biometrics.unavailable.message", comment: "Biometrics unavailable message")
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
            case .faq: return NSLocalizedString("settings.info.faq", comment: "FAQ title")
            case .terms: return NSLocalizedString("settings.info.terms", comment: "Terms title")
            case .privacy: return NSLocalizedString("settings.info.privacy", comment: "Privacy title")
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
            .navigationTitle(NSLocalizedString("settings.title", comment: "Settings navigation title"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProButton(subscriptionManager: subscriptionManager)
                }
                .hideSharedBackground
            }
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
                            Button(NSLocalizedString("action.done", comment: "Done action")) { infoSheet = nil }
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
                    dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))) {
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
        Section(NSLocalizedString("settings.subscription.section", comment: "Subscription section title")) {
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
                            Text(subscriptionManager.isSubscribed ? NSLocalizedString("settings.subscription.activeTitle", comment: "Active subscription title") : NSLocalizedString("settings.subscription.upsellTitle", comment: "Upsell subscription title"))
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(subscriptionManager.isSubscribed ? NSLocalizedString("settings.subscription.activeSubtitle", comment: "Active subscription subtitle") : NSLocalizedString("settings.subscription.upsellSubtitle", comment: "Upsell subscription subtitle"))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if subscriptionManager.isSubscribed {
                        Text(NSLocalizedString("settings.subscription.manageCopy", comment: "Manage subscription copy"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 56)
                    } else {
                        Text(NSLocalizedString("settings.subscription.trialCopy", comment: "Subscription trial copy"))
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
                ProgressView(NSLocalizedString("settings.subscription.progress", comment: "Contacting App Store text"))
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
        Section(NSLocalizedString("settings.general.section", comment: "Settings section title")) {
            Button {
                showSignatureSheet = true
            } label: {
                HStack {
                    Image(systemName: "signature")
                    VStack(alignment: .leading) {
                        Text(savedSignature == nil ? NSLocalizedString("settings.signature.add", comment: "Add signature") : NSLocalizedString("settings.signature.update", comment: "Update signature"))
                        if let savedSignature {
                            Text(String(format: NSLocalizedString("settings.signature.current", comment: "Current signature template"), savedSignature.name))
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
                    Text(NSLocalizedString("settings.biometrics.title", comment: "Require biometrics title"))
                    Text(NSLocalizedString("settings.biometrics.subtitle", comment: "Require biometrics subtitle"))
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
        let result = await BiometricAuthenticator.authenticate(reason: NSLocalizedString("biometrics.disable.reason", comment: "Disable biometrics reason"))

        switch result {
        case .success:
            requireBiometrics = false
        case .failed:
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: NSLocalizedString("alert.authFailed.title", comment: "Authentication failed title"),
                message: NSLocalizedString("alert.authFailed.message", comment: "Authentication failed message")
            )
        case .cancelled:
            requireBiometrics = true
        case .unavailable(let message):
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: NSLocalizedString("alert.authUnavailable.title", comment: "Authentication unavailable title"),
                message: message
            )
        case .error(let message):
            requireBiometrics = true
            settingsAlert = SettingsAlert(
                title: NSLocalizedString("alert.authError.title", comment: "Authentication error title"),
                message: message
            )
        }
    }

    private var infoSection: some View {
        Section(NSLocalizedString("settings.info.section", comment: "Info section title")) {
            Button { infoSheet = .faq } label: {
                Label(NSLocalizedString("settings.info.faq", comment: "FAQ title"), systemImage: "questionmark.circle")
            }
            Button { infoSheet = .terms } label: {
                Label(NSLocalizedString("settings.info.terms", comment: "Terms title"), systemImage: "doc.append")
            }
            Button { infoSheet = .privacy } label: {
                Label(NSLocalizedString("settings.info.privacy", comment: "Privacy title"), systemImage: "lock.shield")
            }
        }
    }

    private var supportSection: some View {
        Section(NSLocalizedString("settings.support.section", comment: "Support section title")) {
            Button {
                if let shareURL = URL(string: "https://roguewaveapps.com/pdf-converter") {
                    shareItem = ShareItem(url: shareURL, cleanupHandler: nil)
                }
            } label: {
                Label(NSLocalizedString("settings.support.shareApp", comment: "Share app label"), systemImage: "square.and.arrow.up")
            }

            Button {
                settingsAlert = SettingsAlert(
                    title: NSLocalizedString("settings.support.contactTitle", comment: "Contact support title"),
                    message: NSLocalizedString("settings.support.contactMessage", comment: "Contact support message")
                )
            } label: {
                Label(NSLocalizedString("settings.support.contactButton", comment: "Contact support button"), systemImage: "envelope")
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
        ("🚀", "account.feature.conversions"),
        ("📸", "account.feature.photos"),
        ("📄", "account.feature.scan"),
        ("🗂️", "account.feature.backup"),
        ("🖋️", "account.feature.editing"),
        ("🤝", "account.feature.support")
    ]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    statusSection
                    featuresSection
                    actionButton
                    if case .failed(let message) = subscriptionManager.purchaseState {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text("Error Details")
                                    .font(.headline)
                                    .foregroundColor(.red)
                            }

                            ScrollView {
                                Text(message)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.red)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 200)
                            .padding(12)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle(NSLocalizedString("account.title", comment: "Account navigation title"))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProButton(subscriptionManager: subscriptionManager)
                }
                .hideSharedBackground
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(subscriptionManager.isSubscribed ? NSLocalizedString("account.status.subscribed.title", comment: "Subscribed status title") : NSLocalizedString("account.status.upsell.title", comment: "Upsell status title"))
                .font(.title2.weight(.semibold))
            Text(subscriptionManager.isSubscribed ? NSLocalizedString("account.status.subscribed.message", comment: "Subscribed status message") : NSLocalizedString("account.status.upsell.message", comment: "Upsell status message"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(subscriptionManager.isSubscribed ? NSLocalizedString("account.features.subscribed", comment: "Subscribed features title") : NSLocalizedString("account.features.upsell", comment: "Upsell features title"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(featureList, id: \.0) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Text(item.0)
                            .font(.title3)
                        Text(NSLocalizedString(item.1, comment: "Feature description"))
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
                Label(NSLocalizedString("account.action.manage", comment: "Manage subscription label"), systemImage: "gearshape")
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
                    Label(NSLocalizedString("account.action.upgrade", comment: "Upgrade action label"), systemImage: "sparkles")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(subscriptionManager.purchaseState == .purchasing)

            Text(NSLocalizedString("account.trial.copy", comment: "Trial copy text"))
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

    private let productID = "com.roguewaveapps.pdfconverter.test.weekly.1"
    private let hasEverPurchasedKey = "hasEverPurchasedSubscription"

    init() {
        Task { await loadProduct() }
        Task { await monitorEntitlements() }
        Task { await listenForTransactions() }
    }

    /// Returns true if the user has never purchased a subscription
    var shouldShowPaywall: Bool {
        return !UserDefaults.standard.bool(forKey: hasEverPurchasedKey) && !isSubscribed
    }

    /// Marks that the user has completed a purchase (called after successful transaction)
    private func markPurchaseCompleted() {
        UserDefaults.standard.set(true, forKey: hasEverPurchasedKey)
    }

    /// Initiates the purchase flow for the weekly subscription.
    func purchase() {
        guard purchaseState != .purchasing else { return }
        Task { await purchaseProduct() }
    }

    /// Restores previous purchases by syncing with the App Store
    func restorePurchases() async {
        print("🔄 [SubscriptionManager] Starting restore purchases...")
        purchaseState = .purchasing

        do {
            // Sync with App Store to get latest transaction info
            try await AppStore.sync()
            print("✅ [SubscriptionManager] AppStore sync completed")

            // Check current entitlements
            var foundActiveSubscription = false
            for await result in Transaction.currentEntitlements {
                if case .verified(let transaction) = result,
                   transaction.productID == productID {
                    let isActive = transaction.revocationDate == nil &&
                        (transaction.expirationDate ?? .distantFuture) > Date()

                    if isActive {
                        foundActiveSubscription = true
                        isSubscribed = true
                        markPurchaseCompleted()
                        print("✅ [SubscriptionManager] Found active subscription")
                        await transaction.finish()
                        break
                    }
                }
            }

            if foundActiveSubscription {
                purchaseState = .purchased
                print("✅ [SubscriptionManager] Restore successful - subscription active")
            } else {
                purchaseState = .failed("No active subscription found.\n\nIf you previously purchased, ensure you're signed in with the same Apple ID.")
                print("ℹ️ [SubscriptionManager] No active subscription found")
            }
        } catch {
            print("❌ [SubscriptionManager] Restore failed: \(error.localizedDescription)")
            purchaseState = .failed("Restore failed.\n\nError: \(error.localizedDescription)")
        }
    }

    /// Sends the user to the native App Store subscription management screen.
    func openManageSubscriptions() {
        if #available(iOS 15.0, *) {
            Task { @MainActor in
                guard let scene = UIApplication.shared.connectedScenes
                    .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
                        openSubscriptionsFallback()
                        return
                    }

                do {
                    try await AppStore.showManageSubscriptions(in: scene)
                } catch {
                    openSubscriptionsFallback()
                }
            }
        } else {
            openSubscriptionsFallback()
        }
    }

    private func openSubscriptionsFallback() {
        guard let url = URL(string: "https://apps.apple.com/account/subscriptions") else { return }
        UIApplication.shared.open(url)
    }

    /// Fetches metadata for the subscription product (price, trial eligibility, etc).
    private func loadProduct() async {
        do {
            print("🔍 [SubscriptionManager] Loading product with ID: \(productID)")
            let products = try await Product.products(for: [productID])

            if let loadedProduct = products.first {
                product = loadedProduct
                print("✅ [SubscriptionManager] Product loaded successfully: \(loadedProduct.displayName) - \(loadedProduct.displayPrice)")
            } else {
                print("❌ [SubscriptionManager] Product array is empty - Product ID not found in App Store Connect")
                purchaseState = .failed("Product not found in App Store.\n\nProduct ID: \(productID)\n\nThis usually means:\n1. Product not set up in App Store Connect\n2. Product not approved yet\n3. Product not added to this app version\n4. Wrong product ID")
            }
        } catch {
            print("❌ [SubscriptionManager] Failed to load product: \(error.localizedDescription)")
            print("   Error details: \(error)")

            let errorMessage = """
            Failed to load subscription.

            Product ID: \(productID)
            Error: \(error.localizedDescription)

            Debug info: \(error)

            Possible causes:
            • Network connection issue
            • App Store services unavailable
            • Invalid product configuration
            """

            purchaseState = .failed(errorMessage)
        }
    }

    /// Listens for entitlement changes so UI instantly reflects new subscription states.
    private func monitorEntitlements() async {
        for await entitlement in StoreKit.Transaction.currentEntitlements {
            await updateSubscriptionState(from: entitlement)
        }
    }

    /// Listens for transaction updates to catch purchases made outside the app or in the background
    private func listenForTransactions() async {
        for await result in StoreKit.Transaction.updates {
            await handleTransactionUpdate(result)
        }
    }

    private func handleTransactionUpdate(_ result: VerificationResult<StoreKit.Transaction>) async {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == productID else { return }

            // Update subscription state
            let isActive = transaction.revocationDate == nil &&
                (transaction.expirationDate ?? .distantFuture) > Date()
            isSubscribed = isActive

            if isActive {
                purchaseState = .purchased
                markPurchaseCompleted()
            }

            // Always finish the transaction
            await transaction.finish()

        case .unverified(_, let error):
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
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
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
        }
    }

    private func purchaseProduct() async {
        guard let product else {
            print("❌ [SubscriptionManager] Cannot purchase - product is nil")
            let errorMessage = """
            Subscription not available.

            Product ID: \(productID)

            The product failed to load. Check the error message above for details.

            In TestFlight, ensure:
            • Product is approved in App Store Connect
            • Product is added to this app version
            • You're signed in with a sandbox account
            """
            purchaseState = .failed(errorMessage)
            return
        }

        print("🛒 [SubscriptionManager] Starting purchase for: \(product.displayName)")
        purchaseState = .purchasing

        do {
            let result = try await product.purchase()
            print("📦 [SubscriptionManager] Purchase result received")

            switch result {
            case .success(let verification):
                print("✅ [SubscriptionManager] Purchase successful")
                await handlePurchaseResult(verification)
            case .pending:
                print("⏳ [SubscriptionManager] Purchase pending (waiting for approval)")
                purchaseState = .pending
            case .userCancelled:
                print("🚫 [SubscriptionManager] Purchase cancelled by user")
                purchaseState = .idle
            @unknown default:
                print("⚠️ [SubscriptionManager] Unknown purchase result")
                purchaseState = .failed("Unknown purchase result.\n\nPlease try again or contact support.")
            }
        } catch {
            print("❌ [SubscriptionManager] Purchase failed: \(error.localizedDescription)")
            print("   Error details: \(error)")

            let errorMessage = """
            Purchase failed.

            Error: \(error.localizedDescription)

            Debug info: \(error)
            """

            purchaseState = .failed(errorMessage)
        }
    }

    private func handlePurchaseResult(_ verification: VerificationResult<StoreKit.Transaction>) async {
        switch verification {
        case .verified(let transaction):
            isSubscribed = true
            purchaseState = .purchased
            markPurchaseCompleted()
            await transaction.finish()
        case .unverified(_, let error):
            purchaseState = .failed(String(format: NSLocalizedString("subscription.verificationFailed", comment: "Verification failed message"), error.localizedDescription))
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
                Section(NSLocalizedString("webPrompt.section.title", comment: "Web prompt section title")) {
                    TextField(NSLocalizedString("webPrompt.placeholder", comment: "Web prompt placeholder"), text: $urlString)
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
                        Label(NSLocalizedString("action.convert", comment: "Convert action"), systemImage: "arrow.down.doc")
                    }
                    .disabled(urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConverting)

                    Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel, action: cancel)
                        .disabled(isConverting)
                }

                if isConverting {
                    Section {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("status.converting", comment: "Conversion in progress"))
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
        .navigationTitle(NSLocalizedString("webPrompt.title", comment: "Convert web page title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action"), action: cancel)
                        .disabled(isConverting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.convert", comment: "Convert action"), action: performConversion)
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
                    conversionError = NSLocalizedString("webPrompt.error.message", comment: "Web conversion error message")
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
                    Text(NSLocalizedString("editor.choosePDF.emptyTitle", comment: "No PDFs found title"))
                        .font(.headline)
                    Text(NSLocalizedString("editor.choosePDF.emptyMessage", comment: "No PDFs found message"))
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
        .navigationTitle(NSLocalizedString("editor.choosePDF.title", comment: "Choose PDF title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
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
                                title: NSLocalizedString("signature.placeFailed.title", comment: "Signature placement failed title"),
                                message: NSLocalizedString("signature.placeFailed.message", comment: "Signature placement failed message")
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
                Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
                    if controller.hasActiveSignaturePlacement() {
                        controller.cancelSignaturePlacement()
                    }
                    onCancel()
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("action.save", comment: "Save action")) {
                    if controller.hasActiveSignaturePlacement() {
                        if controller.confirmSignaturePlacement() {
                            onSave()
                        } else {
                            inlineAlert = InlineAlert(
                                title: NSLocalizedString("signature.placeFailed.title", comment: "Signature placement failed title"),
                                message: NSLocalizedString("signature.placeFailed.message", comment: "Signature placement failed message")
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
                            title: NSLocalizedString("signature.none.title", comment: "No signature found title"),
                            message: NSLocalizedString("signature.none.message", comment: "No signature found message")
                        )
                        return
                    }

                    if !controller.beginSignaturePlacement(signature) {
                        inlineAlert = InlineAlert(
                            title: NSLocalizedString("signature.cannotInsert.title", comment: "Cannot insert signature title"),
                            message: NSLocalizedString("signature.cannotInsert.message", comment: "Cannot insert signature message")
                        )
                    }
                } label: {
                    Label(NSLocalizedString("signature.insert.action", comment: "Insert signature action"), systemImage: "signature")
                }
                .tint(controller.hasActiveSignaturePlacement() ? .orange : nil)

                Button {
                    if !controller.highlightSelection() {
                        inlineAlert = InlineAlert(
                            title: NSLocalizedString("signature.highlight.title", comment: "Highlight missing selection title"),
                            message: NSLocalizedString("signature.highlight.message", comment: "Highlight missing selection message")
                        )
                    }
                } label: {
                    Label(NSLocalizedString("signature.highlight.action", comment: "Highlight action"), systemImage: "highlighter")
                }

            }
        }
        .alert(item: $inlineAlert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))))
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
        annotation.contents = NSLocalizedString("editor.annotation.newNote", comment: "New note default text")
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
                            Label(NSLocalizedString("action.cancel", comment: "Cancel Button Label"), systemImage: "xmark.circle")
                        }
                        .buttonStyle(.bordered)

                        Button {
                            onConfirm()
                        } label: {
                            Label(NSLocalizedString("signature.place", comment: "Place Signature Button Label"), systemImage: "checkmark.circle")
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

struct CreateSomethingView: View {
    var body: some View {
        NavigationView {
            Text(NSLocalizedString("placeholder.createFlow.body", comment: "Create flow placeholder"))
                .navigationTitle(NSLocalizedString("placeholder.createFlow.title", comment: "Create flow title"))
        }
    }
}

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
        _signatureName = State(initialValue: existingSignature?.name ?? NSLocalizedString("signature.defaultName", comment: "Default signature name"))
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
                    Text(NSLocalizedString("signature.name.label", comment: "Signature name label"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    TextField(NSLocalizedString("signature.name.placeholder", comment: "Signature name placeholder"), text: $signatureName)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                }

                Spacer()

                Text(NSLocalizedString("signature.instructions", comment: "Signature instructions"))
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle(signature == nil ? NSLocalizedString("signature.add.title", comment: "Add signature title") : NSLocalizedString("signature.update.title", comment: "Update signature title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("action.cancel", comment: "Cancel action")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("action.save", comment: "Save action")) { saveSignature() }
                        .disabled(drawing.bounds.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(NSLocalizedString("action.clear", comment: "Clear action"), role: .destructive) { drawing = PKDrawing() }
                        .disabled(drawing.bounds.isEmpty)
                }
            }
            .alert(NSLocalizedString("signature.empty.title", comment: "Empty signature title"), isPresented: $showEmptyAlert) {
                Button(NSLocalizedString("action.ok", comment: "OK action"), role: .cancel) { }
            } message: {
                Text(NSLocalizedString("signature.empty.message", comment: "Empty signature message"))
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
        let resolvedName = trimmedName.isEmpty ? NSLocalizedString("signature.defaultName", comment: "Default signature name") : trimmedName
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
    @StateObject private var subscriptionManager = SubscriptionManager()

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
            .navigationTitle(NSLocalizedString("tools.title", comment: "Tools screen title"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    ProButton(subscriptionManager: subscriptionManager)
                }
                .hideSharedBackground
            }
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
                    Text(NSLocalizedString("review.fileName.label", comment: "File name label"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    TextField(NSLocalizedString("review.fileName.placeholder", comment: "File name placeholder"), text: $fileName)
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
                        Label(NSLocalizedString("action.share", comment: "Share action"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        let updated = sanitizedDocument()
                        onSave(updated)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("action.save", comment: "Save action"), systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle(NSLocalizedString("review.title", comment: "Preview screen title"))
            .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("action.cancel", comment: "Cancel action")) {
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
    @State private var showShareSheet = false

    var body: some View {
        PDFPreviewView(url: file.url)
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationTitle(file.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                if let url = try? PDFStorage.prepareShareURL(for: ScannedDocument(pdfURL: file.url, fileName: file.name)) {
                    ShareSheet(activityItems: [url]) {
                        showShareSheet = false
                    }
                }
            }
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

/// Pro subscription button that appears in navigation bars
struct ProButton: View {
    @ObservedObject var subscriptionManager: SubscriptionManager

    var body: some View {
        Button {
            guard !subscriptionManager.isSubscribed else { return }
            subscriptionManager.purchase()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: subscriptionManager.isSubscribed ? "checkmark.seal.fill" : "crown.fill")
                    .font(.system(size: 12, weight: .semibold))

                Text(
                    subscriptionManager.isSubscribed
                    ? NSLocalizedString("Pro", comment: "The text for the \"Pro\" button in the navigation bar.")
                    : NSLocalizedString("Go Pro", comment: "A button label that indicates that the user can upgrade to a premium subscription.")
                )
                .font(.system(size: 14, weight: .semibold))
            }
            .foregroundColor(.blue)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(subscriptionManager.isSubscribed ? 0.5 : 1)           // visual disabled state
        }
        .buttonStyle(.plain)                                                // no extra chrome
        .contentShape(Rectangle())                                          // full pill is tappable
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
            throw ScanWorkflowError.failed(NSLocalizedString("We couldn't create PDF data from the scanned pages.", comment: "Scanned PDF creation error message"))
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
            let folderId = loadFileFolderId(for: url)
            return PDFFile(
                url: url,
                name: url.deletingPathExtension().lastPathComponent,
                date: date,
                pageCount: pageCount,
                fileSize: size,
                folderId: folderId
            )
        }
    }

    static func save(document: ScannedDocument) throws -> PDFFile {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
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
            fileSize: size,
            folderId: nil
        )
    }

    static func importDocuments(at urls: [URL]) throws -> [PDFFile] {
        guard let directory = documentsDirectory() else {
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
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
                let resourceValues = try? destination.resourceValues(forKeys: [.fileSizeKey])
                // Use import date (now) instead of file's original creation/modification date
                let date = Date()
                let size = Int64(resourceValues?.fileSize ?? 0)
                let pageCount = PDFDocument(url: destination)?.pageCount ?? 0
                let file = PDFFile(
                    url: destination,
                    name: destination.deletingPathExtension().lastPathComponent,
                    date: date,
                    pageCount: pageCount,
                    fileSize: size,
                    folderId: nil
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
                fileSize: file.fileSize,
                folderId: file.folderId
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
            fileSize: size,
            folderId: file.folderId
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
            throw ScanWorkflowError.failed(NSLocalizedString("Unable to access the Documents folder", comment: "Documents folder access error"))
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
        let sanitized = trimmed.isEmpty ? NSLocalizedString("Scan", comment: "Paywall feature tag") : trimmed
        let invalidCharacters = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let components = sanitized.components(separatedBy: invalidCharacters)
        let filtered = components.joined(separator: "-")
        if filtered.lowercased().hasSuffix(".pdf") {
            return String(filtered.dropLast(4))
        }
        return filtered
    }

    // MARK: - Folder Management

    private static var foldersFileURL: URL? {
        documentsDirectory()?.appendingPathComponent(".folders.json")
    }

    private static var fileFoldersFileURL: URL? {
        documentsDirectory()?.appendingPathComponent(".file_folders.json")
    }

    static func loadFolders() -> [PDFFolder] {
        guard let url = foldersFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return []
        }

        return (try? JSONDecoder().decode([PDFFolder].self, from: data)) ?? []
    }

    static func saveFolders(_ folders: [PDFFolder]) {
        guard let url = foldersFileURL,
              let data = try? JSONEncoder().encode(folders) else {
            return
        }

        try? data.write(to: url, options: .atomic)
    }

    static func updateFileFolderId(file: PDFFile, folderId: String?) {
        guard let url = fileFoldersFileURL else { return }

        var mapping: [String: String] = [:]

        // Load existing mapping
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONDecoder().decode([String: String].self, from: data) {
            mapping = existing
        }

        // Update mapping
        let key = file.url.lastPathComponent
        if let folderId = folderId {
            mapping[key] = folderId
        } else {
            mapping.removeValue(forKey: key)
        }

        // Save mapping with atomic write and data sync
        if let data = try? JSONEncoder().encode(mapping) {
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                // Ensure the write is flushed to disk
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            } catch {
                print("Failed to write folder mapping: \(error)")
            }
        }
    }

    static func loadFileFolderId(for fileURL: URL) -> String? {
        guard let url = fileFoldersFileURL,
              FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let mapping = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }

        let key = fileURL.lastPathComponent
        return mapping[key]
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
        .init(title: NSLocalizedString("tools.card.convertFiles.title", comment: "Convert files title"),
              tint: Color(hex: 0x2F7F79),
              iconName: "infinity",
              action: .convertFiles),
        .init(title: NSLocalizedString("tools.card.scan.title", comment: "Scan documents title"),
              tint: Color(hex: 0xC02267),
              iconName: "camera",
              action: .scanDocuments),
        .init(title: NSLocalizedString("tools.card.convertPhotos.title", comment: "Convert photos title"),
              tint: Color(hex: 0x5C3A78),
              iconName: "photo.on.rectangle",
              action: .convertPhotos),
        .init(title: NSLocalizedString("tools.card.import.title", comment: "Import documents title"),
              tint: Color(hex: 0x6C8FC0),
              iconName: "arrow.down.to.line",
              action: .importDocuments),
        .init(title: NSLocalizedString("tools.card.web.title", comment: "Convert web page title"),
              tint: Color(hex: 0xBF7426),
              iconName: "link",
              action: .convertWebPage),
        .init(title: NSLocalizedString("tools.card.edit.title", comment: "Edit documents title"),
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
