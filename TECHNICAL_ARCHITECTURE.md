# PDF Converter - Technical Architecture

## Document Purpose

This document provides a comprehensive technical analysis of the PDF Converter iOS app's architecture, focusing on how components interact, data flows, concurrency patterns, state management, and implementation details. It is intended for developers, technical auditors, and AI agents building context about the codebase.

**Companion Document:** See `APP_OVERVIEW.md` for business context and feature descriptions.

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Core Design Patterns](#core-design-patterns)
3. [Component Interaction Model](#component-interaction-model)
4. [Data Flow & State Management](#data-flow--state-management)
5. [Concurrency & Threading Model](#concurrency--threading-model)
6. [File Storage Architecture](#file-storage-architecture)
7. [Cloud Synchronization System](#cloud-synchronization-system)
8. [Subscription & Monetization Flow](#subscription--monetization-flow)
9. [Network Layer & External Services](#network-layer--external-services)
10. [Analytics & Tracking Infrastructure](#analytics--tracking-infrastructure)
11. [Error Handling & Recovery](#error-handling--recovery)
12. [Performance Optimizations](#performance-optimizations)
13. [Security & Data Protection](#security--data-protection)
14. [Testing Strategy](#testing-strategy)
15. [Build Configuration & Dependencies](#build-configuration--dependencies)

---

## Architecture Overview

### High-Level Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     PDFConverterApp.swift                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  App Entry Point                                       │ │
│  │  - PostHog initialization                              │ │
│  │  - SubscriptionManager (StateObject)                   │ │
│  │  - CloudSyncStatus (StateObject)                       │ │
│  │  - RatingPromptCoordinator                             │ │
│  │  - Environment injection                               │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                      ContentView.swift                       │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Root UI Container (1,828 lines)                       │ │
│  │  - Tab interface                                       │ │
│  │  - Floating create button                             │ │
│  │  - All modal presentations (sheets, alerts, dialogs)  │ │
│  │  - Coordinator initialization                          │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────────┐
│                    AppCoordinator.swift                      │
│  ┌────────────────────────────────────────────────────────┐ │
│  │  Navigation Hub (707 lines)                            │ │
│  │  - 20+ state properties                                │ │
│  │  - Routes tool actions                                 │ │
│  │  - Coordinates paywall presentations                   │ │
│  │  - Manages file operations                             │ │
│  │  - Injects dependencies                                │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────────────────────┘
                       │
         ┌─────────────┼─────────────┬──────────────┐
         ▼             ▼             ▼              ▼
┌──────────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐
│ FileManage-  │ │  Scan    │ │  Sub-    │ │ Rating Prompt  │
│ mentService  │ │  Flow    │ │ scription│ │  Coordinator   │
│              │ │  Coord.  │ │  Gate    │ │                │
└──────────────┘ └──────────┘ └──────────┘ └────────────────┘
       │               │            │               │
       ▼               ▼            ▼               ▼
┌──────────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐
│  PDFStorage  │ │  PDF     │ │  Sub-    │ │  Rating        │
│  (Static)    │ │  Gateway │ │ scription│ │  Prompt        │
│              │ │  Client  │ │  Manager │ │  Manager       │
└──────────────┘ └──────────┘ └──────────┘ └────────────────┘
       │               │            │
       ▼               ▼            ▼
┌──────────────┐ ┌──────────┐ ┌──────────┐
│  Cloud       │ │  External│ │ StoreKit │
│  Backup      │ │  API     │ │  2       │
│  Manager     │ │  Service │ │          │
│  (Actor)     │ │          │ │          │
└──────────────┘ └──────────┘ └──────────┘
       │
       ▼
┌──────────────┐
│  CloudKit    │
│  Private DB  │
└──────────────┘
```

### Technology Stack

**UI Framework:** SwiftUI (iOS 16+)
**Concurrency:** Swift Concurrency (async/await, actors, Task)
**State Management:** SwiftUI @Observable, @StateObject, @EnvironmentObject
**Persistence:** FileManager (Documents directory) + CloudKit
**Monetization:** StoreKit 2
**Analytics:** PostHog SDK
**Apple Frameworks:**
- PDFKit (PDF rendering & manipulation)
- VisionKit (document scanning)
- PhotosUI (photo picker)
- PencilKit (signature drawing)
- LocalAuthentication (biometrics)
- CloudKit (iCloud sync)

---

## Core Design Patterns

### 1. Coordinator Pattern

**Purpose:** Centralize navigation logic and decouple view routing from view presentation.

**Implementation:**

**`AppCoordinator` (707 lines):**
- MainActor-isolated
- Uses `@Observable` macro for SwiftUI integration
- Owns all navigation state (tabs, sheets, alerts, dialogs)
- Routes user actions to appropriate services
- Manages paywall presentation strategy
- Coordinates between multiple services

**Key Responsibilities:**
```swift
@Observable
@MainActor
final class AppCoordinator {
    // Navigation state
    var selectedTab: Tab = .files
    var activeScanFlow: ScanFlow?
    var pendingDocument: ScannedDocument?
    var previewFile: PDFFile?
    var editingContext: PDFEditingContext?

    // Dialog state
    var renameTarget: PDFFile?
    var deleteTarget: PDFFile?
    var showDeleteDialog = false

    // Dependencies
    private let subscriptionManager: SubscriptionManager
    private let fileService: FileManagementService
    private let scanCoordinator: ScanFlowCoordinator

    // Action routing
    func handleToolAction(_ action: ToolAction) { ... }
    func presentPreview(_ file: PDFFile, requireAuth: Bool) async { ... }
    func requireSubscription(source: String) -> Bool { ... }
}
```

**`ScanFlowCoordinator` (299 lines):**
- Specialized coordinator for scanning and conversion workflows
- Owns conversion state and progress tracking
- Manages idle timer during long operations
- Coordinates with PDFGatewayClient for external conversions

**Benefits:**
- Single source of truth for navigation state
- Testable navigation logic (can test without UI)
- Clear separation of concerns
- Easy to add new flows without modifying views

### 2. Service Layer Pattern

**Purpose:** Encapsulate business logic and data access in dedicated services.

**Key Services:**

**`FileManagementService` (351 lines):**
```swift
@Observable
@MainActor
final class FileManagementService {
    // Published state
    var files: [PDFFile] = []
    var folders: [PDFFolder] = []
    private(set) var isLoading = false

    // Dependencies
    private let cloudBackup: CloudBackupManager
    private weak var syncStatus: CloudSyncStatus?

    // Operations
    func loadInitialFiles() async { ... }
    func saveScannedDocument(_ document: ScannedDocument) throws -> PDFFile { ... }
    func renameFile(_ file: PDFFile, to newName: String) throws -> PDFFile { ... }
    func deleteFile(_ file: PDFFile) throws { ... }
    func importDocuments(at urls: [URL]) throws -> [PDFFile] { ... }
}
```

**Responsibilities:**
- File CRUD operations
- Cloud backup coordination
- Page count lazy loading (via actor)
- Folder management
- File-to-folder mappings

**`SubscriptionManager` (473 lines):**
```swift
@MainActor
final class SubscriptionManager: ObservableObject {
    @Published private(set) var product: Product?
    @Published private(set) var isSubscribed = false
    @Published var purchaseState: PurchaseState = .idle

    // Lifecycle
    init() {
        // Load cached subscription state
        // Start monitoring entitlements
        // Listen for transaction updates
        // Start periodic validation
    }

    func purchase() { ... }
    func restorePurchases() async { ... }
    func refreshOnForeground() { ... }
}
```

**Responsibilities:**
- StoreKit product loading
- Purchase flow orchestration
- Entitlement monitoring
- Transaction verification
- Subscription state caching
- Periodic expiration validation

**`CloudBackupManager` (715 lines, Actor):**
```swift
actor CloudBackupManager {
    static let shared = CloudBackupManager()

    private let container: CKContainer?
    private let database: CKDatabase?
    private var cachedAccountStatus: CKAccountStatus?

    func backup(file: PDFFile, syncStatus: CloudSyncStatus?) async { ... }
    func restoreMissingFiles(existingRecordNames: Set<String>) async -> [PDFFile] { ... }
    func deleteBackup(for file: PDFFile) async { ... }
}
```

**Responsibilities:**
- Thread-safe CloudKit operations
- Upload/download with progress tracking
- Account status management
- Record CRUD operations
- Folder synchronization

### 3. MVVM (Model-View-ViewModel)

**Implementation:**
- ViewModels for complex views (PaywallViewModel, OnboardingViewModel, ToolsViewModel)
- Models as value types (PDFFile, PDFFolder, ScannedDocument)
- ViewModels use `@Observable` or `@ObservableObject`

**Example:**
```swift
// Model
struct PDFFile: Identifiable {
    let url: URL
    var name: String
    let date: Date
    let pageCount: Int
    let fileSize: Int64
    var folderId: String?
    let stableID: String  // UUID for CloudKit
}

// ViewModel
@Observable
final class PaywallViewModel {
    let paywallId = UUID().uuidString
    let source: String
    let productId: String

    func trackPaywallViewed(analytics: AnalyticsTracking, eligibleForIntroOffer: Bool) {
        analytics.capture("paywall_viewed", properties: [
            "paywall_id": paywallId,
            "source": source,
            "eligible_for_intro_offer": eligibleForIntroOffer
        ])
    }
}

// View
struct PaywallView: View {
    @StateObject private var vm: PaywallViewModel
    @EnvironmentObject var subscriptionManager: SubscriptionManager

    var body: some View { ... }
}
```

### 4. Actor Model for Concurrency

**Purpose:** Thread-safe access to shared mutable state.

**Implementations:**

**`CloudBackupManager` (Actor):**
- All CloudKit operations are isolated to actor
- Prevents data races on cached state
- Async methods automatically serialize access

**`PDFMetadataActor` (Actor):**
```swift
actor PDFMetadataActor {
    nonisolated func pageCount(for url: URL) async -> Int {
        guard !Task.isCancelled else { return 0 }
        guard let document = PDFDocument(url: url) else { return 0 }
        return document.pageCount
    }
}
```

**Purpose:** Offload expensive PDF parsing from main thread without blocking UI.

### 5. Dependency Injection

**Manual DI at Initialization:**
```swift
// PDFConverterApp.swift
init() {
    let cloudBackup = CloudBackupManager.shared
    let pdfGatewayClient = Self.makePDFGatewayClient()

    let fileService = FileManagementService(cloudBackup: cloudBackup)
    let scanCoordinator = ScanFlowCoordinator(
        pdfGatewayClient: pdfGatewayClient,
        fileService: fileService
    )

    _fileService = State(initialValue: fileService)
    _scanCoordinator = State(initialValue: scanCoordinator)
}
```

**Environment Injection:**
```swift
// SwiftUI environment
.environment(\.managedObjectContext, persistenceController.container.viewContext)
.environment(\.analytics, tracker)
.environmentObject(cloudSyncStatus)
.environmentObject(subscriptionManager)
.environmentObject(subscriptionGate)
```

---

## Component Interaction Model

### Typical Workflow: Scan Document → Save → Cloud Backup

**Step-by-Step Interaction:**

```
1. User Action: Tap "Scan Documents"
   ContentView → AppCoordinator.handleToolAction(.scanDocuments)
                 ↓
                 AppCoordinator.presentScanFlow(.documentCamera)
                 ↓
                 Sets: activeScanFlow = .documentCamera

2. SwiftUI Reaction: Sheet presentation
   ContentView (ScanFlowSheets modifier) observes activeScanFlow
   → Presents DocumentScannerView sheet

3. Scanning Process
   DocumentScannerView (VisionKit) → User scans pages
   → Calls completion handler with Result<[UIImage], ScanWorkflowError>

4. Scan Result Processing
   AppCoordinator.handleScanResult(result, suggestedName: "Scan...")
   ↓
   ScanFlowCoordinator.handleScanResult(result, suggestedName: ...)
   ↓
   PDFGenerator.makePDF(from: images) → Returns temporary PDF URL
   ↓
   Creates ScannedDocument(pdfURL: temp, fileName: name)
   ↓
   AppCoordinator sets: pendingDocument = document

5. Review Sheet Presentation
   ContentView (ScanFlowSheets modifier) observes pendingDocument
   → Presents ScanReviewSheet

6. User Action: Tap "Save"
   ScanReviewSheet calls: onSave(document)
   ↓
   AppCoordinator.saveScanDocument(document)
   ↓
   Checks subscription: requireSubscription(source: "scan_review_save")

   IF NOT SUBSCRIBED:
      Sets: documentPendingAfterPaywall = document
      Triggers paywall: subscriptionGate.showPaywall = true
      Returns early

   IF SUBSCRIBED:
      Continue to save...

7. File Save Operation
   AppCoordinator → FileManagementService.saveScannedDocument(document)
   ↓
   PDFStorage.save(document: document) [Static method]
   ↓
   - Moves temp file to Documents directory
   - Generates stable UUID
   - Creates PDFFile instance
   ↓
   FileManagementService inserts file at index 0 (newest first)

8. Background Page Count Loading
   FileManagementService → Task {
       pageCount = await metadataActor.pageCount(for: fileURL)
       Updates files array with pageCount
   }

9. Cloud Backup Trigger
   FileManagementService → Task {
       await backupToCloud(savedFile)
   }
   ↓
   CloudBackupManager.backup(file: file, syncStatus: syncStatus)
   ↓
   - Creates CKRecord with stable UUID as recordName
   - Uploads PDF as CKAsset
   - Sets metadata fields
   - Saves to CloudKit private database
   ↓
   CloudSyncStatus updates per-file status (syncing → synced)

10. Cleanup
    AppCoordinator → ScanCoordinator.cleanupTemporaryFile(at: document.pdfURL)
    ↓
    Deletes temporary PDF from /tmp

    AppCoordinator sets: pendingDocument = nil
    → Sheet dismisses
```

**Key Observations:**
- **Unidirectional data flow:** User action → Coordinator → Service → Storage → Cloud
- **Subscription gating:** Checked before state-changing operations
- **Async operations:** File save, page count, cloud backup all async
- **Cleanup:** Temporary files deleted after success or cancel

### Workflow: Paywall → Purchase → Restore Pending State

```
1. Subscription Required Gate
   AppCoordinator.requireSubscription(source: "scan_review_save", pendingDocument: doc)
   ↓
   IF isSubscribed: return true
   IF NOT:
      - Save pending state: documentPendingAfterPaywall = doc
      - Set paywallSource = "scan_review_save"
      - Show paywall: subscriptionGate.showPaywall = true
      - return false

2. Paywall Presentation
   ContentView (PaywallPresenter modifier) observes subscriptionGate.showPaywall
   → Presents PaywallView as fullScreenCover

3. Purchase Flow
   PaywallView → User taps "Continue"
   ↓
   SubscriptionManager.purchase()
   ↓
   Task {
       guard let product else { return }
       let appAccountToken = AnonymousIdProvider.getOrCreate() (UUID in Keychain)
       let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])

       switch result {
       case .success(let verification):
           handlePurchaseResult(verification)
           → Sets isSubscribed = true
           → Sets purchaseState = .purchased
           → Caches expiration date in UserDefaults
       case .pending:
           purchaseState = .pending
       case .userCancelled:
           purchaseState = .idle
       }
   }

4. Paywall Dismissal (on purchase success)
   PaywallView observes subscriptionManager.purchaseState
   onChange(.purchased):
       subscriptionGate.showPaywall = false

5. Restore Pending State
   ContentView observes subscriptionGate.showPaywall
   onChange(false):
       AppCoordinator.handlePaywallDismissal()
       ↓
       IF documentPendingAfterPaywall != nil:
           let doc = documentPendingAfterPaywall
           documentPendingAfterPaywall = nil
           DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
               pendingDocument = doc  // Re-present review sheet
           }

6. Re-attempt Save
   User taps "Save" again (now subscribed)
   → AppCoordinator.saveScanDocument(document)
   → requireSubscription() returns true
   → Proceeds with save (as in previous workflow)
```

### Workflow: Cloud Restore on App Launch

```
1. App Launch
   PDFConverterApp.init() → Creates SubscriptionManager, CloudSyncStatus
   ↓
   ContentView.task {
       AppCoordinator.checkPaywallOnLaunch()
   }

2. File Loading & Cloud Restore
   AppCoordinator.checkPaywallOnLaunch()
   ↓
   Task {
       await FileManagementService.loadInitialFiles()
       await FileManagementService.attemptCloudRestore()
   }

3. Load Local Files
   FileManagementService.loadInitialFiles()
   ↓
   PDFStorage.loadSavedFiles() [async static method]
   ↓
   - Scans Documents directory for .pdf files
   - Reads resource values (date, size)
   - Loads stable IDs from .file_stable_ids.json
   - Loads folder mappings from .file_folders.json
   - Creates PDFFile instances (pageCount = 0, loaded lazily)
   ↓
   Sets: files = loadedFiles.sorted { $0.date > $1.date }

4. Background Page Count Loading
   Task {
       for file in loadedFiles {
           pageCount = await metadataActor.pageCount(for: fileURL)
           Update files[index] with pageCount
       }
   }

5. Cloud Restore Check
   FileManagementService.attemptCloudRestore()
   ↓
   Guard: !hasAttemptedCloudRestore (runs once)
   ↓
   CloudBackupManager.printEnvironmentDiagnostics() [DEBUG only]
   ↓
   Restore folders:
       existingFolderIds = Set(PDFStorage.loadFolders().map { $0.id })
       restoredFolders = await cloudBackup.restoreMissingFolders(existingFolderIds: ids)
       PDFStorage.saveFolders(folders + restoredFolders)
   ↓
   Restore files:
       existingRecordIDs = Set(files.map(\.stableID))  // UUID-based
       restoredFiles = await cloudBackup.restoreMissingFiles(existingRecordNames: ids)

6. CloudKit Fetch (in CloudBackupManager)
   restoreMissingFiles(existingRecordNames: Set<String>)
   ↓
   Check iCloud availability → account status
   ↓
   fetchAllRecords() → Returns [CKRecord]
   ↓
   For each record:
       IF recordName NOT in existingRecordNames:
           Download CKAsset (PDF file)
           PDFStorage.storeCloudAsset(from: assetURL, stableID: recordName)
           → Copies file to Documents directory
           → Saves stable ID mapping
           → Returns PDFFile
   ↓
   Get folder mappings: getFileFolderMappings()
   ↓
   Apply folder IDs to restored files
   ↓
   Save folder mappings: PDFStorage.updateFileFolderId(file, folderId)

7. Merge Restored Files
   FileManagementService.attemptCloudRestore()
   ↓
   files.append(contentsOf: restoredWithFolders)
   files.sort { $0.date > $1.date }
```

**Key Insights:**
- Cloud restore happens once per app lifecycle
- Uses stable UUIDs to match CloudKit records to local files
- Folder mappings restored separately
- Non-blocking (UI shows local files immediately)
- Page counts load in background

---

## Data Flow & State Management

### State Management Strategy

**SwiftUI State Patterns Used:**

1. **@State** - Local view state (animations, temporary UI state)
2. **@StateObject** - View-owned objects with lifecycle tied to view
3. **@ObservedObject** - Shared objects passed from parent
4. **@EnvironmentObject** - App-wide shared objects (SubscriptionManager, CloudSyncStatus)
5. **@Observable** - Modern Swift 5.9+ macro for automatic change tracking
6. **@SceneStorage** - Scene-persisted values (requireBiometrics)

### State Flow Diagram

```
┌───────────────────────────────────────────────────────────┐
│                  App-Level State                          │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  SubscriptionManager (@MainActor, ObservableObject) │  │
│  │  - isSubscribed: Bool                               │  │
│  │  - purchaseState: PurchaseState                     │  │
│  │  - product: Product?                                │  │
│  └─────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  CloudSyncStatus (@MainActor, ObservableObject)     │  │
│  │  - status: SyncStatus                               │  │
│  │  - message: String?                                 │  │
│  │  - fileStatuses: [URL: FileSyncStatus]              │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
                          │
                          │ Environment Injection
                          ▼
┌───────────────────────────────────────────────────────────┐
│              Coordinator-Level State                      │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  AppCoordinator (@Observable, @MainActor)           │  │
│  │  - selectedTab: Tab                                 │  │
│  │  - activeScanFlow: ScanFlow?                        │  │
│  │  - pendingDocument: ScannedDocument?                │  │
│  │  - previewFile: PDFFile?                            │  │
│  │  - editingContext: PDFEditingContext?               │  │
│  │  - renameTarget: PDFFile?                           │  │
│  │  - deleteTarget: PDFFile?                           │  │
│  │  - showDeleteDialog: Bool                           │  │
│  │  - [20+ more navigation/dialog states]              │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
                          │
                          │ Dependency Injection
                          ▼
┌───────────────────────────────────────────────────────────┐
│              Service-Level State                          │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  FileManagementService (@Observable, @MainActor)    │  │
│  │  - files: [PDFFile]                                 │  │
│  │  - folders: [PDFFolder]                             │  │
│  │  - isLoading: Bool                                  │  │
│  │  - hasLoadedInitialFiles: Bool                      │  │
│  └─────────────────────────────────────────────────────┘  │
│  ┌─────────────────────────────────────────────────────┐  │
│  │  ScanFlowCoordinator (@Observable, @MainActor)      │  │
│  │  - isConverting: Bool                               │  │
│  │  - conversionProgress: String?                      │  │
│  └─────────────────────────────────────────────────────┘  │
└───────────────────────────────────────────────────────────┘
```

### State Synchronization Patterns

**Pattern 1: Optimistic UI Updates**

```swift
// FileManagementService.saveScannedDocument
func saveScannedDocument(_ document: ScannedDocument) throws -> PDFFile {
    let savedFile = try PDFStorage.save(document: document)

    // Immediate UI update (optimistic)
    files.insert(savedFile, at: 0)

    // Background operations (don't block UI)
    Task {
        let pageCount = await metadataActor.pageCount(for: savedFile.url)
        // Update file with actual page count
        if let index = files.firstIndex(where: { $0.stableID == savedFile.stableID }) {
            files[index] = PDFFile(..., pageCount: pageCount, ...)
        }
    }

    Task {
        await backupToCloud(savedFile)
    }

    return savedFile
}
```

**Pattern 2: Coordinator Bindings**

```swift
// AppCoordinator provides bindings for SwiftUI
func binding<T>(for keyPath: ReferenceWritableKeyPath<AppCoordinator, T?>) -> Binding<T?> {
    Binding(
        get: { self[keyPath: keyPath] },
        set: { self[keyPath: keyPath] = $0 }
    )
}

// Usage in ContentView
.sheet(item: coordinator.binding(for: \.previewFile)) { file in
    NavigationView {
        SavedPDFDetailView(file: file, coordinator: coordinator)
    }
}
```

**Pattern 3: Environment-Driven Side Effects**

```swift
// ContentView observes scenePhase
.onChange(of: scenePhase) { oldPhase, newPhase in
    if oldPhase == .background && newPhase == .active {
        subscriptionManager.refreshOnForeground()
    }
}

// SubscriptionManager refreshes entitlements
func refreshOnForeground() {
    Task { @MainActor in
        await refreshEntitlements()
    }
}
```

### Data Persistence Layers

**Layer 1: FileManager (Local Storage)**
- **Location:** `FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first`
- **Files:** PDFs with original filenames
- **Metadata:**
  - `.file_stable_ids.json` - `{ "filename.pdf": "UUID" }`
  - `.file_folders.json` - `{ "UUID": "folderID" }`
  - `.folders.json` - `[{ id, name, createdDate }]`

**Layer 2: UserDefaults (App Preferences)**
- `hasCompletedOnboarding: Bool`
- `hasEverPurchasedSubscription: Bool`
- `cachedSubscriptionState: Bool`
- `cachedExpirationDate: Date?`
- Signature drawing data (PencilKit PKDrawing)
- Rating prompt timestamps

**Layer 3: Keychain (Secure Storage)**
- `anonymousID: String` (UUID for PostHog + StoreKit attribution)

**Layer 4: CloudKit (Cloud Persistence)**
- **Container:** Custom or default CloudKit container
- **Database:** Private database (user's iCloud account)
- **Record Types:**
  - `PDFDocument` - File metadata + binary asset
  - `PDFFolder` - Folder metadata

**Layer 5: Core Data (Minimal Usage)**
- `PersistenceController.shared` created but barely used
- Model: `PDFConverter.xcdatamodeld`
- Injected via environment but no active entities in code

---

## Concurrency & Threading Model

### Threading Architecture

**MainActor Isolation:**
- All UI-related code runs on main thread
- Coordinators (`AppCoordinator`, `ScanFlowCoordinator`)
- Services (`FileManagementService`)
- ViewModels (`PaywallViewModel`, `OnboardingViewModel`)

**Actor Isolation:**
- `CloudBackupManager` (actor) - Thread-safe CloudKit operations
- `PDFMetadataActor` - Background PDF parsing

**Nonisolated Functions:**
- Static utility methods (`PDFStorage` enum methods)
- Computed properties marked `nonisolated`

### Concurrency Patterns

**Pattern 1: Structured Concurrency with Task**

```swift
// FileManagementService
func loadInitialFiles() async {
    guard !hasLoadedInitialFiles else { return }
    hasLoadedInitialFiles = true
    await refreshFromDisk()
}

func refreshFromDisk() async {
    isLoading = true
    defer { isLoading = false }

    // Cancel existing task
    pageCountLoadingTask?.cancel()

    let loadedFiles = await PDFStorage.loadSavedFiles()  // Calls nonisolated static
    files = loadedFiles.sorted { $0.date > $1.date }

    // Start background task
    pageCountLoadingTask = Task {
        for file in loadedFiles {
            guard !Task.isCancelled else { return }

            let pageCount = await metadataActor.pageCount(for: file.url)

            // Update UI on MainActor
            if let index = files.firstIndex(where: { $0.stableID == file.stableID }) {
                files[index] = PDFFile(..., pageCount: pageCount, ...)
            }
        }
    }
}
```

**Pattern 2: Actor-Isolated Cloud Operations**

```swift
actor CloudBackupManager {
    func backup(file: PDFFile, syncStatus: CloudSyncStatus?) async {
        // All operations automatically serialized by actor
        let (isAvailable, unavailableReason) = await checkCloudAvailability()
        guard isAvailable, let database else { return }

        let record = try await existingRecord(with: recordID) ?? CKRecord(...)
        await record[CloudRecordKey.fileName] = file.url.lastPathComponent as NSString
        // ... set other fields

        let result = try await database.modifyRecords(saving: [record], ...)

        // Update sync status on MainActor
        if let syncStatus {
            await syncStatus.setFileSynced(file.url)  // MainActor method
        }
    }
}
```

**Pattern 3: Task Groups for Parallel Operations**

```swift
// Not currently used, but pattern would be:
await withTaskGroup(of: PDFFile.self) { group in
    for url in urls {
        group.addTask {
            return try await convertFile(at: url)
        }
    }

    for await file in group {
        files.append(file)
    }
}
```

### Task Lifecycle Management

**Stored Tasks:**
```swift
// AppCoordinator
private var initialLoadTask: Task<Void, Never>?
private var fileConversionTask: Task<Void, Never>?

// Cancel and replace
initialLoadTask?.cancel()
initialLoadTask = Task {
    await fileService.loadInitialFiles()
}
```

**Deinit Considerations:**
```swift
nonisolated deinit {
    // Cannot access @MainActor properties from deinit
    // Task cancellation happens automatically when instance deallocates
}
```

### Long-Running Operations

**PDF Conversion (External API):**
- Polling loop with 1-second intervals
- 120-second timeout
- Idle timer disabled (prevents screen lock)
- Cancellation support via `Task.checkCancellation()`

```swift
func convertWebPage(url: URL, progressHandler: ((String) -> Void)?) async throws -> ScannedDocument {
    setIdleTimerDisabled(true)  // Keep screen awake
    defer { setIdleTimerDisabled(false) }

    do {
        try Task.checkCancellation()

        let result = try await client.convert(publicURL: url) { phase in
            self.conversionProgress = "Converting..."
            progressHandler?(self.conversionProgress!)
        }

        try Task.checkCancellation()

        let pdfData = try await downloadPDF(from: result.downloadURL)

        try Task.checkCancellation()

        return ScannedDocument(...)
    } catch is CancellationError {
        throw ScanWorkflowError.cancelled
    }
}
```

---

## File Storage Architecture

### Directory Structure

```
Documents/
├── Scan 2026-01-06.pdf              (User PDFs)
├── Photos 2026-01-06.pdf
├── Invoice 01.pdf
├── .file_stable_ids.json            (Hidden metadata)
├── .file_folders.json               (Folder mappings)
└── .folders.json                    (Folder definitions)

Temporary/
└── UUID.pdf                         (Temp files during conversion)
```

### Metadata Files Format

**`.file_stable_ids.json`:**
```json
{
  "Scan 2026-01-06.pdf": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
  "Photos 2026-01-06.pdf": "B2C3D4E5-F678-9012-BCDE-F12345678901",
  "Invoice 01.pdf": "C3D4E5F6-7890-1234-CDEF-123456789012"
}
```

**Purpose:** Map filenames to stable UUIDs that persist across renames. Used for CloudKit record identity.

**`.file_folders.json`:**
```json
{
  "A1B2C3D4-E5F6-7890-ABCD-EF1234567890": "folder-invoices-2026",
  "C3D4E5F6-7890-1234-CDEF-123456789012": "folder-invoices-2026"
}
```

**Purpose:** Map stable IDs to folder IDs. Keyed by stable ID (not filename) to survive renames.

**`.folders.json`:**
```json
[
  {
    "id": "folder-invoices-2026",
    "name": "Invoices 2026",
    "createdDate": "2026-01-06T10:00:00Z"
  },
  {
    "id": "folder-receipts",
    "name": "Receipts",
    "createdDate": "2026-01-05T15:30:00Z"
  }
]
```

### PDFFile Data Model

```swift
struct PDFFile: Identifiable, Equatable {
    let id: UUID = UUID()  // Transient ID for SwiftUI ForEach
    let url: URL           // File path
    var name: String       // Display name (without .pdf extension)
    let date: Date         // Modification date
    let pageCount: Int     // Number of pages (0 = loading)
    let fileSize: Int64    // Bytes
    var folderId: String?  // Optional folder assignment
    let stableID: String   // UUID for CloudKit identity
}
```

**Key Design Decisions:**

1. **Dual IDs:**
   - `id` - Transient UUID for SwiftUI list identity (prevents animation glitches on update)
   - `stableID` - Persistent UUID for CloudKit record names

2. **Value Type (Struct):**
   - Immutable by default
   - Cheap to copy
   - Easy to update (create new instance)

3. **Lazy Page Count:**
   - Initial load sets pageCount = 0
   - Background task updates with actual count
   - UI shows spinner while loading

### File Operations Implementation

**Save:**
```swift
static func save(document: ScannedDocument) throws -> PDFFile {
    guard let directory = documentsDirectory() else { throw ... }

    let baseName = sanitizeFileName(document.fileName)
    let destination = uniqueURL(for: baseName, in: directory)  // Adds " 01", " 02" if exists

    try FileManager.default.moveItem(at: document.pdfURL, to: destination)

    let stableID = getOrCreateStableID(for: destination)  // UUID

    return PDFFile(url: destination, ..., stableID: stableID)
}
```

**Rename:**
```swift
static func rename(file: PDFFile, to newName: String) throws -> PDFFile {
    let sanitized = sanitizeFileName(newName)
    let destination = uniqueURL(for: sanitized, in: directory)

    try FileManager.default.moveItem(at: file.url, to: destination)

    // Update stable ID mapping to point to new filename
    updateStableIDMapping(oldURL: file.url, newURL: destination)

    return PDFFile(url: destination, ..., stableID: file.stableID)  // Preserve UUID
}
```

**Delete:**
```swift
static func delete(file: PDFFile) throws {
    let stableID = loadStableID(for: file.url)

    try FileManager.default.removeItem(at: file.url)

    // Clean up metadata
    removeStableIDMapping(forFileURL: file.url)
    if let stableID {
        removeFileFolderMapping(forStableID: stableID)
    }
}
```

### Stable ID System

**Purpose:** CloudKit record names must not change when files are renamed. Stable UUIDs solve this.

**Lifecycle:**

1. **Creation:** When file is first saved, generate UUID and store mapping
2. **Rename:** Update filename → UUID mapping, preserve UUID
3. **CloudKit Sync:** Use UUID as CKRecord.ID.recordName
4. **Restore:** Match CloudKit record UUID to local file UUID
5. **Deletion:** Remove UUID mapping

**Migration Support:**

```swift
// Old code used filenames as CloudKit record names
// Migration: Convert filename-keyed mappings to UUID-keyed
private nonisolated static func migrateFileFolderMapping(_ legacy: [String: String]) -> [String: String] {
    var migrated: [String: String] = [:]
    for (fileName, folderId) in legacy {
        let fileURL = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { continue }
        let stableID = getOrCreateStableID(for: fileURL)
        migrated[stableID] = folderId  // Now keyed by UUID
    }
    return migrated
}
```

---

## Cloud Synchronization System

### CloudKit Architecture

**Container:** Custom or default CloudKit container
**Database:** Private CloudKit database (user's iCloud account)
**Concurrency:** Actor-isolated for thread safety

### Record Schema

**PDFDocument Record:**
```swift
recordName: String  // Stable UUID from PDFFile.stableID
fileName: String    // Original filename (for restore)
displayName: String // User-visible name
modifiedAt: Date    // Last modification
fileSize: Int64     // Bytes
pageCount: Int      // Number of pages
fileAsset: CKAsset  // Binary PDF file
folderId: String?   // Optional folder assignment
```

**PDFFolder Record:**
```swift
recordName: String  // "folder-{UUID}"
folderName: String
folderCreatedDate: Date
```

### Sync Flows

**Flow 1: Upload (Backup)**

```
1. User saves scanned document
   FileManagementService.saveScannedDocument(document)
   ↓
   Task {
       await cloudBackup.backup(file: savedFile, syncStatus: syncStatus)
   }

2. CloudBackupManager.backup (actor method)
   ↓
   Check iCloud availability:
       container.accountStatus() → CKAccountStatus
       IF NOT .available: return early with unavailable reason
   ↓
   Sync status update:
       await syncStatus.setFileSyncing(file.url)
   ↓
   Check if file exists:
       FileManager.default.fileExists(atPath: file.url.path)
   ↓
   Try to fetch existing record:
       let recordID = CKRecord.ID(recordName: file.stableID)  // UUID
       let record = try await database.record(for: recordID)
       ?? CKRecord(recordType: "PDFDocument", recordID: recordID)
   ↓
   Populate record fields:
       await record[CloudRecordKey.fileName] = file.url.lastPathComponent as NSString
       await record[CloudRecordKey.displayName] = file.name as NSString
       await record[CloudRecordKey.fileAsset] = CKAsset(fileURL: file.url)
       // ... other fields
   ↓
   Save to CloudKit:
       let result = try await database.modifyRecords(
           saving: [record],
           deleting: [],
           savePolicy: .allKeys,
           atomically: true
       )
   ↓
   Update sync status:
       await syncStatus.setFileSynced(file.url)
```

**Flow 2: Download (Restore)**

```
1. App launch
   FileManagementService.attemptCloudRestore()
   ↓
   Guard: !hasAttemptedCloudRestore (run once)
   ↓
   Load existing files:
       existingRecordIDs = Set(files.map(\.stableID))

2. Fetch CloudKit records
   CloudBackupManager.restoreMissingFiles(existingRecordNames: existingRecordIDs)
   ↓
   Check iCloud availability
   ↓
   Query all PDFDocument records:
       fetchAllRecords() → [CKRecord]
       (Uses CKQueryOperation with TRUEPREDICATE, sorted by createdTimestamp)

3. Identify missing files
   For each CKRecord:
       IF record.recordID.recordName NOT in existingRecordIDs:
           → File is missing locally, restore it

4. Download and store
   For missing record:
       Get CKAsset from record[CloudRecordKey.fileAsset]
       let assetURL = asset.fileURL  // CloudKit downloads to temp location
       ↓
       PDFStorage.storeCloudAsset(
           from: assetURL,
           preferredName: record[CloudRecordKey.fileName],
           stableID: record.recordID.recordName  // Preserve UUID
       )
       ↓
       Copy file to Documents directory
       Save stable ID mapping
       Return PDFFile

5. Get folder mappings
   CloudBackupManager.getFileFolderMappings()
   ↓
   Query all records, build mapping: [stableID: folderId]

6. Apply folder assignments
   For each restored file:
       IF mappings[file.stableID] exists:
           PDFStorage.updateFileFolderId(file: file, folderId: mappings[file.stableID])

7. Merge into local array
   FileManagementService:
       files.append(contentsOf: restoredFiles)
       files.sort { $0.date > $1.date }
```

### Sync Status Tracking

**CloudSyncStatus (ObservableObject, MainActor):**
```swift
@MainActor
final class CloudSyncStatus: ObservableObject {
    enum SyncStatus {
        case idle
        case syncing(count: Int)
        case success(message: String)
        case error(message: String)
        case unavailable(reason: String)
    }

    @Published var status: SyncStatus = .idle
    @Published var fileStatuses: [URL: FileSyncStatus] = [:]

    func setFileSyncing(_ url: URL) {
        fileStatuses[url] = .syncing
    }

    func setFileSynced(_ url: URL) {
        fileStatuses[url] = .synced
    }

    func setFileFailed(_ url: URL, error: String) {
        fileStatuses[url] = .failed(error)
    }
}
```

**UI Integration:**
```swift
// FilesView shows per-file status
if let status = cloudSyncStatus.fileStatuses[file.url] {
    switch status {
    case .syncing:
        ProgressView()
    case .synced:
        Image(systemName: "checkmark.icloud")
            .foregroundColor(.green)
    case .failed(let error):
        Image(systemName: "exclamationmark.icloud")
            .foregroundColor(.orange)
            .onTapGesture {
                // Retry sync
                Task {
                    await CloudBackupManager.shared.backup(file: file, syncStatus: cloudSyncStatus)
                }
            }
    }
}
```

### Conflict Resolution

**Strategy:** Last-write-wins (CloudKit default with .allKeys save policy)

**Scenarios:**

1. **File renamed on Device A, modified on Device B:**
   - Device A uploads with new displayName, same stableID
   - Device B uploads with old displayName, same stableID
   - Last upload wins (CloudKit overwrites)

2. **File deleted on Device A, still exists on Device B:**
   - Device A deletes CloudKit record
   - Device B's next sync won't find the record
   - No automatic deletion of local file (intentional - safety)

3. **Folder assignment changed:**
   - folderId field updated in CloudKit record
   - Next restore respects latest folderId

**No Automatic Conflict UI** - App assumes single user across devices, relies on CloudKit's atomic operations.

### Error Handling

**CloudKit Error Types:**
- `.notAuthenticated` - User not signed into iCloud
- `.networkUnavailable` - No internet connection
- `.quotaExceeded` - iCloud storage full
- `.unknownItem` - Record doesn't exist (safe to ignore on delete)
- `.invalidArguments` - Schema not configured (return empty array)

**Graceful Degradation:**
```swift
let (isAvailable, unavailableReason) = await checkCloudAvailability()
guard isAvailable else {
    if let syncStatus, let reason = unavailableReason {
        await syncStatus.setUnavailable(reason)
    }
    return  // Don't fail, just skip sync
}
```

---

## Subscription & Monetization Flow

### StoreKit 2 Architecture

**SubscriptionManager Lifecycle:**

1. **Initialization:**
   ```swift
   init() {
       productID = Bundle.main.subscriptionProductID
       isSubscribed = loadCachedSubscriptionState()  // From UserDefaults

       Task { await loadProduct() }
       Task { await monitorEntitlements() }
       Task { await listenForTransactions() }

       startPeriodicValidation()  // Timer every 60s
   }
   ```

2. **Product Loading:**
   ```swift
   private func loadProduct() async {
       let products = try await Product.products(for: [productID])
       product = products.first
   }
   ```

3. **Entitlement Monitoring:**
   ```swift
   private func monitorEntitlements() async {
       for await entitlement in Transaction.currentEntitlements {
           if case .verified(let transaction) = entitlement,
              transaction.productID == productID {
               let isActive = transaction.revocationDate == nil &&
                              (transaction.expirationDate ?? .distantFuture) > Date()
               isSubscribed = isActive
               cacheSubscriptionState(isActive: isActive, expirationDate: transaction.expirationDate)
           }
       }
   }
   ```

4. **Transaction Updates:**
   ```swift
   private func listenForTransactions() async {
       for await result in Transaction.updates {
           await handleTransactionUpdate(result)
       }
   }
   ```

### Purchase Flow

**User Journey:**

```
1. User taps gated feature (e.g., "Save" button)
   AppCoordinator.saveScanDocument(document)
   ↓
   requireSubscription(source: "scan_review_save", pendingDocument: document)
   ↓
   IF NOT isSubscribed:
       subscriptionGate.paywallSource = "scan_review_save"
       documentPendingAfterPaywall = document
       subscriptionGate.showPaywall = true
       return false

2. Paywall presented
   ContentView (PaywallPresenter modifier) observes subscriptionGate.showPaywall
   → fullScreenCover(isPresented: $subscriptionGate.showPaywall) {
       PaywallView(productId: productID, source: subscriptionGate.paywallSource)
   }

3. User taps "Continue" button
   PaywallView → SubscriptionManager.purchase()
   ↓
   Task {
       let anonID = AnonymousIdProvider.getOrCreate()  // UUID from Keychain
       let appAccountToken = UUID(uuidString: anonID)!

       let result = try await product.purchase(options: [.appAccountToken(appAccountToken)])

       switch result {
       case .success(let verification):
           handlePurchaseResult(verification)
       case .pending:
           purchaseState = .pending
       case .userCancelled:
           purchaseState = .idle
       }
   }

4. Purchase verification
   handlePurchaseResult(verification)
   ↓
   switch verification {
   case .verified(let transaction):
       let isActive = transaction.revocationDate == nil &&
                     (transaction.expirationDate ?? .distantFuture) > Date()
       isSubscribed = isActive
       purchaseState = .purchased
       markPurchaseCompleted()  // UserDefaults flag
       cacheSubscriptionState(isActive: true, expirationDate: transaction.expirationDate)
       await transaction.finish()
   case .unverified(_, let error):
       purchaseState = .failed(error.localizedDescription)
   }

5. Paywall dismissal
   PaywallView.onChange(of: subscriptionManager.purchaseState) { _, newState in
       if newState == .purchased {
           subscriptionGate.showPaywall = false
       }
   }

6. Restore pending state
   ContentView.onChange(of: subscriptionGate.showPaywall) { _, isPresented in
       if !isPresented {
           coordinator.handlePaywallDismissal()
       }
   }
   ↓
   AppCoordinator.handlePaywallDismissal()
   ↓
   IF documentPendingAfterPaywall != nil:
       DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
           pendingDocument = documentPendingAfterPaywall
           documentPendingAfterPaywall = nil
       }

7. User completes action
   Review sheet re-presented
   User taps "Save" again
   → requireSubscription() returns true (now subscribed)
   → Proceeds with save operation
```

### Subscription State Caching

**Purpose:** Instant UI rendering without waiting for StoreKit network calls.

**Implementation:**
```swift
private func loadCachedSubscriptionState() -> Bool {
    guard let expirationDate = UserDefaults.standard.object(forKey: cachedExpirationDateKey) as? Date else {
        return false
    }
    return expirationDate > Date()  // Still active
}

private func cacheSubscriptionState(isActive: Bool, expirationDate: Date?) {
    if isActive, let expirationDate = expirationDate {
        UserDefaults.standard.set(expirationDate, forKey: cachedExpirationDateKey)
    } else {
        UserDefaults.standard.removeObject(forKey: cachedExpirationDateKey)
    }
}
```

**Validation:**
```swift
private func startPeriodicValidation() {
    validationTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
            await self?.validateCurrentExpiration()
        }
    }
}

private func validateCurrentExpiration() async {
    guard isSubscribed else { return }

    guard let cachedExpiration = UserDefaults.standard.object(forKey: cachedExpirationDateKey) as? Date else {
        return
    }

    if cachedExpiration <= Date() {
        isSubscribed = false
        UserDefaults.standard.removeObject(forKey: cachedExpirationDateKey)
        await refreshEntitlements()  // Double-check with StoreKit
    }
}
```

### Restore Purchases

**Flow:**
```swift
func restorePurchases() async {
    purchaseState = .purchasing

    do {
        try await AppStore.sync()  // Syncs with App Store

        for await result in Transaction.currentEntitlements {
            if case .verified(let transaction) = result,
               transaction.productID == productID {
                let isActive = transaction.revocationDate == nil &&
                              (transaction.expirationDate ?? .distantFuture) > Date()

                if isActive {
                    isSubscribed = true
                    markPurchaseCompleted()
                    cacheSubscriptionState(isActive: true, expirationDate: transaction.expirationDate)
                    await transaction.finish()
                    purchaseState = .purchased
                    return
                }
            }
        }

        // No active subscription found
        purchaseState = .failed("No active subscription found. Ensure you're signed in with the same Apple ID.")
    } catch {
        purchaseState = .failed("Restore failed: \(error.localizedDescription)")
    }
}
```

### Anonymous ID for Attribution

**Purpose:** Track users across purchase flows without PII.

**Implementation:**
```swift
// AnonymousIdProvider.swift
static func getOrCreate() -> String {
    let key = "anonymousID"

    // Try to load existing ID from Keychain
    if let existing = KeychainHelper.load(key: key) {
        return existing
    }

    // Generate new UUID
    let newID = UUID().uuidString
    KeychainHelper.save(key: key, value: newID)
    return newID
}
```

**Usage:**
1. **PostHog Identification:**
   ```swift
   let anonId = AnonymousIdProvider.getOrCreate()
   PostHogTracker.identify(anonId)
   ```

2. **StoreKit Attribution:**
   ```swift
   let appAccountToken = UUID(uuidString: anonId)!
   product.purchase(options: [.appAccountToken(appAccountToken)])
   ```

This allows correlating PostHog events with StoreKit purchase events using the same UUID.

---

## Network Layer & External Services

### PDFGatewayClient Architecture

**Base Configuration:**
```swift
public struct Config: Sendable {
    public let baseURL: URL
    public let pollInterval: TimeInterval
    public let timeout: TimeInterval
    public let userAgent: String?
}

// Initialization in ContentView
let config = PDFGatewayClient.Config(
    baseURL: URL(string: "https://gotenberg-6a3w.onrender.com")!,
    pollInterval: 1.0,
    timeout: 120.0
)
let client = PDFGatewayClient(config: config)
```

### Job Types & Routing

**Job Type Selection:**
```swift
private static func jobType(forFilename name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "epub", "mobi", "azw", "azw3":
        return "EBOOK_TO_PDF"  // Calibre backend
    default:
        return "DOC_TO_PDF"    // LibreOffice backend (via Gotenberg)
    }
}
```

### Conversion Workflow: URL to PDF

**API Flow:**

```
1. Create Job
   POST /v1/jobs
   Body: { "type": "URL_TO_PDF", "url": "https://example.com" }
   ↓
   Response: { "job_id": "abc123", "status": "QUEUED" }

2. Poll for Completion
   GET /v1/jobs/abc123
   ↓
   Response (in-progress): { "status": "PROCESSING" }
   ↓
   Wait 1 second, poll again
   ↓
   Response (complete): { "status": "SUCCEEDED", "download_url": "https://s3.amazonaws.com/..." }

3. Download PDF
   GET https://s3.amazonaws.com/signed-url
   ↓
   Response: Binary PDF data

4. Save to Temp
   Write data to FileManager.default.temporaryDirectory/UUID.pdf
```

**Implementation:**
```swift
public func convert(publicURL: URL, progress: ((ConversionPhase) -> Void)?) async throws -> PDFGatewayResult {
    guard publicURL.scheme == "https" || publicURL.scheme == "http" else {
        throw PDFGatewayError.invalidURL(publicURL.absoluteString)
    }

    let create = try await createURLJob(url: publicURL.absoluteString)
    let jobId = create.job_id

    progress?(.converting)

    let downloadURL = try await waitForCompletion(jobId: jobId)

    return PDFGatewayResult(jobId: jobId, downloadURL: downloadURL)
}
```

### Conversion Workflow: File to PDF

**API Flow:**

```
1. Create Job with Upload Request
   POST /v1/jobs
   Body: { "type": "DOC_TO_PDF", "original_filename": "document.docx" }
   ↓
   Response: {
       "job_id": "def456",
       "status": "CREATED",
       "upload": {
           "method": "PUT",
           "url": "https://s3.amazonaws.com/signed-upload-url"
       }
   }

2. Upload File to S3
   PUT https://s3.amazonaws.com/signed-upload-url
   Headers: { "Content-Type": "application/octet-stream" }
   Body: Binary file data
   ↓
   Response: 200 OK

3. Submit Job for Processing
   POST /v1/jobs/def456/submit
   ↓
   Response: { "status": "QUEUED" } or { "status": "SUCCEEDED", "download_url": "..." }

4. Poll for Completion (if not immediate)
   GET /v1/jobs/def456
   ↓
   Response (complete): { "status": "SUCCEEDED", "download_url": "https://s3..." }

5. Download PDF
   GET https://s3.amazonaws.com/signed-download-url
   ↓
   Save to temp file
```

**Implementation:**
```swift
public func convert(fileURL: URL, filename: String, progress: ((ConversionPhase) -> Void)?) async throws -> PDFGatewayResult {
    let type = Self.jobType(forFilename: filename)

    // Create job
    let create = try await createFileJob(type: type, originalFilename: filename)
    let jobId = create.job_id

    guard let uploadURL = URL(string: create.upload?.url ?? "") else {
        throw PDFGatewayError.unexpectedResponse
    }

    // Upload file
    progress?(.uploading)
    try await uploadFile(to: uploadURL, fileURL: fileURL)

    // Submit job
    progress?(.converting)
    let submit = try await submitFileJob(jobId: jobId)

    // If already succeeded, return immediately
    if submit.status == "SUCCEEDED", let downloadURL = URL(string: submit.download_url ?? "") {
        return PDFGatewayResult(jobId: jobId, downloadURL: downloadURL)
    }

    // Otherwise, poll until complete
    let downloadURL = try await waitForCompletion(jobId: jobId)
    return PDFGatewayResult(jobId: jobId, downloadURL: downloadURL)
}
```

### Polling Implementation

**Exponential Backoff Not Used (Fixed 1s Interval):**

```swift
private func waitForCompletion(jobId: String) async throws -> URL {
    let deadline = Date().addingTimeInterval(config.timeout)  // 120 seconds

    while Date() < deadline {
        let status = try await getJob(jobId: jobId)

        switch status.status {
        case "SUCCEEDED":
            if let downloadURL = URL(string: status.download_url ?? "") {
                return downloadURL
            }
            throw PDFGatewayError.unexpectedResponse

        case "FAILED":
            let message = status.error_message ?? status.error ?? "Unknown error"
            throw PDFGatewayError.jobFailed(jobId: jobId, message: message)

        default:  // QUEUED, PROCESSING, etc.
            try await Task.sleep(nanoseconds: UInt64(config.pollInterval * 1_000_000_000))
        }
    }

    throw PDFGatewayError.timeout(jobId: jobId)
}
```

### Error Handling

**Custom Error Types:**
```swift
public enum PDFGatewayError: Error, LocalizedError {
    case invalidURL(String)
    case invalidFilename(String)
    case serverError(String)
    case unexpectedResponse
    case jobFailed(jobId: String, message: String)
    case timeout(jobId: String)

    public var errorDescription: String? {
        switch self {
        case .timeout(let jobId):
            return "Timed out waiting for conversion (\(jobId))"
        case .jobFailed(let jobId, let message):
            return "Conversion failed (\(jobId)): \(message)"
        // ... other cases
        }
    }
}
```

**User-Facing Error Presentation:**
```swift
// ScanFlowCoordinator
func convertWebPage(url: URL) async throws -> ScannedDocument {
    do {
        let result = try await client.convert(publicURL: url) { ... }
        // ... success path
    } catch let error as PDFGatewayError {
        throw ScanWorkflowError.failed(error.localizedDescription)
    } catch {
        throw ScanWorkflowError.failed(error.localizedDescription)
    }
}

// AppCoordinator
func handleWebConversion(urlString: String) async {
    do {
        let document = try await scanCoordinator.convertWebPage(url: url) { progress in
            self.conversionProgress = progress
        }
        pendingDocument = document
    } catch {
        alertContext = ScanAlert(
            title: "Conversion Failed",
            message: error.localizedDescription,
            onDismiss: nil
        )
    }
}
```

---

## Analytics & Tracking Infrastructure

### PostHog SDK Integration

**Initialization:**
```swift
// PDFConverterApp.init()
let POSTHOG_API_KEY = "phc_FQdK7M4eYcjjhgNYiHScD1OoeOyYFVMwqWR2xvoq4yR"
let POSTHOG_HOST = "https://us.i.posthog.com"

let config = PostHogConfig(apiKey: POSTHOG_API_KEY, host: POSTHOG_HOST)
config.sessionReplay = true
config.sessionReplayConfig.maskAllImages = true
config.sessionReplayConfig.maskAllTextInputs = true
config.sessionReplayConfig.screenshotMode = true
config.captureElementInteractions = true
config.captureApplicationLifecycleEvents = true
config.captureScreenViews = false  // Manual tracking via .postHogScreenView()

PostHogSDK.shared.setup(config)

let anonId = AnonymousIdProvider.getOrCreate()
PostHogTracker.identify(anonId)
```

### AnalyticsTracking Protocol

**Environment-Based Injection:**
```swift
protocol AnalyticsTracking {
    func capture(_ event: String, properties: [String: Any]?)
    func identify(_ userId: String)
}

struct PostHogTracker: AnalyticsTracking {
    func capture(_ event: String, properties: [String: Any]?) {
        PostHogSDK.shared.capture(event, properties: properties)
    }

    func identify(_ userId: String) {
        PostHogSDK.shared.identify(userId)
    }
}

// Environment injection
extension EnvironmentValues {
    @Entry var analytics: AnalyticsTracking = PostHogTracker()
}

// Usage in views
@Environment(\.analytics) private var analytics

analytics.capture("button_tapped", properties: ["button": "create"])
```

### Screen View Tracking

**Custom ViewModifier:**
```swift
extension View {
    func postHogScreenView(_ screenName: String, _ properties: [String: Any] = [:]) -> some View {
        self.modifier(PostHogScreenViewModifier(screenName: screenName, properties: properties))
    }
}

struct PostHogScreenViewModifier: ViewModifier {
    let screenName: String
    let properties: [String: Any]
    @Environment(\.analytics) private var analytics

    func body(content: Content) -> some View {
        content.onAppear {
            var props = properties
            props["screen_name"] = screenName
            analytics.capture("$screen", properties: props)
        }
    }
}

// Usage
struct FilesView: View {
    var body: some View {
        List { ... }
            .postHogScreenView("Files")
    }
}
```

### Event Tracking Patterns

**Pattern 1: Feature Usage**
```swift
// ToolsView
ToolCard(
    icon: "doc.text.viewfinder",
    title: "Scan Documents",
    action: {
        analytics.capture("tool_card_tapped", properties: [
            "tool": "scan_documents",
            "source": "tools_tab"
        ])
        coordinator.handleToolAction(.scanDocuments)
    }
)
```

**Pattern 2: Subscription Funnel**
```swift
// PaywallViewModel
func trackPaywallViewed(analytics: AnalyticsTracking, eligibleForIntroOffer: Bool) {
    analytics.capture("paywall_viewed", properties: [
        "paywall_id": paywallId,
        "source": source,
        "product_id": productId,
        "eligible_for_intro_offer": eligibleForIntroOffer
    ])
}

func trackPurchaseAttempted(analytics: AnalyticsTracking) {
    analytics.capture("purchase_attempted", properties: [
        "paywall_id": paywallId,
        "source": source,
        "product_id": productId
    ])
}

func trackPurchaseResult(analytics: AnalyticsTracking, success: Bool, error: String?) {
    analytics.capture("purchase_completed", properties: [
        "paywall_id": paywallId,
        "success": success,
        "error": error
    ])
}
```

**Pattern 3: User Flow Milestones**
```swift
// RatingPromptManager
func recordConversionCompleted() {
    analytics.capture("conversion_completed", properties: [
        "total_conversions": totalConversions
    ])

    if totalConversions == 1 {
        analytics.capture("first_conversion_completed", properties: [:])
    }
}
```

### Apple Search Ads Attribution

**ASAUploader:**
```swift
static func sendIfNeeded() {
    let hasUploadedKey = "hasUploadedASAToken"
    guard !UserDefaults.standard.bool(forKey: hasUploadedKey) else { return }

    Task {
        do {
            let token = try await AAAttribution.attributionToken()

            // Upload to PostHog
            PostHogSDK.shared.capture("asa_attribution", properties: [
                "asa_token": token
            ])

            UserDefaults.standard.set(true, forKey: hasUploadedKey)
        } catch {
            // Silently fail (ASA not available or user opted out)
        }
    }
}
```

**Called on App Launch:**
```swift
// PDFConverterApp.init()
ASAUploader.sendIfNeeded()
```

---

## Error Handling & Recovery

### Error Hierarchy

**Custom Error Types:**

```swift
enum ScanWorkflowError: Error, LocalizedError {
    case noImages
    case cancelled
    case failed(String)
    case underlying(Error)
    case unavailable

    var shouldDisplayAlert: Bool {
        switch self {
        case .cancelled: return false
        default: return true
        }
    }

    var message: String {
        switch self {
        case .noImages: return "No images were captured"
        case .cancelled: return "Operation cancelled"
        case .failed(let msg): return msg
        case .underlying(let error): return error.localizedDescription
        case .unavailable: return "Service unavailable"
        }
    }
}

enum PDFGatewayError: Error, LocalizedError {
    case invalidURL(String)
    case serverError(String)
    case timeout(jobId: String)
    case jobFailed(jobId: String, message: String)
    // ... see Network Layer section
}

enum PDFEditingError: Error {
    case writeFailed
}
```

### Alert Context Pattern

**ScanAlert Model:**
```swift
struct ScanAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let onDismiss: (() -> Void)?
}

// AppCoordinator
var alertContext: ScanAlert?

// ContentView
.alert(item: coordinator.binding(for: \.alertContext)) { alert in
    Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        dismissButton: .default(Text("OK")) {
            alert.onDismiss?()
        }
    )
}
```

### Error Recovery Strategies

**Strategy 1: Retry with Exponential Backoff (Not Currently Implemented)**

Current implementation uses fixed 1-second polling. Potential improvement:

```swift
// Future enhancement
var retryCount = 0
let maxRetries = 3
let baseDelay = 1.0

while retryCount < maxRetries {
    do {
        return try await performOperation()
    } catch {
        retryCount += 1
        if retryCount >= maxRetries { throw error }
        let delay = baseDelay * pow(2.0, Double(retryCount - 1))
        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }
}
```

**Strategy 2: Graceful Degradation**

```swift
// CloudBackupManager
let (isAvailable, unavailableReason) = await checkCloudAvailability()
guard isAvailable else {
    if let syncStatus, let reason = unavailableReason {
        await syncStatus.setUnavailable(reason)
    }
    return  // App continues without cloud sync
}
```

**Strategy 3: User-Initiated Retry**

```swift
// Cloud sync failed indicator with tap-to-retry
Image(systemName: "exclamationmark.icloud")
    .foregroundColor(.orange)
    .onTapGesture {
        Task {
            await CloudBackupManager.shared.backup(file: file, syncStatus: cloudSyncStatus)
        }
    }
```

**Strategy 4: Cached Fallbacks**

```swift
// SubscriptionManager uses cached expiration date
private func loadCachedSubscriptionState() -> Bool {
    guard let expirationDate = UserDefaults.standard.object(forKey: cachedExpirationDateKey) as? Date else {
        return false
    }
    return expirationDate > Date()
}

// Allows instant UI rendering even if StoreKit network call is slow
init() {
    isSubscribed = loadCachedSubscriptionState()  // Immediate
    Task { await loadProduct() }  // Async
    Task { await monitorEntitlements() }  // Async
}
```

### Task Cancellation

**Cancellation Checkpoints:**
```swift
func convertFileUsingLibreOffice(url: URL) async throws -> ScannedDocument {
    defer { isConverting = false }

    do {
        try Task.checkCancellation()  // Before network call

        let result = try await client.convert(fileURL: url, filename: filename) { ... }

        try Task.checkCancellation()  // After conversion

        let pdfData = try await downloadPDF(from: result.downloadURL)

        try Task.checkCancellation()  // After download

        let outputURL = try persistPDFData(pdfData)
        return ScannedDocument(pdfURL: outputURL, fileName: name)

    } catch is CancellationError {
        throw ScanWorkflowError.cancelled
    }
}
```

**User-Initiated Cancellation:**
- Sheet dismissal cancels associated Task
- AppCoordinator stores Task references and cancels on new operations

### Logging Strategy

**OSLog Framework:**
```swift
private static let conversionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.roguewaveapps.pdfconverter",
    category: "Conversion"
)

conversionLogger.error("Failed to load PDF Gateway base URL configuration.")
```

**DEBUG Logging:**
```swift
#if DEBUG
print("☁️ Starting cloud backup for \(files.count) file(s)")
print("☁️ Container: \(container?.containerIdentifier ?? "none")")
print("☁️ Database: \(database.databaseScope.rawValue)")
#endif
```

---

## Performance Optimizations

### 1. Lazy Page Count Loading

**Problem:** Parsing PDFs to get page counts blocks UI during initial file list load.

**Solution:** Load files without page counts, compute in background.

```swift
// PDFStorage.loadSavedFiles() - Fast initial load
static func loadSavedFiles() async -> [PDFFile] {
    let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }

    return pdfs.compactMap { url in
        loadPDFFileMetadataFast(url: url)  // pageCount = 0
    }
}

// FileManagementService - Background computation
func refreshFromDisk() async {
    let loadedFiles = await PDFStorage.loadSavedFiles()
    files = loadedFiles  // UI updates immediately

    pageCountLoadingTask = Task {
        for file in loadedFiles {
            guard !Task.isCancelled else { return }

            let pageCount = await metadataActor.pageCount(for: file.url)  // Off main thread

            // Update UI incrementally
            if let index = files.firstIndex(where: { $0.stableID == file.stableID }) {
                files[index] = PDFFile(..., pageCount: pageCount, ...)
            }
        }
    }
}
```

**Actor for Thread Safety:**
```swift
actor PDFMetadataActor {
    nonisolated func pageCount(for url: URL) async -> Int {
        guard !Task.isCancelled else { return 0 }
        guard let document = PDFDocument(url: url) else { return 0 }
        return document.pageCount  // CPU-intensive, runs on actor queue
    }
}
```

### 2. Thumbnail Caching

**Implementation:** (Not shown in provided code, but pattern would be)

```swift
class ThumbnailCache {
    private var cache = NSCache<NSURL, UIImage>()

    func thumbnail(for url: URL, size: CGSize) async -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) {
            return cached
        }

        guard let thumbnail = await generateThumbnail(for: url, size: size) else {
            return nil
        }

        cache.setObject(thumbnail, forKey: url as NSURL)
        return thumbnail
    }
}
```

### 3. Stable ID Caching

**Avoids JSON reads on every file access:**

```swift
// Cache stable IDs in memory (not currently implemented, but could be)
private static var stableIDCache: [String: String] = [:]

static func getOrCreateStableID(for fileURL: URL) -> String {
    let key = fileURL.lastPathComponent

    if let cached = stableIDCache[key] {
        return cached
    }

    // Load from disk
    if let url = fileStableIDsFileURL,
       let data = try? Data(contentsOf: url),
       let mapping = try? JSONDecoder().decode([String: String].self, from: data),
       let existingID = mapping[key] {
        stableIDCache[key] = existingID
        return existingID
    }

    // Generate new
    let newID = UUID().uuidString
    saveStableID(newID, for: fileURL)
    stableIDCache[key] = newID
    return newID
}
```

### 4. Task Cancellation for Stale Operations

**Cancel previous tasks before starting new ones:**

```swift
// FileManagementService
private var pageCountLoadingTask: Task<Void, Never>?

func refreshFromDisk() async {
    pageCountLoadingTask?.cancel()  // Cancel old task

    pageCountLoadingTask = Task {
        for file in loadedFiles {
            guard !Task.isCancelled else { return }  // Check cancellation
            // ... load page count
        }
    }
}
```

### 5. Idle Timer Management

**Prevent screen lock during long operations:**

```swift
// ScanFlowCoordinator
private func setIdleTimerDisabled(_ disabled: Bool) {
    DispatchQueue.main.async {
        UIApplication.shared.isIdleTimerDisabled = disabled
        self.isIdleTimerDisabled = disabled
    }
}

func convertWebPage(url: URL) async throws -> ScannedDocument {
    setIdleTimerDisabled(true)
    defer { setIdleTimerDisabled(false) }

    // Long-running conversion...
}
```

### 6. Subscription State Caching

**Avoid StoreKit network call on every app launch:**

```swift
// SubscriptionManager.init()
isSubscribed = loadCachedSubscriptionState()  // Instant from UserDefaults

// Background verification
Task { await monitorEntitlements() }  // Async, updates if changed
```

---

## Security & Data Protection

### Local Data Protection

**File System Encryption:**
- iOS automatically encrypts files in Documents directory (Data Protection Class C by default)
- No custom encryption implemented

**Biometric Authentication:**
```swift
// BiometricAuthenticator
static func authenticate(reason: String) async -> AuthResult {
    let context = LAContext()
    var error: NSError?

    guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
        if let error = error {
            return .unavailable(error.localizedDescription)
        }
        return .unavailable("Biometrics not available")
    }

    do {
        let success = try await context.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        )
        return success ? .success : .failed
    } catch {
        return .error(error.localizedDescription)
    }
}

