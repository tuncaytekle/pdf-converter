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
import OSLog
import PostHog

/// Root container view that orchestrates tabs, quick actions, and all modal flows.
struct ContentView: View {
    private static let gotenbergLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.roguewaveapps.pdfconverter",
        category: "Gotenberg"
    )

    // MARK: - Coordinators & Services

    @State private var coordinator: AppCoordinator!
    @State private var fileService: FileManagementService
    @State private var scanCoordinator: ScanFlowCoordinator

    // MARK: - Environment

    @StateObject private var subscriptionManager = SubscriptionManager()
    @State private var subscriptionGate: SubscriptionGate!
    @StateObject private var tabNavVM = TabNavigationViewModel()
    @EnvironmentObject private var cloudSyncStatus: CloudSyncStatus
    @Environment(\.analytics) private var analytics
    @Environment(\.colorScheme) private var scheme

    // MARK: - Scene-Scoped State

    @SceneStorage("requireBiometrics") private var requireBiometrics = false

    // MARK: - UI State (stays in view)

    @State private var createButtonPulse = false
    @State private var didAnimateCreateButtonCue = false

    // MARK: - Initialization

    init() {
        let cloudBackup = CloudBackupManager.shared
        let gotenbergClient = Self.makeGotenbergClient()

        let fileService = FileManagementService(cloudBackup: cloudBackup)
        let scanCoordinator = ScanFlowCoordinator(
            gotenbergClient: gotenbergClient,
            fileService: fileService
        )
        _fileService = State(initialValue: fileService)
        _scanCoordinator = State(initialValue: scanCoordinator)
    }

    private static func makeGotenbergClient() -> GotenbergClient? {
        guard let baseURL = Bundle.main.gotenbergBaseURL else {
            gotenbergLogger.error("Missing or invalid Gotenberg base URL configuration.")
            return nil
        }
        return GotenbergClient(
            baseURL: baseURL,
            retryPolicy: RetryPolicy(maxRetries: 2, baseDelay: 0.5, exponential: true),
            timeout: 120
        )
    }

    var body: some View {
        Group {
            if let coordinator = coordinator, let subscriptionGate = subscriptionGate {
                contentView(coordinator: coordinator, subscriptionGate: subscriptionGate)
            } else {
                Color(.systemBackground).ignoresSafeArea()
            }
        }
        .environmentObject(subscriptionManager)
        .task {
            // Initialize subscription gate and coordinator on first appearance
            if subscriptionGate == nil {
                subscriptionGate = SubscriptionGate(subscriptionManager: subscriptionManager)
            }
            if coordinator == nil {
                // Set sync status in file service for cloud backup feedback
                fileService.setSyncStatus(cloudSyncStatus)

                coordinator = AppCoordinator(
                    subscriptionManager: subscriptionManager,
                    subscriptionGate: subscriptionGate!,
                    fileService: fileService,
                    scanCoordinator: scanCoordinator
                )
                coordinator?.checkPaywallOnLaunch()
            }
        }
    }

    @ViewBuilder
    private func contentView(coordinator: AppCoordinator, subscriptionGate: SubscriptionGate) -> some View {
        rootContent
            .environmentObject(subscriptionGate)
        .modifier(ScanFlowSheets(coordinator: coordinator, scanCoordinator: scanCoordinator, subscriptionManager: subscriptionManager))
        .modifier(FileManagementSheets(coordinator: coordinator, fileService: fileService, subscriptionManager: subscriptionManager))
        .modifier(FileImporters(coordinator: coordinator))
        .modifier(ConfirmationDialogs(coordinator: coordinator, fileService: fileService, subscriptionManager: subscriptionManager, subscriptionGate: subscriptionGate))
        .modifier(PaywallPresenter(coordinator: coordinator, subscriptionManager: subscriptionManager, subscriptionGate: subscriptionGate))
    }
}

// MARK: - View Modifiers for Sheet Presentations
private struct ScanFlowSheets: ViewModifier {
    let coordinator: AppCoordinator
    let scanCoordinator: ScanFlowCoordinator
    let subscriptionManager: SubscriptionManager

