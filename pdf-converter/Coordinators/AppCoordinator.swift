import SwiftUI
import Observation
import VisionKit
import LocalAuthentication
import PDFKit

/// Main coordinator responsible for navigation state, modal presentation, and coordinating between services
@Observable
@MainActor
final class AppCoordinator {
    // MARK: - Navigation State

    /// Current active tab
    var selectedTab: Tab = .files

    /// Active scan flow (document camera or photo library)
    var activeScanFlow: ScanFlow?

    /// Scanned document awaiting review
    var pendingDocument: ScannedDocument?

    /// File being previewed
    var previewFile: PDFFile?

    /// PDF editing session
    var editingContext: PDFEditingContext?

    /// Current share item
    var shareItem: ShareItem?

    /// Alert to display
    var alertContext: ScanAlert?

    // MARK: - Dialog State

    /// File being renamed
    var renameTarget: PDFFile?

    /// Rename text input
    var renameText: String = ""

    /// File pending deletion
    var deleteTarget: PDFFile?

    /// Delete dialog visibility
    var showDeleteDialog = false

    /// Folder pending deletion
    var deleteFolderTarget: PDFFolder?

    /// Folder delete dialog visibility
    var showDeleteFolderDialog = false

    // MARK: - Import/Convert State

    /// Import PDF dialog visibility
    var showImporter = false

    /// UUID to force reimporter presentation
    var importerTrigger = UUID()

    /// Convert files dialog visibility
    var showConvertPicker = false

    /// Web URL conversion prompt visibility
    var showWebURLPrompt = false

    /// Web URL input text
    var webURLInput: String = ""

    /// Edit file selector visibility
    var showEditSelector = false

    /// Whether a file conversion is in progress
    var isConvertingFile = false

    // MARK: - Paywall State

    /// Onboarding flow visibility
    var showOnboarding: Bool

    /// Document to restore after paywall dismissal
    var documentPendingAfterPaywall: ScannedDocument?

    /// Editing context to restore after paywall dismissal
    var editingContextPendingAfterPaywall: PDFEditingContext?

    /// Whether paywall check has completed
    var hasCheckedPaywall = false

    // MARK: - UI State

    /// Quick actions menu visibility
    var showCreateActions = false

    // MARK: - Dependencies

    /// Subscription manager for paywall checks
    private let subscriptionManager: SubscriptionManager

    /// Centralized subscription gating
    private let subscriptionGate: SubscriptionGate

    /// File management service
    private let fileService: FileManagementService

    /// Scan flow coordinator
    private let scanCoordinator: ScanFlowCoordinator

    // MARK: - Task Management

    /// Initial file loading and cloud restore task
    private var initialLoadTask: Task<Void, Never>?

