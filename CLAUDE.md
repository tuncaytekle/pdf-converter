# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build and Test Commands

**Development:**
- Open in Xcode: `xed .`
- Build: `xcodebuild -scheme pdf-converter -destination 'platform=iOS Simulator,name=iPhone 15' build`
- Run tests: `xcodebuild test -scheme pdf-converter -destination 'platform=iOS Simulator,name=iPhone 15'`
- Locate app sandbox for debugging: `xcrun simctl get_app_container booted com.roguewaveapps.pdf-converter data`

**Available schemes:** `pdf-converter`, `pdf-converterTests`, `pdf-converterUITests`

## Architecture Overview

This is a SwiftUI-based iOS PDF conversion and management app with a monolithic architecture centered around a 3400+ line `ContentView.swift` file. The app orchestrates multiple PDF workflows (scanning, converting, editing) through a floating tab-bar interface.

### Core Components

**Main Entry Point:**
- `PDFConverterApp.swift` - App entry point that injects Core Data via `PersistenceController.shared`
- `Persistence.swift` - Core Data stack wrapper (model name: "PDFConverter")

**Monolithic View Controller:**
- `ContentView.swift` (3400+ lines) - Contains all UI, state management, and business logic
  - Defines enums: `Tab` (files/tools/settings/account), `ToolAction` (conversion types), `ScanFlow` (camera/photos)
  - Embeds all child views: `FilesView`, `ToolsView`, `SettingsView`, `AccountView`, `ScanReviewSheet`, `PDFEditingView`, etc.
  - Manages state for: file list, modal presentations, biometric auth, rename/delete operations, CloudKit sync
  - Implements `PDFStorage` enum with static methods for file operations
  - Implements `PDFFile` struct (lightweight file metadata representation)

**External Services:**
- `CloudBackupManager.swift` - Actor-based CloudKit integration for PDF backup/restore
  - Uses private database with "PDFDocument" record type
  - Handles upload, deletion, and missing file restoration
  - Record naming via `CloudRecordNaming.recordName(for:)`
- `GotenbergError.swift` - HTTP client for Gotenberg PDF conversion API
  - `GotenbergClient` class with retry logic, authentication support
  - Converts HTML, URLs, and Office documents to PDF
  - Multipart form-data uploads with exponential backoff retry

### Data Flow

1. **File Loading:** `loadInitialFiles()` calls `PDFStorage.loadSavedFiles()` which scans Documents directory for PDFs
2. **Scanning:** User triggers `activeScanFlow` → `DocumentScannerView` or `PhotoPickerView` → `ScanReviewSheet` → saves via `PDFStorage.save(document:)`
3. **Cloud Sync:** After save, triggers `CloudBackupManager.backup(file:)` which uploads to CloudKit private DB
4. **Conversion:** `GotenbergClient.convertURLToPDF()` or similar methods send requests to remote Gotenberg instance
5. **Editing:** `PDFEditingView` provides signature and annotation tools using PencilKit, signature persistence via `SignatureStore` in UserDefaults

### Key Design Patterns

- **Monolithic view architecture:** All business logic and UI nested within `ContentView`
- **File-based storage:** PDFs stored in app Documents directory, metadata derived from file system
- **Actor-based cloud sync:** `CloudBackupManager` is an actor for thread-safe CloudKit operations
- **State-driven modals:** SwiftUI sheets bound to optional `@State` properties (e.g., `previewFile`, `pendingDocument`, `editingContext`)
- **Enum-based static utilities:** `PDFStorage` uses static methods for all file I/O

## Code Organization

The app structure is intentionally flat—most functionality resides in `ContentView.swift`:

```
pdf-converter/
├── PDFConverterApp.swift          # App entry, Core Data injection
├── ContentView.swift              # Main UI + all child views (3400 lines)
├── Persistence.swift              # Core Data controller
├── CloudBackupManager.swift       # CloudKit backup actor
├── GotenbergError.swift           # HTTP client for PDF conversion
└── Assets.xcassets                # Images, colors, icons
```

**When adding features:**
- New views are typically embedded within `ContentView.swift` as child structs
- File operations go in the `PDFStorage` enum (line ~3015)
- Cloud operations extend `CloudBackupManager` actor
- External API changes modify `GotenbergClient`

## Coding Conventions

- Four-space indentation, `PascalCase` types, `camelCase` properties
- Enum cases in lower camel case (matching `Tab`, `ToolAction`)
- Extract helpers into extensions when views exceed ~300 lines (though `ContentView` violates this)
- Prefer SwiftUI composition, though current architecture centralizes most logic
- Type erasure and dependency injection at view boundaries

## Testing

- Unit tests: `pdf-converterTests/PDFConverterTests.swift` - use format `testScenario_expectedResult`
- UI tests: `pdf-converterUITests/PDFConverterUITests.swift` - cover scanning, tab switching, biometrics
- Launch arguments stub hardware access for UI testing
- Run `xcodebuild test` before opening PRs

## Key Integration Points

**VisionKit:** Document scanning via `VNDocumentCameraViewController` wrapped in `DocumentScannerView`

**PhotosUI:** Photo picker via `PHPickerViewController` wrapped in `PhotoPickerView`

**PDFKit:** PDF rendering, page manipulation, metadata extraction

**LocalAuthentication:** Biometric auth for file preview (controlled by `requireBiometrics` SceneStorage)

**PencilKit:** Signature drawing and PDF annotation via `PKCanvasView`

**StoreKit:** In-app purchase integration (StoreKit configuration file present)

**CloudKit:** Private database sync via `CloudBackupManager`
- Container ID read from `Info.plist` key `CloudKitContainerIdentifier`
- Record type: "PDFDocument" with fields: fileName, displayName, modifiedAt, fileSize, pageCount, fileAsset

**Gotenberg API:** External conversion service at `https://gotenberg-6a3w.onrender.com`
- Converts HTML, URLs, Office docs to PDF
- 120s timeout, 2-retry policy with exponential backoff

## Localization

Localization strings in `Localizable.xcstrings` (43KB, staged for commit). Use `NSLocalizedString` throughout the codebase.

## Security

- Biometric authentication gates file preview when `requireBiometrics` enabled
- Entitlements managed through Xcode (do not manually edit)
- Never commit sample data or simulator containers
- CloudKit credentials managed by system

## Commit Guidelines

- Imperative subjects under 72 characters (e.g., "Simplify signature placement")
- Bundle one logical change per commit
- Include screenshots/recordings for UI changes
- Rebase on `main` before requesting review
