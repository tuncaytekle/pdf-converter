# PDF Converter - App Overview

## Executive Summary

**PDF Converter** is a premium iOS mobile application that provides comprehensive PDF creation, conversion, management, and editing capabilities with cloud synchronization. It follows a subscription-based monetization model ($9.99/week with a 7-day trial at $0.49) and targets users who need reliable PDF workflow tools on mobile devices.

**Bundle ID:** `com.roguewaveapps.pdfconverter`
**Platform:** iOS (Portrait-only)
**Architecture:** SwiftUI + MVVM + Coordinator Pattern
**Primary Tech Stack:** SwiftUI, StoreKit 2, CloudKit, PDFKit, VisionKit, PostHog Analytics

---

## Core Value Proposition

The app solves the problem of creating, converting, organizing, and editing PDFs on iOS without needing a desktop computer or multiple apps. It combines several PDF workflows into a single, cohesive experience:

1. **Document Scanning** - Convert physical documents to PDFs using device camera
2. **Photo-to-PDF Conversion** - Turn photos from library into PDF documents
3. **Web-to-PDF** - Convert web pages to PDF format
4. **Office Document Conversion** - Convert Word, Excel, PowerPoint, and eBook files to PDF
5. **PDF Management** - Organize PDFs in folders with search, sort, and cloud backup
6. **PDF Editing** - Add signatures, highlights, and annotations to existing PDFs

---

## User Journey

### First-Time User Experience

1. **App Launch** → 3-screen onboarding flow highlighting key features
2. **Paywall Presentation** → Subscription offer with 7-day trial ($0.49) shown immediately after onboarding
3. **Main Interface** → Tab-based interface with floating create button

### Typical Workflow

1. **Content Capture/Import**
   - Tap floating create button (with pulsing animation to draw attention)
   - Choose source: Document Camera, Photo Library, Import PDF, Web URL, or Office File
   - Capture/select content

2. **Review & Save**
   - Preview generated PDF in review sheet
   - Edit filename
   - **Gate: Requires subscription** to save or share
   - Save to library or share directly

3. **Organization**
   - View all PDFs in Files tab (sortable by date/name)
   - Create folders via drag-and-drop
   - Search by filename or document content (OCR indexing)
   - Automatic cloud backup to iCloud

4. **Editing** (Premium)
   - Select PDF from library
   - Add signatures via PencilKit drawing
   - Place signature stamps with drag-to-position
   - Add highlights and annotations
   - Save changes (requires subscription)

---

## Monetization Model

### Subscription Details

**Product:** Weekly auto-renewable subscription
**Price:** $9.99/week
**Trial:** 7-day trial for $0.49 (introductory offer)
**Platform:** StoreKit 2 with modern async/await API
**Product ID:** `com.roguewaveapps.pdfconverter.test.weekly.1`

### Free vs Premium Features

**Free (No Subscription Required):**
- View existing PDFs in library
- Browse files and folders
- Use document scanner/photo picker (but cannot save)
- Preview PDFs
- Access settings

**Premium (Subscription Required):**
- Save scanned documents to library
- Share PDFs via system share sheet
- Edit PDFs (signatures, annotations, highlights)
- Unlimited document conversions (web, office files)
- Cloud backup and sync via iCloud
- Organize files in folders

### Paywall Strategy

1. **Onboarding Paywall** - First launch after completing onboarding (100% impressions)
2. **Launch Paywall** - Shown on app launch if user has never purchased
3. **Feature Gates** - Inline blocking when trying to save, share, or edit without subscription

The paywall features an animated toggle that transitions to full paywall content, creating a smooth, engaging purchase experience. It includes:
- Visual toggle animation (7-day trial enabled)
- Feature highlights with tags
- Social proof ("1 Converter App", 5-star rating)
- Transparent pricing with introductory offer clearly displayed
- Restore purchases functionality

---

## Design Philosophy & User Experience

### Design Principles

1. **Simplicity Over Complexity**
   - Single-tap workflows where possible
   - Minimal navigation depth (max 2 levels)
   - Clear visual hierarchy