    func body(content: Content) -> some View {
        content
        .sheet(item: coordinator.binding(for: \.activeScanFlow)) { flow in
            switch flow {
            case .documentCamera:
                DocumentScannerView { result in
                    coordinator.handleScanResult(result, suggestedName: scanCoordinator.defaultFileName(prefix: "Scan"))
                }
            case .photoLibrary:
                PhotoPickerView { result in
                    coordinator.handleScanResult(result, suggestedName: scanCoordinator.defaultFileName(prefix: "Photos"))
                }
            }
        }
        .sheet(item: coordinator.binding(for: \.pendingDocument)) { document in
            ScanReviewSheet(
                document: document,
                onSave: { coordinator.saveScanDocument($0) },
                onShare: { coordinator.shareScanDocument($0) },
                onCancel: { coordinator.discardScanDocument($0) }
            )
        }
    }
}

private struct FileManagementSheets: ViewModifier {
    let coordinator: AppCoordinator
    let fileService: FileManagementService
    let subscriptionManager: SubscriptionManager

    func body(content: Content) -> some View {
        content
        .sheet(item: coordinator.binding(for: \.previewFile)) { file in
            NavigationView {
                SavedPDFDetailView(file: file)
            }
        }
        .sheet(item: coordinator.binding(for: \.renameTarget)) { file in
            RenameFileSheet(fileName: Binding(
                get: { coordinator.renameText },
                set: { coordinator.renameText = $0 }
            )) {
                coordinator.renameTarget = nil
                coordinator.renameText = file.name
            } onSave: {
                coordinator.applyRename(for: file, newName: coordinator.renameText)
            }
        }
        .sheet(item: coordinator.binding(for: \.shareItem)) { item in
            ShareSheet(activityItems: [item.url]) {
                item.cleanupHandler?()
                coordinator.shareItem = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showWebURLPrompt },
            set: { coordinator.showWebURLPrompt = $0 }
        )) {
            WebConversionPrompt(
                urlString: Binding(
                    get: { coordinator.webURLInput },
                    set: { coordinator.webURLInput = $0 }
                ),
                onConvert: { input in
                    await coordinator.handleWebConversion(urlString: input)
                    return true
                },
                onCancel: {
                    coordinator.showWebURLPrompt = false
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { coordinator.showEditSelector },
            set: { coordinator.showEditSelector = $0 }
        )) {
            NavigationView {
                PDFEditorSelectionView(
                    files: Binding(
                        get: { fileService.files },
                        set: { fileService.files = $0 }
                    ),
                    onSelect: { file in
                        coordinator.beginEditing(file)
                    },
                    onCancel: {
                        coordinator.showEditSelector = false
                    }
                )
            }
            .navigationViewStyle(.stack)
        }
        .sheet(item: coordinator.binding(for: \.editingContext)) { context in
            NavigationView {
                PDFEditorView(
                    context: context,
                    onSave: {
                        coordinator.saveEditedDocument(context)
                    },
                    onCancel: {
                        coordinator.editingContext = nil
                    }
                )
            }
            .navigationViewStyle(.stack)
        }
    }
}

private struct FileImporters: ViewModifier {
    let coordinator: AppCoordinator

    func body(content: Content) -> some View {
        content
        .background(
            EmptyView()
                .id(coordinator.importerTrigger)
                .fileImporter(
                    isPresented: Binding(
                        get: { coordinator.showImporter },
                        set: { coordinator.showImporter = $0 }
                    ),
                    allowedContentTypes: [.pdf],
                    allowsMultipleSelection: true,
                    onCompletion: coordinator.handleImportResult
                )
        )
        .background(                                    // <- isolated host for "Convert Files to PDF"
            EmptyView()
                .fileImporter(
                    isPresented: Binding(
                        get: { coordinator.showConvertPicker },
                        set: { coordinator.showConvertPicker = $0 }
                    ),
                    allowedContentTypes: ContentView.convertibleContentTypes,
                    allowsMultipleSelection: false,
                    onCompletion: coordinator.handleConvertResult
                )
        )
    }
}

private struct ConfirmationDialogs: ViewModifier {
    let coordinator: AppCoordinator
    let fileService: FileManagementService
    let subscriptionManager: SubscriptionManager
    let subscriptionGate: SubscriptionGate