// Usage in AppCoordinator
func presentPreview(_ file: PDFFile, requireAuth: Bool) async {
    guard requireAuth else {
        previewFile = file
        return
    }

    let result = await BiometricAuthenticator.authenticate(reason: "Unlock PDF preview")

    switch result {
    case .success:
        previewFile = file
    case .failed, .cancelled:
        // Don't show file
        break
    case .unavailable(let message), .error(let message):
        alertContext = ScanAlert(title: "Authentication Failed", message: message, ...)
    }
}
```

### Network Security

**HTTPS Enforcement:**
- All external API calls use HTTPS
- HTTP URLs automatically upgraded in web conversion

**CloudKit Security:**
- Private database (user's iCloud account)
- Apple's end-to-end encryption
- No custom authentication needed

**Signed URLs:**
- PDF Gateway uses signed S3 URLs for uploads/downloads
- Temporary credentials, expire after use

### Privacy & Data Minimization

**No User Accounts:**
- No email, password, or registration
- Anonymous ID in Keychain (UUID, no PII)

**PostHog Privacy:**
```swift
config.sessionReplayConfig.maskAllImages = true
config.sessionReplayConfig.maskAllTextInputs = true
```

**Photo Access:**
- Uses PHPicker (runs in separate process)
- No persistent photo library access

**No Background Uploads:**
- Cloud sync only when app is active
- User can disable iCloud in iOS Settings

### Entitlements

**Required Capabilities:**
- iCloud (CloudKit + iCloud Documents)
- In-App Purchase (StoreKit)
- Push Notifications (for CloudKit change notifications)

**Info.plist Privacy Strings:**
- Camera Usage: "To scan documents and create PDFs"
- (PhotosUI doesn't require NSPhotoLibraryUsageDescription)

---

## Testing Strategy

### Unit Tests

**Observed Pattern:** Minimal unit test coverage in provided code.

**Target:** `pdf-converterTests/PDFConverterTests.swift`

**Recommended Test Cases:**

```swift
// PDFStorage tests
func testSaveDocument_CreatesFile() {
    let document = ScannedDocument(pdfURL: tempURL, fileName: "Test")
    let file = try PDFStorage.save(document: document)
    XCTAssertTrue(FileManager.default.fileExists(atPath: file.url.path))
}