2. **Instant Feedback**
   - Progress indicators for long operations (conversions)
   - Cloud sync status per file (checkmark/spinner/warning)
   - Success/error alerts with actionable messages

3. **Non-Destructive Operations**
   - All edits create new versions (for PDF editing)
   - Clear confirmation dialogs for delete operations
   - Temporary files cleaned up after cancel/dismiss

4. **Accessibility First**
   - VoiceOver labels throughout
   - Dynamic Type support
   - Reduce Motion support (disables animations)
   - Keyboard navigation support

### Visual Design Language

- **Color Scheme:** Light mode (white background with accent blue #007AFF)
- **Typography:** San Francisco system font with semantic sizing
- **Layout:** Floating tab bar at bottom, large tappable areas
- **Animations:** Subtle transitions, pulsing create button, smooth sheet presentations

### Onboarding Flow

**3-Screen Progressive Disclosure:**
1. Welcome screen with app icon and brand
2. Feature showcase (scan, convert, organize, share)
3. Trial benefits highlighting value proposition

**Post-Onboarding:**
- Paywall presentation (subscription offer)
- Smart rating prompts based on usage milestones

---

## Core Features Deep Dive

### 1. Document Scanning (VisionKit)

**Technology:** Apple's VisionKit framework with `VNDocumentCameraViewController`

**Workflow:**
- User taps "Scan Documents" from create menu
- Native iOS document scanner opens
- Auto-detects document edges, suggests retakes
- Processes multiple pages in single session
- Generates PDF with all scanned pages
- Shows review sheet with rename/save/share options

**UX Details:**
- Fallback if VisionKit unavailable (older devices)
- Cleanup of temporary files after save/dismiss
- Page count displayed in review

### 2. Photo-to-PDF Conversion

**Technology:** PhotosUI framework with `PHPickerViewController`

**Workflow:**
- Multi-select photos from library
- Converts images to PDF pages (maintains order)
- Each photo becomes a page
- Automatic compression for file size optimization

**UX Details:**
- No photo permissions required (picker runs in separate process)
- Preview before save
- Automatic filename with timestamp

### 3. Web-to-PDF Conversion

**Technology:** External Gotenberg API service via custom HTTP client

**Service:** `https://gotenberg-6a3w.onrender.com`

**Workflow:**
1. User enters URL in prompt dialog
2. URL normalization (adds https:// if missing)
3. Job creation via `/v1/jobs` API endpoint
4. Conversion status polling (1-second intervals)
5. Download converted PDF from signed S3 URL
6. Present in review sheet

**Technical Details:**
- 120-second timeout with retry logic
- Progress phases: converting → downloading
- Idle timer disabled during conversion (prevents screen lock)
- Cancellation support (Task cancellation)

**UX Details:**
- Smart URL parsing (accepts "google.com" or "https://google.com")
- Loading indicator with progress text
- Error messages for timeout/failure
- Automatic filename from domain name

### 4. Office Document Conversion

**Technology:** External Gotenberg API with LibreOffice/Calibre backends

**Supported Formats:**
- **LibreOffice:** .docx, .xlsx, .pptx, .doc, .xls, .ppt, .odt, .ods, .odp
- **Calibre:** .epub, .mobi, .azw, .azw3

**Workflow:**
1. User selects file via system file picker
2. File extension determines conversion backend
3. Upload to signed S3 URL (PUT request)
4. Job submission to gateway
5. Polling for completion
6. Download result

**Technical Details:**
- Security-scoped file access (required for Files app integration)
- Multipart upload with progress tracking
- Automatic retry on transient failures
- 120-second conversion timeout

### 5. PDF Library Management

**Storage:** File-based in app's Documents directory

**Metadata Files:**
- `.file_stable_ids.json` - UUID mapping for CloudKit sync
- `.file_folders.json` - File-to-folder relationships
- `.folders.json` - Folder definitions

**Features:**
- **Stable IDs:** Each file gets a UUID that persists across renames
- **Folders:** Drag-and-drop file organization
- **Search:** Full-text search via OCR content indexing
- **Sorting:** By date or name (ascending/descending)
- **Thumbnails:** Cached PDF page previews
- **Metadata:** Page count, file size, modification date

**Performance Optimizations:**
- Lazy loading of page counts (background actor)
- Thumbnail generation with caching
- Text indexing on-demand
- Fast initial file list (metadata read without PDF parsing)

### 6. Cloud Backup & Sync (iCloud)

**Technology:** CloudKit private database with actor-based concurrency

**Sync Strategy:**
- Automatic background upload after file save
- UUID-based record names (survives renames)
- Missing file restoration on app launch
- Per-file sync status tracking
- Folder sync support

**CloudKit Schema:**

**PDFDocument Record:**
```
recordName: UUID (stable ID)
fileName: String
displayName: String
modifiedAt: Date
fileSize: Int64
pageCount: Int
fileAsset: CKAsset (binary PDF)
folderId: String?
```

**PDFFolder Record:**
```
recordName: UUID
name: String
createdDate: Date
```

**Sync Status Indicators:**
- Green checkmark: Successfully synced
- Progress spinner: Syncing in progress
- Orange exclamation: Failed (tap to retry)
- Gray: iCloud unavailable

**Error Handling:**
- Account status caching
- Graceful degradation when iCloud unavailable
- Retry logic for transient failures
- Diagnostic logging (DEBUG builds)

### 7. PDF Editing

**Technology:** PDFKit + PencilKit

**Capabilities:**
- Signature placement (drag & resize)
- Text highlighting (color selection)
- Annotation tools (PencilKit canvas)
- Non-destructive editing (file replacement on save)

**Signature Management:**
- Draw signature once via PencilKit
- Store in UserDefaults as `PKDrawing`
- Reuse across multiple PDFs
- Convert to PDFAnnotation stamp
- Drag-to-position with SwiftUI gestures

**Editing Workflow:**
1. Select PDF from library
2. Editor opens with PDF view
3. Choose tool (signature, highlight, annotate)
4. Apply changes to document
5. **Subscription gate on save**
6. File replaced with edited version

---

## Navigation & Information Architecture

### Tab Structure

**4 Primary Tabs (Bottom Navigation):**

1. **Files** - PDF library with grid/list view
   - Search bar
   - Sort controls
   - Folder navigation
   - File cards with thumbnails
   - Cloud sync status

2. **Tools** - Quick access to conversion tools
   - Scan Documents (camera icon)
   - Convert Photos (photo icon)
   - Convert Files (document icon)
   - Import PDFs (folder icon)
   - Convert Web Page (globe icon)
   - Edit Documents (pencil icon)

3. **Settings** - App configuration
   - Biometric authentication toggle
   - FAQ access
   - App version info
   - Support links

4. **Account** - Subscription management
   - Subscription status badge
   - Manage subscription (iOS system sheet)
   - Restore purchases
   - Pro badge if subscribed

**Floating Create Button:**
- Positioned bottom-center (overlays tab bar)
- Pulsing animation on first use (visual cue)
- Opens quick actions menu (6 tool options)
- Dismisses on outside tap

### Modal Presentation Patterns

**Sheets (Swipe-to-Dismiss):**
- Document scanner (VisionKit)
- Photo picker (PhotosUI)
- Review sheet (after scan/conversion)
- PDF preview
- Rename dialog
- Edit selector
- PDF editor
- Web URL prompt
- Share sheet
- Paywall

**Alerts (Blocking Dialogs):**
- Delete confirmations
- Error messages
- Success notifications
- Rating prompts

**Confirmation Dialogs:**
- File deletion
- Folder deletion with file count

---

## Analytics & User Insights

### PostHog Integration

**Tracking Strategy:**
- Session replay enabled (with masking for privacy)
- Element interactions captured automatically
- Manual screen view tracking
- Custom event properties for context

**Key Events Tracked:**

**Screen Views:**
- Files tab
- Tools tab
- Settings tab
- Account tab
- Paywall
- PDF Editor
- Scan Review

**Feature Usage:**
- Create button tapped (floating button)
- Tool card tapped (which tool)
- PDF file tapped
- Folder created/renamed/deleted
- Search performed
- Sort changed

**Subscription Events:**
- Paywall viewed (with source attribution)
- Purchase attempted
- Purchase succeeded/failed
- Restore purchases attempted
- Pro button tapped (source context)

**Conversion Funnel:**
- Scan started
- Scan completed
- Review sheet shown
- PDF saved/shared
- Paywall shown (if gated)
- Purchase completed

**Attribution:**
- Anonymous ID stored in Keychain
- Used as StoreKit `appAccountToken` for user tracking
- Apple Search Ads attribution token uploaded

### Rating Prompt Strategy

**RatingPromptManager Triggers:**
1. First conversion completed (celebrates success)
2. Second app open (early engagement)
3. After subscription purchase (positive moment)
4. Recurring prompts (time-based intervals)

**Two-Step Flow:**
1. Enjoyment question ("Are you enjoying the app?")
   - Yes → System rating prompt (StoreKit)
   - No → Feedback prompt (help improve)
2. Rate app / Provide feedback

**Timing Logic:**
- Minimum intervals between prompts
- No more than 3 times per version
- Respect user choice (don't re-ask immediately)

---

## Technical Requirements & Constraints

### iOS Version Support

- **Minimum:** iOS 16.0 (for SwiftUI Observation, StoreKit 2)
- **Target:** iOS 17.0+ (for newer API features)
- **Architecture:** Modern Swift with async/await, actors, Observation macro

### Device Support

- **Orientation:** Portrait only (locked via AppDelegate)
- **Devices:** iPhone (universal layout with adaptive metrics)
- **Accessibility:** VoiceOver, Dynamic Type, Reduce Motion

### Network Dependencies

**Critical:**
- StoreKit App Store connectivity (subscriptions)
- CloudKit iCloud connectivity (optional but recommended)

**Optional:**
- PDF Gateway API for conversions (fallback: disable conversion tools)

### Storage Requirements

- PDF files stored in Documents directory (user-accessible via Files app)
- Hidden metadata files (JSON) for mappings
- Signature data in UserDefaults (small)
- CloudKit backup storage (user's iCloud quota)

### Performance Targets

- Initial file list load: <500ms (lazy page count loading)
- Thumbnail generation: <200ms per thumbnail (cached)
- Cloud sync: Background, non-blocking
- Conversion timeout: 120 seconds max

---

## Security & Privacy

### Data Protection

**Local Storage:**
- Files in app Documents directory (encrypted at rest by iOS)
- Biometric authentication option for file preview (Face ID/Touch ID)
- Signatures stored locally (not uploaded)

**Cloud Storage:**
- CloudKit private database (user's iCloud account)
- End-to-end encryption via Apple's infrastructure
- No third-party cloud services

**Network Security:**
- HTTPS for all API calls
- Signed S3 URLs for file uploads (temporary credentials)
- No persistent user accounts or passwords

### Privacy Considerations

**Data Collection:**
- PostHog analytics with session replay (text/image masking enabled)
- Anonymous ID in Keychain (no PII)
- Apple Search Ads attribution (opt-in by user)

**Permissions:**
- Camera (document scanning)
- Photo Library (via PHPicker, no persistent access)
- iCloud (automatic if signed in)
- No location, contacts, or other sensitive permissions

**Compliance:**
- Privacy Policy linked in paywall and settings
- Standard Apple EULA for subscriptions
- No GDPR/CCPA-specific flows (no user accounts)

---

## Failure Modes & Error Handling

### Graceful Degradation

**iCloud Unavailable:**
- App functions normally
- Local storage only
- Sync status shows "iCloud unavailable" message
- No blocking errors

**PDF Gateway Unreachable:**
- Conversion tools disabled
- Clear error messages explaining service unavailable
- Core features (scan, import, manage) still work

**StoreKit Issues:**
- Paywall shows loading state
- Error messages with diagnostics
- Restore purchases as fallback
- Subscription status cached between launches

### User-Facing Error Messages

**Principles:**
1. Clear, non-technical language
2. Actionable next steps
3. Context-specific help
4. No silent failures

**Examples:**
- "Unable to scan document. Please try again."
- "Conversion timed out. Please check your internet connection."
- "Failed to save to iCloud. Files are saved locally."
- "Subscription not available. Please try again later."

### Developer Error Logging

**OSLog Framework:**
- Subsystem-based logging (Storage, Subscription, Conversion)
- Debug vs Release builds (verbose vs minimal)
- CloudKit diagnostic logging (#if DEBUG)

---

## Future Expansion Opportunities

### Potential Features

1. **OCR Text Extraction** - Extract text from scanned PDFs
2. **Batch Operations** - Multi-select delete, move, share
3. **Templates** - Pre-designed PDF templates (invoices, forms)
4. **Page Manipulation** - Reorder, extract, merge PDFs
5. **Compression** - Reduce PDF file sizes
6. **Password Protection** - Encrypt PDFs with passwords
7. **Export Formats** - Convert PDFs to images, Word, Excel

### Monetization Extensions

1. **Lifetime Purchase** - One-time unlock option
2. **Team/Family Plans** - Multi-user subscriptions
3. **Document Templates** - Premium template marketplace
4. **Business Features** - Company branding, bulk operations

### Platform Extensions

1. **iPad Optimization** - Multi-column layout, drag-and-drop
2. **Mac Catalyst** - Desktop version with keyboard shortcuts
3. **Share Extension** - Convert from Safari, Photos
4. **Widget** - Quick access to recent files, scan button

---

## Competitive Positioning

### Key Differentiators

1. **Native iOS Experience** - Built with SwiftUI, feels like Apple app
2. **All-in-One Solution** - Scanning + conversion + management + editing
3. **iCloud Integration** - Seamless sync across devices
4. **Offline Capable** - Core features work without internet
5. **No User Accounts** - Privacy-focused, no registration required

### Market Comparison

**vs Scanner Apps (Scanbot, Adobe Scan):**
- More comprehensive (editing, conversions)
- Better file management

**vs PDF Editors (PDFelement, PDF Expert):**
- Simpler, more focused
- Better scanning workflow

**vs Cloud Storage (Dropbox, Google Drive):**
- PDF-specific features
- No storage limits (local + iCloud)
- Offline editing

---

## Success Metrics

### Key Performance Indicators (KPIs)

**Acquisition:**
- App Store impressions → installs
- Install → onboarding completion rate

**Activation:**
- First document created (conversion funnel)
- Time to first save

**Retention:**
- Day 1, 7, 30 retention rates
- Weekly active users (WAU)

**Revenue:**
- Trial start rate (paywall → subscription)
- Trial → paid conversion rate
- Average revenue per user (ARPU)
- Churn rate (weekly subscription)

**Engagement:**
- Documents created per user
- Feature adoption (which tools used)
- Cloud sync usage (% of users)

### North Star Metric

**Documents Saved per Week** - Indicates both product value and subscription necessity, correlates with revenue.

---

## Conclusion

PDF Converter is a well-architected iOS app that combines multiple PDF workflows into a cohesive, subscription-based product. Its strength lies in its native iOS integration (VisionKit, CloudKit, StoreKit), thoughtful UX (subscription gates, onboarding, rating prompts), and clean codebase architecture (Coordinator pattern, service layer, SwiftUI best practices).

The app demonstrates production-ready quality with comprehensive error handling, analytics tracking, accessibility support, and graceful degradation when services are unavailable. Its subscription model is clearly gated with a compelling paywall that converts users after experiencing core value (document scanning).

This overview provides context for understanding the app's purpose, user journey, and business model. For technical implementation details, see the companion document **TECHNICAL_ARCHITECTURE.md**.