    func body(content: Content) -> some View {
        content
        .confirmationDialog(NSLocalizedString("dialog.deletePDF.title", comment: "Delete PDF confirmation"), isPresented: Binding(
            get: { coordinator.showDeleteDialog },
            set: { coordinator.showDeleteDialog = $0 }
        ), presenting: coordinator.deleteTarget) { file in
            Button(role: .destructive) {
                coordinator.deleteFile(file)
            } label: {
                Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) {
                coordinator.deleteTarget = nil
                coordinator.showDeleteDialog = false
            }
        } message: { file in
            Text(String(format: NSLocalizedString("dialog.deletePDF.message", comment: "Delete PDF message"), file.name))
        }
        .confirmationDialog(
            NSLocalizedString("dialog.deleteFolder.title", comment: "Delete folder confirmation title"),
            isPresented: Binding(
                get: { coordinator.showDeleteFolderDialog },
                set: { coordinator.showDeleteFolderDialog = $0 }
            ),
            presenting: coordinator.deleteFolderTarget
        ) { folder in
            Button(role: .destructive) {
                coordinator.deleteFolderAction(folder)
            } label: {
                Label(NSLocalizedString("action.delete", comment: "Delete action"), systemImage: "trash")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) {
                coordinator.deleteFolderTarget = nil
                coordinator.showDeleteFolderDialog = false
            }
        } message: { folder in
            let fileCount = fileService.files.filter { $0.folderId == folder.id }.count
            Text(String(format: NSLocalizedString("dialog.deleteFolder.message", comment: "Delete folder message"), fileCount))
        }
        .alert(item: coordinator.binding(for: \.alertContext)) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))) {
                    coordinator.alertContext = nil
                    context.onDismiss?()
                }
            )
        }
        .fullScreenCover(isPresented: Binding(
            get: { coordinator.showOnboarding },
            set: { coordinator.showOnboarding = $0 }
        )) {
            OnboardingFlowView(isPresented: Binding(
                get: { coordinator.showOnboarding },
                set: { coordinator.showOnboarding = $0 }
            ))
        }
        .onChange(of: coordinator.showOnboarding) { _, isShowing in
            // When onboarding flow is dismissed on first launch, show paywall
            if !isShowing && !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                subscriptionGate.showPaywall = true
            }
        }
        .confirmationDialog("", isPresented: Binding(
            get: { coordinator.showCreateActions },
            set: { coordinator.showCreateActions = $0 }
        ), titleVisibility: .hidden) {
            Button { coordinator.presentScanFlow(.documentCamera) } label: {
                Label(NSLocalizedString("action.scanDocuments", comment: "Scan documents to PDF"), systemImage: "doc.text.viewfinder")
            }
            Button { coordinator.presentScanFlow(.photoLibrary) } label: {
                Label(NSLocalizedString("action.convertPhotos", comment: "Convert photos to PDF"), systemImage: "photo.on.rectangle")
            }
            Button {
                coordinator.showCreateActions = false
                coordinator.showConvertPicker = true
            } label: {
                Label(NSLocalizedString("action.convertFiles", comment: "Convert files to PDF"), systemImage: "folder")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) { }
        }
        .overlay {
            if coordinator.isConvertingFile {
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
        .alert(item: coordinator.binding(for: \.alertContext)) { context in
            Alert(
                title: Text(context.title),
                message: Text(context.message),
                dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))) {
                    coordinator.alertContext = nil
                    context.onDismiss?()
                }
            )
        }
        .fullScreenCover(isPresented: Binding(
            get: { coordinator.showOnboarding },
            set: { coordinator.showOnboarding = $0 }
        )) {
            OnboardingFlowView(isPresented: Binding(
                get: { coordinator.showOnboarding },
                set: { coordinator.showOnboarding = $0 }
            ))
        }
        .onChange(of: coordinator.showOnboarding) { _, isShowing in
            // When onboarding flow is dismissed on first launch, show paywall
            if !isShowing && !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                subscriptionGate.showPaywall = true
            }
        }
        .confirmationDialog("", isPresented: Binding(
            get: { coordinator.showCreateActions },
            set: { coordinator.showCreateActions = $0 }
        ), titleVisibility: .hidden) {
            Button { coordinator.presentScanFlow(.documentCamera) } label: {
                Label(NSLocalizedString("action.scanDocuments", comment: "Scan documents to PDF"), systemImage: "doc.text.viewfinder")
            }
            Button { coordinator.presentScanFlow(.photoLibrary) } label: {
                Label(NSLocalizedString("action.convertPhotos", comment: "Convert photos to PDF"), systemImage: "photo.on.rectangle")
            }
            Button {
                coordinator.showCreateActions = false
                coordinator.showConvertPicker = true
            } label: {
                Label(NSLocalizedString("action.convertFiles", comment: "Convert files to PDF"), systemImage: "folder")
            }
            Button(NSLocalizedString("action.cancel", comment: "Cancel action"), role: .cancel) { }
        }
        .overlay {
            if coordinator.isConvertingFile {
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
}

extension ContentView {
    // MARK: - Body Builders

    /// Outer container holding the tab interface and floating compose button.
    private var rootContent: some View {
        ZStack(alignment: .top) {
            tabInterface

            if coordinator.selectedTab == .files {
                floatingCreateButton
            }

            // Cloud sync status banner at the top
            CloudSyncBanner(status: cloudSyncStatus)
                .zIndex(100)
        }
    }

    /// Hosts the four main tabs and wires callbacks back into `ContentView`.
    private var tabInterface: some View {
        TabView(selection: Binding(
            get: { coordinator.selectedTab },
            set: { coordinator.selectedTab = $0 }
        )) {
            FilesView(
                files: Binding(
                    get: { fileService.files },
                    set: { fileService.files = $0 }
                ),
                folders: Binding(
                    get: { fileService.folders },
                    set: { fileService.folders = $0 }
                ),
                onPreview: { file in Task { await coordinator.presentPreview(file, requireAuth: requireBiometrics) } },
                onShare: { coordinator.shareSavedFile($0) },
                onRename: { coordinator.presentRename($0) },
                onDelete: { coordinator.confirmDelete($0) },
                onDeleteFolder: { coordinator.confirmFolderDelete($0) },
                cloudBackup: CloudBackupManager.shared
            )
            .tabItem { Label(NSLocalizedString("tab.files", comment: "Files tab label"), systemImage: "doc") }
            .tag(Tab.files)
            .postHogScreenView("Files", [
                "file_count": fileService.files.count,
                "folder_count": fileService.folders.count
            ])

            ToolsView(onAction: coordinator.handleToolAction)
                .tabItem { Label(NSLocalizedString("tab.tools", comment: "Tools tab label"), systemImage: "wrench.and.screwdriver") }
                .tag(Tab.tools)
                .postHogScreenView("Tools")

            SettingsView()
                .tabItem { Label(NSLocalizedString("tab.settings", comment: "Settings tab label"), systemImage: "gearshape") }
                .tag(Tab.settings)
                .postHogScreenView("Settings")

            AccountView()
                .tabItem { Label(NSLocalizedString("tab.account", comment: "Account tab label"), systemImage: "person.crop.circle") }
                .tag(Tab.account)
                .postHogScreenView("Account", [
                    "subscribed": subscriptionManager.isSubscribed
                ])
        }
        .onChange(of: coordinator.selectedTab) { _, newTab in
            tabNavVM.trackTabIfNeeded(analytics: analytics, tab: newTab)
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .onAppear {
            // Track initial tab
            tabNavVM.trackTabIfNeeded(analytics: analytics, tab: coordinator.selectedTab)
        }
    }

    /// Floating action button anchored to the bottom bar that surfaces quick actions.
    private var floatingCreateButton: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                ZStack {
                    // 1) Persistent backing circle + shadow (NOT inside Menu label)
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 64, height: 64)
                        .shadow(radius: 6, y: 2)
                        .shadow(
                            color: Color.blue.opacity(createButtonPulse ? 0.5 : 0.25),
                            radius: createButtonPulse ? 24 : 8,
                            y: createButtonPulse ? 12 : 2
                        )
                        .scaleEffect(createButtonPulse ? 1.12 : 1)
                        .allowsHitTesting(false) // taps go to the Menu above

                    // 2) Menu only controls interaction + icon; no shadow here
                    Menu {
                        Button { coordinator.presentScanFlow(.documentCamera) } label: {
                            Label(
                                NSLocalizedString("action.scanDocuments", comment: "Scan documents to PDF"),
                                systemImage: "doc.text.viewfinder"
                            )
                        }

                        Button { coordinator.presentScanFlow(.photoLibrary) } label: {
                            Label(
                                NSLocalizedString("action.convertPhotos", comment: "Convert photos to PDF"),
                                systemImage: "photo.on.rectangle"
                            )
                        }

                        Button {
                            coordinator.showCreateActions = false
                            coordinator.showConvertPicker = true
                        } label: {
                            Label(
                                NSLocalizedString("action.convertFiles", comment: "Convert files to PDF"),
                                systemImage: "folder"
                            )
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)   // ensures correct tap target
                            .contentShape(Circle())          // circular hit-testing
                            .contentShape(.contextMenuPreview, Circle())
                            .accessibilityLabel(
                                NSLocalizedString("accessibility.create", comment: "Create button")
                            )
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        let generator = UIImpactFeedbackGenerator(style: .medium)
                        generator.impactOccurred()
                        createButtonPulse = false
                    })
                    .task {
                        await animateCreateButtonCueIfNeeded()
                    }
                }
            }
            .padding(.trailing, 28)
            .padding(.bottom, 60)
        }
        .allowsHitTesting(true)
    }

    
    // MARK: - Quick Action Routing

    /// Presents the document camera flow when the hardware supports it.
    private func scanDocumentsToPDF() {
        guard VNDocumentCameraViewController.isSupported else {
            coordinator.alertContext = ScanAlert(
                title: NSLocalizedString("alert.scannerUnavailable.title", comment: "Scanner unavailable title"),
                message: NSLocalizedString("alert.scannerUnavailable.message", comment: "Scanner unavailable message"),
                onDismiss: nil
            )
            return
        }
        coordinator.activeScanFlow = .documentCamera
    }

    /// Opens the shared photo picker so the user can turn images into a PDF.
    private func convertPhotosToPDF() {
        coordinator.activeScanFlow = .photoLibrary
    }

    /// Opens the "convert files" importer after collapsing the quick action sheet.
    private func convertFilesToPDF() {
        coordinator.showCreateActions = false
        coordinator.showConvertPicker = true
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
    fileprivate static let convertibleExtensions: [String] = [
        "123","602","abw","bib","bmp","cdr","cgm","cmx","csv","cwk","dbf","dif","doc","docm","docx","dot","dotm","dotx","dxf","emf","eps","epub","fodg","fodp","fods","fodt","fopd","gif","htm","html","hwp","jpeg","jpg","key","ltx","lwp","mcw","met","mml","mw","numbers","odd","odg","odm","odp","ods","odt","otg","oth","otp","ots","ott","pages","pbm","pcd","pct","pcx","pdb","pdf","pgm","png","pot","potm","potx","ppm","pps","ppt","pptm","pptx","psd","psw","pub","pwp","pxl","ras","rtf","sda","sdc","sdd","sdp","sdw","sgl","slk","smf","stc","std","sti","stw","svg","svm","swf","sxc","sxd","sxg","sxi","sxm","sxw","tga","tif","tiff","txt","uof","uop","uos","uot","vdx","vor","vsd","vsdm","vsdx","wb2","wk1","wks","wmf","wpd","wpg","wps","xbm","xhtml","xls","xlsb","xlsm","xlsx","xlt","xltm","xltx","xlw","xml","xpm","zabw"
    ]

    fileprivate static let convertibleContentTypes: [UTType] = {
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
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @State private var showSignatureSheet = false
    @State private var savedSignature: SignatureStore.Signature? = SignatureStore.load()
    @State private var showManageSubscriptionsSheet = false
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
        .manageSubscriptionsSheetIfAvailable($showManageSubscriptionsSheet)
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
                handleSubscriptionTap()
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
                        if let product = subscriptionManager.product,
                           let subscription = product.subscription {
                            let trialPrice = subscription.introductoryOffer?.displayPrice ?? "$0.49"
                            let regularPrice = product.displayPrice
                            Text(String(format: NSLocalizedString("settings.subscription.trialCopy", comment: "Subscription trial copy"), trialPrice, regularPrice))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 56)
                        } else {
                            Text(NSLocalizedString("settings.subscription.trialCopyFallback", comment: "Subscription trial copy fallback"))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 56)
                        }
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

    @MainActor
    private func handleSubscriptionTap() {
        if subscriptionManager.isSubscribed {
            presentManageSubscriptions()
        } else {
            subscriptionManager.purchase()
        }
    }

    @MainActor
    private func presentManageSubscriptions() {
        if #available(iOS 17.0, *) {
            showManageSubscriptionsSheet = true
        } else {
            subscriptionManager.openManageSubscriptionsFallback()
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

    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller: PDFEditorController
    @State private var inlineAlert: InlineAlert?
    @State private var cachedSignature: SignatureStore.Signature? = SignatureStore.load()

    init(
        context: PDFEditingContext,
        onSave: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
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
                .postHogLabel("pdf_editor_cancel")
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
                .postHogLabel("pdf_editor_save")
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
                .postHogLabel("pdf_editor_insert_signature")
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
                .postHogLabel("pdf_editor_highlight")

            }
        }
        .alert(item: $inlineAlert) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text(NSLocalizedString("action.ok", comment: "OK action"))))
        }
        .postHogScreenView("PDF Editor", [
            "file_name": context.file.name
        ])
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