    /// Active file conversion task
    private var fileConversionTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        subscriptionManager: SubscriptionManager,
        subscriptionGate: SubscriptionGate,
        fileService: FileManagementService,
        scanCoordinator: ScanFlowCoordinator
    ) {
        self.subscriptionManager = subscriptionManager
        self.subscriptionGate = subscriptionGate
        self.fileService = fileService
        self.scanCoordinator = scanCoordinator
        self.showOnboarding = !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
    }

    nonisolated deinit {
        // Note: Cannot access @MainActor properties from deinit
        // Task cancellation will happen when instance is deallocated
    }

    // MARK: - Generic Binding Helper

    /// Creates a SwiftUI binding for optional properties using keypaths
    func binding<T>(for keyPath: ReferenceWritableKeyPath<AppCoordinator, T?>) -> Binding<T?> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { self[keyPath: keyPath] = $0 }
        )
    }

    // MARK: - Navigation Actions

    /// Selects the given tab
    func selectTab(_ tab: Tab) {
        selectedTab = tab
    }

    /// Presents a scan flow (document camera or photo library)
    func presentScanFlow(_ flow: ScanFlow) {
        guard flow == .documentCamera else {
            activeScanFlow = flow
            return
        }

        // Check if document scanner is available
        guard VNDocumentCameraViewController.isSupported else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.scannerUnavailable.title", comment: "Scanner unavailable title"),
                message: NSLocalizedString("alert.scannerUnavailable.message", comment: "Scanner unavailable message"),
                onDismiss: nil
            )
            return
        }

        activeScanFlow = flow
    }

    /// Presents the preview sheet with optional biometric authentication
    func presentPreview(_ file: PDFFile, requireAuth: Bool) async {
        guard requireAuth else {
            previewFile = file
            return
        }

        let result = await BiometricAuthenticator.authenticate(
            reason: NSLocalizedString("biometrics.reason.preview", comment: "Reason for biometric prompt")
        )

        switch result {
        case .success:
            previewFile = file
        case .failed:
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.authFailed.title", comment: "Authentication failed title"),
                message: NSLocalizedString("alert.authFailed.message", comment: "Authentication failed message"),
                onDismiss: nil
            )
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

    /// Initiates file rename flow
    func presentRename(_ file: PDFFile) {
        renameText = file.name
        renameTarget = file
    }

    /// Shows delete confirmation dialog
    func confirmDelete(_ file: PDFFile) {
        deleteTarget = file
        showDeleteDialog = true
    }

    /// Shows folder delete confirmation dialog
    func confirmFolderDelete(_ folder: PDFFolder) {
        deleteFolderTarget = folder
        showDeleteFolderDialog = true
    }

    // MARK: - Tool Action Routing

    /// Routes tool action taps to appropriate handlers
    func handleToolAction(_ action: ToolAction) {
        switch action {
        case .scanDocuments:
            presentScanFlow(.documentCamera)
        case .convertPhotos:
            presentScanFlow(.photoLibrary)
        case .convertFiles:
            showCreateActions = false
            showConvertPicker = true
        case .importDocuments:
            showCreateActions = false
            presentImporter()
        case .convertWebPage:
            showCreateActions = false
            showWebURLPrompt = true
        case .editDocuments:
            showCreateActions = false
            Task {
                await promptEditDocuments()
            }
        }
    }

    // MARK: - Paywall Coordination

    /// Checks if paywall should be shown on launch and loads files
    func checkPaywallOnLaunch() {
        // Check if we should show the paywall (onboarding is handled at initialization)
        let hasCompletedOnboarding = UserDefaults.standard.bool(forKey: "hasCompletedOnboarding")
        if hasCompletedOnboarding && subscriptionManager.shouldShowPaywall {
            subscriptionGate.showPaywall = true
        }

        // Mark that we've checked, allowing main content to render
        hasCheckedPaywall = true

        // Load files if not already loaded
        guard !fileService.hasLoadedInitialFiles else { return }

        // Cancel any existing load task and start new one
        initialLoadTask?.cancel()
        initialLoadTask = Task {
            await fileService.loadInitialFiles()
            await fileService.attemptCloudRestore()
        }
    }

    /// Handles paywall dismissal and restores any pending state
    func handlePaywallDismissal() {
        // Mark onboarding as completed if needed
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            showOnboarding = false
        }

        // Restore pending document
        if let savedDoc = documentPendingAfterPaywall {
            documentPendingAfterPaywall = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.pendingDocument = savedDoc
            }
        }

        // Restore pending editing context
        if let savedContext = editingContextPendingAfterPaywall {
            editingContextPendingAfterPaywall = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.editingContext = savedContext
            }
        }
    }

    /// Checks if user is subscribed, shows paywall if not
    /// - Returns: true if subscribed, false if paywall was shown
    func requireSubscription(source: String, pendingDocument: ScannedDocument? = nil, pendingContext: PDFEditingContext? = nil) -> Bool {
        guard subscriptionManager.isSubscribed else {
            subscriptionGate.paywallSource = source
            documentPendingAfterPaywall = pendingDocument
            editingContextPendingAfterPaywall = pendingContext
            subscriptionGate.showPaywall = true
            return false
        }
        return true
    }

    // MARK: - Document Actions

    /// Handles scan result from camera or photo picker
    func handleScanResult(_ result: Result<[UIImage], ScanWorkflowError>, suggestedName: String) {
        activeScanFlow = nil

        do {
            let document = try scanCoordinator.handleScanResult(result, suggestedName: suggestedName)
            pendingDocument = document
            showCreateActions = false
        } catch let error as ScanWorkflowError {
            // Only show alert if it's not a cancellation
            guard error.shouldDisplayAlert else { return }

            alertContext = ScanAlert(
                title: NSLocalizedString("alert.scanFailed.title", comment: "Scan failed title"),
                message: error.message,
                onDismiss: nil
            )
        } catch let error as ConversionError {
            if !error.localizedDescription.isEmpty {
                alertContext = ScanAlert(
                    title: NSLocalizedString("alert.scanFailed.title", comment: "Scan failed title"),
                    message: error.localizedDescription,
                    onDismiss: nil
                )
            }
        } catch {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.pdfError.title", comment: "PDF error title"),
                message: error.localizedDescription,
                onDismiss: nil
            )
        }
    }

    /// Saves a scanned document after subscription check
    func saveScanDocument(_ document: ScannedDocument) {
        guard requireSubscription(source: "scan_review_save", pendingDocument: document) else {
            return
        }

        do {
            _ = try fileService.saveScannedDocument(document)
            scanCoordinator.cleanupTemporaryFile(at: document.pdfURL)
            pendingDocument = nil
        } catch {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.savePDFFailed.title", comment: "Save PDF failed title"),
                message: NSLocalizedString("alert.savePDFFailed.message", comment: "Save PDF failed message"),
                onDismiss: nil
            )
        }
    }

    /// Prepares a scanned document for sharing after subscription check
    func shareScanDocument(_ document: ScannedDocument) -> ShareItem? {
        guard requireSubscription(source: "scan_review_share", pendingDocument: document) else {
            return nil
        }

        do {
            let shareURL = try fileService.prepareShareURL(for: document)
            return ShareItem(
                url: shareURL,
                cleanupHandler: {
                    PDFStorage.deleteTemporaryFile(at: shareURL)
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

    /// Discards a temporary scanned document
    func discardScanDocument(_ document: ScannedDocument) {
        pendingDocument = nil
        scanCoordinator.cleanupTemporaryFile(at: document.pdfURL)
    }

    // MARK: - File Actions

    /// Applies file rename after validation
    func applyRename(for file: PDFFile, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.invalidName.title", comment: "Invalid name title"),
                message: NSLocalizedString("alert.invalidName.message", comment: "Invalid name message"),
                onDismiss: nil
            )
            return
        }

        do {
            let renamed = try fileService.renameFile(file, to: trimmed)
            renameText = renamed.name
            renameTarget = nil
        } catch {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.renameFailed.title", comment: "Rename failed title"),
                message: NSLocalizedString("alert.renameFailed.message", comment: "Rename failed message"),
                onDismiss: nil
            )
        }
    }

    /// Deletes a file from storage
    func deleteFile(_ file: PDFFile) {
        do {
            try fileService.deleteFile(file)
            deleteTarget = nil
            showDeleteDialog = false
        } catch {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.deleteFailed.title", comment: "Delete failed title"),
                message: NSLocalizedString("alert.deleteFailed.message", comment: "Delete failed message"),
                onDismiss: {
                    self.deleteTarget = nil
                    self.showDeleteDialog = false
                }
            )
        }
    }

    /// Deletes a folder and all its files
    func deleteFolderAction(_ folder: PDFFolder) {
        fileService.deleteFolder(folder)
        deleteFolderTarget = nil
        showDeleteFolderDialog = false
    }

    /// Prepares a saved file for sharing after subscription check
    func shareSavedFile(_ file: PDFFile) {
        guard requireSubscription(source: "files_list_share") else {
            return
        }

        shareItem = nil
        shareItem = ShareItem(url: file.url, cleanupHandler: nil)
    }

    // MARK: - Import/Convert Actions

    /// Forces SwiftUI to re-present the file importer
    func presentImporter() {
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

    /// Shows web URL conversion prompt
    func promptWebConversion() {
        showCreateActions = false
        showWebURLPrompt = true
    }

    /// Shows PDF edit selector after ensuring files are loaded
    func promptEditDocuments() async {
        await fileService.refreshFromDisk()
        guard !fileService.files.isEmpty else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.noPDFs.title", comment: "No PDFs available title"),
                message: NSLocalizedString("alert.noPDFs.message", comment: "No PDFs available message"),
                onDismiss: nil
            )
            return
        }
        showEditSelector = true
    }

    /// Handles PDF import result
    func handleImportResult(_ result: Result<[URL], Error>) {
        showImporter = false

        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }

            do {
                let imported = try fileService.importDocuments(at: urls)
                if imported.isEmpty {
                    alertContext = ScanAlert(
                        title: NSLocalizedString("alert.noImport.title", comment: "No PDFs imported title"),
                        message: NSLocalizedString("alert.noImport.message", comment: "No PDFs imported message"),
                        onDismiss: nil
                    )
                    return
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
                // User cancelled, no action
                return
            }
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.importFailed.title", comment: "Import failed title"),
                message: NSLocalizedString("alert.importAccessFailed.message", comment: "Import file access failed message"),
                onDismiss: nil
            )
        }
    }

    /// Handles web URL conversion
    func handleWebConversion(urlString: String) async {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.invalidURL.title", comment: "Invalid URL title"),
                message: NSLocalizedString("alert.invalidURL.message", comment: "Invalid URL message"),
                onDismiss: nil
            )
            return
        }

        guard let resolvedURL = scanCoordinator.normalizeWebURL(from: trimmed) else {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.invalidURL.title", comment: "Invalid URL title"),
                message: NSLocalizedString("alert.invalidURL.unrecognized", comment: "Invalid URL unrecognized message"),
                onDismiss: nil
            )
            return
        }

        isConvertingFile = true
        defer { isConvertingFile = false }

        do {
            let document = try await scanCoordinator.convertWebPage(url: resolvedURL)
            pendingDocument = document
            webURLInput = resolvedURL.absoluteString
        } catch let error as ConversionError {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
                message: error.localizedDescription,
                onDismiss: nil
            )
        } catch {
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
                message: error.localizedDescription,
                onDismiss: nil
            )
        }
    }

    /// Handles file conversion result
    func handleConvertResult(_ result: Result<[URL], Error>) {
        showConvertPicker = false

        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Cancel any existing conversion and start new one
            fileConversionTask?.cancel()
            fileConversionTask = Task {
                isConvertingFile = true
                defer { isConvertingFile = false }

                do {
                    let document = try await scanCoordinator.convertFileUsingLibreOffice(url: url)
                    pendingDocument = document
                } catch let error as ConversionError {
                    alertContext = ScanAlert(
                        title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
                        message: error.localizedDescription,
                        onDismiss: nil
                    )
                } catch {
                    alertContext = ScanAlert(
                        title: NSLocalizedString("alert.conversionFailed.title", comment: "Conversion failed title"),
                        message: error.localizedDescription,
                        onDismiss: nil
                    )
                }
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

    /// Begins editing a PDF file
    func beginEditing(_ file: PDFFile) {
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
            self.editingContext = context
        }
    }

    /// Saves edited PDF document after subscription check
    func saveEditedDocument(_ context: PDFEditingContext) {
        guard requireSubscription(source: "pdf_editor_save", pendingContext: context) else {
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        do {
            guard context.document.write(to: tempURL) else {
                throw PDFEditingError.writeFailed
            }

            _ = try FileManager.default.replaceItemAt(context.file.url, withItemAt: tempURL)
            PDFStorage.deleteTemporaryFile(at: tempURL)

            Task {
                await fileService.refreshFromDisk()
            }
            editingContext = nil
        } catch {
            PDFStorage.deleteTemporaryFile(at: tempURL)
            alertContext = ScanAlert(
                title: NSLocalizedString("alert.saveFailed.title", comment: "Save failed title"),
                message: NSLocalizedString("alert.saveFailed.message", comment: "Save failed message"),
                onDismiss: nil
            )
        }
    }
}