func testStableID_PersistsAcrossRenames() {
    let file = try PDFStorage.save(document: document)
    let originalStableID = file.stableID

    let renamed = try PDFStorage.rename(file: file, to: "New Name")
    XCTAssertEqual(renamed.stableID, originalStableID)
}

// SubscriptionManager tests
func testCachedSubscriptionState_ReturnsTrue_WhenExpirationInFuture() {
    let futureDate = Date().addingTimeInterval(3600)
    UserDefaults.standard.set(futureDate, forKey: "cachedExpirationDate")

    let manager = SubscriptionManager()
    XCTAssertTrue(manager.isSubscribed)
}

// FileManagementService tests
func testSaveScannedDocument_InsertsAtBeginning() async {
    let service = FileManagementService()
    let document = ScannedDocument(...)

    let file = try service.saveScannedDocument(document)
    XCTAssertEqual(service.files.first?.stableID, file.stableID)
}
```

### UI Tests

**Target:** `pdf-converterUITests/PDFConverterUITests.swift`

**Recommended Test Cases:**

```swift
func testTabSwitching() {
    let app = XCUIApplication()
    app.launch()

    app.tabBars.buttons["Tools"].tap()
    XCTAssertTrue(app.staticTexts["Convert to PDF"].exists)

    app.tabBars.buttons["Settings"].tap()
    XCTAssertTrue(app.switches["Require Biometrics"].exists)
}