/// Grid of high-level conversion/editing shortcuts surfaced on the Tools tab.
struct ToolsView: View {
    // Adaptive: fits as many columns as will cleanly fit (usually 2 on iPhone, 3 on iPad)
    private let columns = [
        GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 16)
    ]
    let onAction: (ToolAction) -> Void
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @StateObject private var vm = ToolsViewModel()
    @Environment(\.analytics) private var analytics

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ToolCard.sample) { card in
                        Button {
                            if let action = card.action {
                                vm.trackToolCardTapped(analytics: analytics, tool: action)
                                onAction(action)
                            }
                        } label: {
                            ToolCardView(card: card)
                        }
                        .postHogLabel("tool_card_\(toolActionName(card.action))")
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

    private func toolActionName(_ action: ToolAction?) -> String {
        guard let action = action else { return "unknown" }
        switch action {
        case .convertFiles: return "convert_files"
        case .scanDocuments: return "scan_documents"
        case .convertPhotos: return "convert_photos"
        case .importDocuments: return "import_documents"
        case .convertWebPage: return "convert_web"
        case .editDocuments: return "edit_documents"
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
    @EnvironmentObject private var subscriptionGate: SubscriptionGate
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
                    .postHogLabel("scan_review_share")
                    .buttonStyle(.bordered)

                    Button {
                        let updated = sanitizedDocument()
                        onSave(updated)
                        dismiss()
                    } label: {
                        Label(NSLocalizedString("action.save", comment: "Save action"), systemImage: "tray.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .postHogLabel("scan_review_save")
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
                        .postHogLabel("scan_review_cancel")
                    }
                }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url]) {
                item.cleanupHandler?()
                shareItem = nil
            }
        }
        .postHogScreenView("Scan Review")
    }

    /// Returns a sanitized copy to avoid saving with trailing spaces or empty names.
    private func sanitizedDocument() -> ScannedDocument {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return document }
        return document.withFileName(trimmed)
    }
}

// MARK: - Paywall Presenter

private struct PaywallPresenter: ViewModifier {
    let coordinator: AppCoordinator
    let subscriptionManager: SubscriptionManager
    @ObservedObject var subscriptionGate: SubscriptionGate

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $subscriptionGate.showPaywall) {
                PaywallView(productId: Bundle.main.subscriptionProductID, source: subscriptionGate.paywallSource)
                    .environmentObject(subscriptionManager)
                    .environmentObject(subscriptionGate)
            }
            .onChange(of: subscriptionGate.showPaywall) { _, isShowing in
                if !isShowing {
                    coordinator.handlePaywallDismissal()
                    subscriptionGate.handlePaywallDismissal()
                }
            }
    }
}
