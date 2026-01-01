import SwiftUI
import Foundation

enum FileSortType {
    case date, name
}

enum SortDirection {
    case ascending, descending
}

struct FilesView: View {
    @Binding var files: [PDFFile]
    @Binding var folders: [PDFFolder]
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var sortType: FileSortType = .date
    @State private var sortDirection: SortDirection = .descending
    @State private var currentFolderId: String?
    @State private var showCreateFolderDialog = false
    @State private var newFolderName = ""
    @State private var moveFileToFolder: PDFFile?
    @State private var showRenameFolderDialog = false
    @State private var renameFolderTarget: PDFFolder?
    @State private var renameFolderName = ""
    @StateObject private var contentIndexer = FileContentIndexer()
    @EnvironmentObject private var subscriptionManager: SubscriptionManager
    @EnvironmentObject private var cloudSyncStatus: CloudSyncStatus

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
                .onDisappear {
                    contentIndexer.cancelPendingWork()
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
                Section { searchBar }
                    .textCase(nil)
                    .listRowBackground(Color.clear)

                Section { sortingToolbar }
                    .textCase(nil)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 8, trailing: 0))

                if currentFolderId == nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ForEach(folders) { folder in
                        folderRow(for: folder)
                    }
                }

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
                HStack(spacing: 6) {
                    Text(file.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    // Cloud sync indicator
                    cloudSyncIndicator(for: file)
                }

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
                Button { onPreview(file) } label: {
                    Label(NSLocalizedString("action.preview", comment: "Preview action"), systemImage: "eye.fill")
                }

                Button { onShare(file) } label: {
                    Label(NSLocalizedString("action.share", comment: "Share action"), systemImage: "square.and.arrow.up")
                }

                Button { onRename(file) } label: {
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
        .task {
            contentIndexer.ensureTextIndex(for: file)
        }
    }

    @ViewBuilder
    private func cloudSyncIndicator(for file: PDFFile) -> some View {
        if let status = cloudSyncStatus.getFileStatus(file.url) {
            switch status {
            case .synced:
                Image(systemName: "checkmark.icloud.fill")
                    .font(.caption)
                    .foregroundColor(.green)
                    .accessibilityLabel(NSLocalizedString("Synced to iCloud", comment: "File synced status"))

            case .syncing:
                ProgressView()
                    .scaleEffect(0.7)
                    .accessibilityLabel(NSLocalizedString("Syncing to iCloud", comment: "File syncing status"))

            case .failed(let error):
                Button(action: {
                    // Retry sync for this file
                    Task {
                        await cloudBackup.backup(file: file, syncStatus: cloudSyncStatus)
                    }
                }) {
                    Image(systemName: "exclamationmark.icloud.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Sync failed, tap to retry", comment: "File sync failed status"))
                .help(error)
            }
        }
    }

    private var filteredFiles: [PDFFile] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let isSearching = !trimmed.isEmpty

        let folderFiltered: [PDFFile]
        if isSearching {
            folderFiltered = files
        } else {
            folderFiltered = files.filter { $0.folderId == currentFolderId }
        }

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
                return false
            }
        }

        return filtered.sorted { file1, file2 in
            switch sortType {
            case .date:
                return sortDirection == .ascending ? file1.date < file2.date : file1.date > file2.date
            case .name:
                return sortDirection == .ascending ? file1.name < file2.name : file1.name > file2.name
            }
        }
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
        PDFStorage.updateFileFolderId(file: file, folderId: folderId)

        let updatedFile = PDFFile(
            url: file.url,
            name: file.name,
            date: file.date,
            pageCount: file.pageCount,
            fileSize: file.fileSize,
            folderId: folderId,
            stableID: file.stableID  // Preserve stable ID
        )

        withAnimation(.easeInOut(duration: 0.3)) {
            files.removeAll(where: { $0.id == file.id })
            files.append(updatedFile)
        }

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

        if let index = folders.firstIndex(where: { $0.id == folder.id }) {
            let updatedFolder = PDFFolder(id: folder.id, name: trimmedName)
            folders[index] = updatedFolder
            PDFStorage.saveFolders(folders)

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
            HStack(spacing: 8) {
                Menu {
                    Button { sortType = .date } label: {
                        Label(NSLocalizedString("sort.date", comment: "Sort by date"), systemImage: sortType == .date ? "checkmark" : "")
                    }
                    Button { sortType = .name } label: {
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

private struct EmptyFilesView: View {
    var body: some View {
        VStack(spacing: 20) {
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

struct PDFFile: Identifiable, Equatable {
    let url: URL
    var name: String
    let date: Date
    let pageCount: Int
    let fileSize: Int64
    var folderId: String?
    let stableID: String  // Stable UUID for CloudKit record identity

    var id: String { stableID } // Stable identity across renames/moves.

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
        lhs.stableID == rhs.stableID
    }
}