func testScanFlow_RequiresSubscription() {
    let app = XCUIApplication()
    app.launchArguments = ["--no-subscription"]
    app.launch()

    app.buttons["Create"].tap()
    app.buttons["Scan Documents"].tap()

    // Mock scanner completion
    // ...

    app.buttons["Save"].tap()
    XCTAssertTrue(app.otherElements["Paywall"].exists)
}
```

### Integration Tests

**Recommended Areas:**

1. **Cloud Sync Flow:**
   - Save file → verify CloudKit upload
   - Delete local file → restore from CloudKit

2. **Subscription Flow:**
   - Mock StoreKit purchase
   - Verify subscription gates lift

3. **Conversion Flow:**
   - Mock PDF Gateway responses
   - Verify timeout handling

### Manual Testing Checklist

**Critical Paths:**

- [ ] Scan document → save → verify cloud backup
- [ ] Import PDF → rename → verify CloudKit update
- [ ] Convert web URL → share → verify temp cleanup
- [ ] Purchase subscription → verify all features unlock
- [ ] Restore purchases → verify state update
- [ ] Delete file → verify CloudKit deletion
- [ ] Create folder → move files → verify sync

**Edge Cases:**

- [ ] Airplane mode (cloud unavailable)
- [ ] iCloud sign-out
- [ ] Subscription expired
- [ ] PDF Gateway timeout
- [ ] File name with special characters
- [ ] Large PDF (100+ pages)
- [ ] Multiple rapid conversions

---

## Build Configuration & Dependencies

### Xcode Configuration

**Schemes:**
- `pdf-converter` - Main app target
- `pdf-converterTests` - Unit tests
- `pdf-converterUITests` - UI automation tests

**Build Commands:**
```bash
# Open in Xcode
xed .

