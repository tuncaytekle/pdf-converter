import SwiftUI

enum Tab: Hashable {
    case files, tools, settings, account
}

struct ContentView: View {
    @State private var selection: Tab = .files
    @State private var showCreate = false
    @State private var showCreateActions = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            // 1) Native TabView
            TabView(selection: $selection) {
                FilesView(
                    onScanDocuments: { scanDocumentsToPDF() },
                    onConvertFiles: { convertPhotosToPDF() }
                )
                .tabItem { Label("Files", systemImage: "doc") }
                .tag(Tab.files)

                ToolsView()
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
        // Present whatever flow you need
        .sheet(isPresented: $showCreate) {
            CreateSomethingView()
        }
        .confirmationDialog("", isPresented: $showCreateActions, titleVisibility: .hidden) {
            Button("📄 Scan Documents to PDF") { scanDocumentsToPDF() }
            Button("🖼️ Convert Photos to PDF") { convertPhotosToPDF() }
            Button("Cancel", role: .cancel) { }
        }
    }
    
    private func scanDocumentsToPDF() {
        // TODO: Implement document scanning to PDF
    }

    private func convertPhotosToPDF() {
        // TODO: Implement photo selection and PDF conversion
    }
}

// MARK: - FilesView (replaces HomeView)

struct FilesView: View {
    // Simple in-memory list for now; replace with your persistence later
    @State private var files: [PDFFile] = []

    // Callbacks provided by parent to trigger creation flows
    let onScanDocuments: () -> Void
    let onConvertFiles: () -> Void

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
                        Image(systemName: "chevron.right")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
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
                    Label("Scan", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onConvertFiles()
                } label: {
                    Label("Convert", systemImage: "doc.badge.plus")
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
private struct PDFFile: Identifiable {
    let id = UUID()
    let name: String
    let date: Date

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
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

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ToolCard.sample) { card in
                        Button(action: {}) {
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
}

extension ToolCard {
    static let sample: [ToolCard] = [
        .init(title: "Convert\nFiles to PDF",
              subtitle: "Convert Word, PowerPoint or\nExcel files to PDF",
              tint: Color(hex: 0x2F7F79),
              iconName: "infinity"),
        .init(title: "Scan\nDocuments",
              subtitle: "Scan multiple documents with\nyour camera",
              tint: Color(hex: 0xC02267),
              iconName: "camera"),
        .init(title: "Convert\nPhotos to PDF",
              subtitle: "Choose from your photo\nlibrary to create a new PDF",
              tint: Color(hex: 0x5C3A78),
              iconName: "photo.on.rectangle"),
        .init(title: "Import\nDocuments",
              subtitle: "Import PDF files from your\ndevice or web",
              tint: Color(hex: 0x6C8FC0),
              iconName: "arrow.down.to.line"),
        .init(title: "Convert\nWeb Page",
              subtitle: "Convert Web Pages to PDF\nusing a URL Link",
              tint: Color(hex: 0xBF7426),
              iconName: "link"),
        .init(title: "Edit\nDocuments",
              subtitle: "Sign, highlight, annotate\nexisting PDF files",
              tint: Color(hex: 0x7B3DD3),
              iconName: "pencil.and.outline")
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