# Build for simulator
xcodebuild -scheme pdf-converter \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build

# Run tests
xcodebuild test -scheme pdf-converter \
  -destination 'platform=iOS Simulator,name=iPhone 15'

# Locate app sandbox
xcrun simctl get_app_container booted com.roguewaveapps.pdf-converter data
```

### Swift Package Dependencies

**PostHog:**
```swift
// Package.swift (inferred)
dependencies: [
    .package(url: "https://github.com/PostHog/posthog-ios.git", from: "3.0.0")
]
```

### Apple Framework Dependencies

**System Frameworks:**
- SwiftUI
- StoreKit
- CloudKit
- PDFKit
- VisionKit
- PhotosUI
- PencilKit
- LocalAuthentication
- UIKit
- Foundation
- Combine (limited use)

### Info.plist Configuration

**Key Configurations:**

```xml
<key>CloudKitContainerIdentifier</key>
<string>iCloud.com.roguewaveapps.pdfconverter</string>

<key>PDFGatewayBaseURL</key>
<string>https://gotenberg-6a3w.onrender.com</string>

<key>SubscriptionProductID</key>
<string>com.roguewaveapps.pdfconverter.test.weekly.1</string>

<key>NSCameraUsageDescription</key>
<string>To scan documents and create PDFs</string>

<key>UIRequiredDeviceCapabilities</key>
<array>
    <string>armv7</string>
</array>

<key>UISupportedInterfaceOrientations</key>
<array>
    <string>UIInterfaceOrientationPortrait</string>
</array>
```

### Extension Points

**Bundle Extensions:**
```swift
extension Bundle {
    var subscriptionProductID: String {
        object(forInfoDictionaryKey: "SubscriptionProductID") as? String ?? ""
    }

    var pdfGatewayBaseURL: URL? {
        guard let urlString = object(forInfoDictionaryKey: "PDFGatewayBaseURL") as? String else {
            return nil
        }
        return URL(string: urlString)
    }
}
```

### Localization

**Localizable.xcstrings:**
- 162KB string catalog
- Comprehensive coverage (200+ strings)
- Ready for multi-language support

**Usage:**
```swift
NSLocalizedString("alert.scanFailed.title", comment: "Scan failed title")
```

---

## Conclusion

This technical architecture demonstrates a well-designed, production-ready iOS application built with modern Swift patterns:

**Strengths:**
- Clean separation of concerns (Coordinator, Service, Storage layers)
- Thread-safe concurrency (Actors, async/await)
- Robust error handling with user-friendly feedback
- Comprehensive analytics tracking
- Secure cloud synchronization
- Subscription-based monetization with proper gating

**Areas for Improvement:**
- Test coverage (minimal unit/UI tests currently)
- Some large files could be refactored (ContentView: 1,828 lines)
- Exponential backoff for API retries
- In-memory caching for stable IDs and thumbnails
- More granular error recovery strategies

The codebase shows clear evolution from a monolith (legacy ContentView) to a more modular architecture with coordinators and services. The recent refactoring maintains backward compatibility while improving maintainability.

This document provides comprehensive context for understanding how all components interact, data flows through the system, and how to extend or modify the application. For business context and feature descriptions, see the companion document **APP_OVERVIEW.md**.
