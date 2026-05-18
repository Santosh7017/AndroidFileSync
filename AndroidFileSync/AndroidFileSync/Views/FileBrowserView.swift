//
//  FileBrowserView.swift
//  AndroidFileSync
//

import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View, Equatable {
    let files: [UnifiedFile]
    let currentPath: String
    let isLoading: Bool
    let canGoBack: Bool
    @Binding var selectedFiles: Set<UUID>
    let onNavigate: (String) -> Void
    let onGoBack: () -> Void
    let onDownload: (UnifiedFile) -> Void
    let onUpload: ([URL]) -> Void
    let onDelete: ((UnifiedFile) -> Void)?
    let onRename: ((UnifiedFile, String) -> Void)?
    var onPreview: ((UnifiedFile) -> Void)? = nil
    let onBatchDelete: (() -> Void)?
    let onBatchDownload: (() -> Void)?
    let onBatchChangeExtension: ((String) -> Void)?
    var onCopy: (([UnifiedFile]) -> Void)? = nil
    var onCut: (([UnifiedFile]) -> Void)? = nil
    var onDownloadFolder: ((UnifiedFile) -> Void)? = nil
    /// Called when the user chooses "Add to Sidebar" from the folder context menu
    var onAddToSidebar: ((UnifiedFile) -> Void)? = nil
    /// Called when the user chooses "Delete Permanently" from the selection toolbar
    var onPermanentDelete: (() -> Void)? = nil
    
    // Sorting support
    var sortOption: ActionToolbar.SortOption = .name
    var onSortChange: ((ActionToolbar.SortOption, Bool) -> Void)? = nil
    
    // Equatable implementation - only compare data that affects rendering
    static func == (lhs: FileBrowserView, rhs: FileBrowserView) -> Bool {
        lhs.files.map(\.id) == rhs.files.map(\.id) &&
        lhs.currentPath == rhs.currentPath &&
        lhs.isLoading == rhs.isLoading &&
        lhs.canGoBack == rhs.canGoBack &&
        lhs.selectedFiles == rhs.selectedFiles &&
        lhs.sortOption == rhs.sortOption
    }
    
    // Table sort state
    @State private var sortOrder: [KeyPathComparator<UnifiedFile>] = [
        .init(\.name, order: .forward)
    ]
    
    // FIX 1: Bring back the state variable for UI feedback
    @State private var isDraggingOver = false
    
    // Delete confirmation state
    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: UnifiedFile? = nil
    @State private var showBatchDeleteConfirmation = false
    @State private var batchDeleteCount = 0

    // Change extension state (for context menu)
    @State private var showExtensionDialog = false
    @State private var newExtension = ""
    
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            fileListOrEmptyState
            
            // Selection toolbar - only show when there are selected files in current view
            let selectedFilesList = files.filter { selectedFiles.contains($0.id) }
            if !selectedFilesList.isEmpty {
                SelectionToolbar(
                    selectedFiles: selectedFilesList,
                    onClearSelection: { selectedFiles.removeAll() },
                    onDelete: { onBatchDelete?() },
                    onDownload: { onBatchDownload?() },
                    onRename: onRename,
                    onChangeExtension: onBatchChangeExtension,
                    onPermanentDelete: onPermanentDelete
                )
            }
        }
        .alert("Move \(fileToDelete?.name ?? "item") to Trash?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                fileToDelete = nil
            }
            Button("Move to Trash", role: .destructive) {
                if let file = fileToDelete {
                    onDelete?(file)
                }
                fileToDelete = nil
            }
        } message: {
            Text("You can restore this item from the Trash.")
        }
        // Change extension alert (no pre-fill needed, so SwiftUI alert works fine here)
        .alert("Change Extension", isPresented: $showExtensionDialog) {
            TextField("New Extension", text: $newExtension)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                newExtension = ""
            }
            Button("Change") {
                if !newExtension.isEmpty {
                    onBatchChangeExtension?(newExtension)
                }
                newExtension = ""
            }
        } message: {
            Text("Enter new extension (e.g. txt, jpg) for \(selectedFiles.count) files.")
        }
        // Batch delete confirmation alert
        .alert("Move \(batchDeleteCount) items to Trash?", isPresented: $showBatchDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                batchDeleteCount = 0
            }
            Button("Move to Trash", role: .destructive) {
                onBatchDelete?()
                batchDeleteCount = 0
            }
        } message: {
            Text("You can restore these items from the Trash.")
        }
    }
    
    // MARK: - View Components
    
    private var pathBar: some View {
        HStack(spacing: 0) {
            // Back button
            if canGoBack {
                Button(action: onGoBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Go back")
            }
            
            // Breadcrumb path
            breadcrumbPath
            
            Spacer()
            
            // Item count
            if isLoading {
                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
            } else {
                Text(files.count == 1 ? "1 item" : "\(files.count) items")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            
            Divider().frame(height: 16).padding(.horizontal, 10)
            
            // Upload button — accent-tinted, non-intrusive Apple style
            Button(action: showUploadDialog) {
                Label("Upload", systemImage: "arrow.up.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.accentColor)
            .help("Upload files to this folder")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    
    // Breadcrumb segments built from current path
    private var breadcrumbPath: some View {
        let segments = currentPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        
        return HStack(spacing: 2) {
            Text("/")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                Text(segment)
                    .font(.system(size: 14, weight: index == segments.count - 1 ? .medium : .regular))
                    .foregroundColor(index == segments.count - 1 ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: 16, height: 16)
        } else {
            Text("\(files.count) items")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var fileListOrEmptyState: some View {
        ZStack {
            if files.isEmpty && !isLoading {
                emptyFolderView
            } else {
                fileList
            }
            
            if isDraggingOver {
                dropOverlay
            }
        }
        // FIX 2: Use the standard .onDrop with proper URL extraction
        .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    do {
                        // Try loading as Data first (most common case)
                        if let data = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                        // Fallback: try loading as URL directly
                        else if let url = try await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                            urls.append(url)
                        }
                    } catch {
                        print("⚠️ Failed to load dropped item: \(error)")
                    }
                }
                
                if !urls.isEmpty {
                    await MainActor.run {
                        onUpload(urls)
                    }
                }
            }
            return true
        }
        .background(
            Group {
                Button("") { handleDeleteShortcut() }.keyboardShortcut(.delete, modifiers: .command)
                Button("") { handleDeleteShortcut() }.keyboardShortcut(.delete, modifiers: [])
            }.hidden()
        )
    }
    
    private func handleDeleteShortcut() {
        let items = files.filter { selectedFiles.contains($0.id) }
        guard !items.isEmpty else { return }
        
        if items.count == 1 {
            fileToDelete = items.first
            showDeleteConfirmation = true
        } else {
            batchDeleteCount = items.count
            showBatchDeleteConfirmation = true
        }
    }
    
    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            Text(isDraggingOver ? "Drop files to upload" : "Folder is empty")
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            if !isDraggingOver {
                Text("Drag files here or click the Upload button")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private var fileList: some View {
        Table(files, selection: $selectedFiles, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 8) {
                    Image(systemName: getFileIcon(for: file))
                        .foregroundColor(getFileColor(for: file))
                        .frame(width: 18)
                    Text(file.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            TableColumn("Size", value: \.size) { file in
                Text(file.isDirectory ? "--" : formatBytes(file.size))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 70, ideal: 90, max: 110)
            
            TableColumn("Date", value: \.sortableDate) { file in
                Text(file.modificationDate != nil ? Self.dateFormatter.string(from: file.modificationDate!) : "--")
                    .font(.system(.callout, design: .default))
                    .foregroundColor(.secondary)
            }
            .width(min: 160, ideal: 170, max: 200)
            
            TableColumn("Type", value: \.sortableType) { file in
                Text(file.isDirectory ? "Folder" : getFileType(for: file))
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            // No .width() — fills remaining space, eliminates trailing column separator
        }
        .tableStyle(.inset)
        .scrollContentBackground(.hidden)
        .onChange(of: sortOrder) { newOrder in
            guard let first = newOrder.first else { return }
            let ascending = first.order == .forward
            if first.keyPath == \UnifiedFile.name { onSortChange?(.name, ascending) }
            else if first.keyPath == \UnifiedFile.size { onSortChange?(.size, ascending) }
            else if first.keyPath == \UnifiedFile.sortableDate { onSortChange?(.date, ascending) }
            else if first.keyPath == \UnifiedFile.sortableType { onSortChange?(.type, ascending) }
        }
        // Use contextMenu with primaryAction for double-click - this is the macOS-native approach
                // that works with selection (macOS 13+)
                .contextMenu(forSelectionType: UUID.self, menu: { selectedIds in
                    // Context menu for selected items
                    let selectedItems = files.filter { selectedIds.contains($0.id) }
                    let isSingleSelection = selectedIds.count <= 1
                    let hasOnlyFiles = !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }
                    
                    if let firstItem = selectedItems.first {
                        // Preview option (for single previewable files)
                        if isSingleSelection && !firstItem.isDirectory && FilePreviewManager.isPreviewable(firstItem) {
                            Button {
                                onPreview?(firstItem)
                            } label: {
                                Label("Preview", systemImage: "eye")
                            }
                            Divider()
                        }
                        
                        // Download
                        if !firstItem.isDirectory || !isSingleSelection {
                            Button(isSingleSelection ? "Download" : "Download Selected") {
                                if isSingleSelection, let file = selectedItems.first, !file.isDirectory {
                                    onDownload(file)
                                } else {
                                    onBatchDownload?()
                                }
                            }
                            Divider()
                        }
                        
                        // Folder download option
                        if isSingleSelection && firstItem.isDirectory {
                            Button {
                                onDownloadFolder?(firstItem)
                            } label: {
                                Label("Download Folder", systemImage: "folder.badge.gearshape")
                            }

                            // ── Add to Sidebar ──────────────────────────────
                            Button {
                                onAddToSidebar?(firstItem)
                            } label: {
                                Label("Add to Sidebar", systemImage: "sidebar.left")
                            }

                            Divider()
                        }
                        
                        // Copy
                        Button(isSingleSelection ? "Copy" : "Copy \(selectedIds.count) items") {
                            let items = isSingleSelection ? [firstItem] : selectedItems
                            onCopy?(items)
                        }
                        
                        // Cut
                        Button(isSingleSelection ? "Cut" : "Cut \(selectedIds.count) items") {
                            let items = isSingleSelection ? [firstItem] : selectedItems
                            onCut?(items)
                        }
                        
                        Divider()
                        
                        // Rename - only for single selection
                        if isSingleSelection {
                            Button("Rename") {
                                let kind = firstItem.isDirectory ? "Folder" : "File"
                                if let newName = TextInputDialog.show(
                                    title: "Rename \(kind)",
                                    message: "Enter a new name for \"\(firstItem.name)\"",
                                    placeholder: firstItem.name,
                                    initialValue: firstItem.name,
                                    confirmLabel: "Rename"
                                ), newName != firstItem.name {
                                    onRename?(firstItem, newName)
                                }
                            }
                            .disabled(onRename == nil)
                        }
                        
                        // Change Extension - only for multiple files (no folders)
                        if selectedIds.count > 1 && hasOnlyFiles {
                            Button("Change Extension...") {
                                showExtensionDialog = true
                            }
                            .disabled(onBatchChangeExtension == nil)
                        }
                        
                        // Move to Trash
                        Button(isSingleSelection ? "Move to Trash" : "Move \(selectedIds.count) items to Trash", role: .destructive) {
                            if isSingleSelection {
                                fileToDelete = firstItem
                                showDeleteConfirmation = true
                            } else {
                                batchDeleteCount = selectedIds.count
                                showBatchDeleteConfirmation = true
                            }
                        }
                    }
                }, primaryAction: { selectedIds in
                    // Double-click action
                    if let firstId = selectedIds.first,
                       let file = files.first(where: { $0.id == firstId }) {
                        if file.isDirectory {
                            onNavigate(file.path)
                        } else if FilePreviewManager.isPreviewable(file) {
                            onPreview?(file)
                        } else {
                            onDownload(file)
                        }
                    }
                })
    }
    
    @ViewBuilder
    private func fileContextMenu(for file: UnifiedFile) -> some View {
        let selectedItems = files.filter { selectedFiles.contains($0.id) }
        let isSingleSelection = selectedFiles.count <= 1
        let hasOnlyFiles = !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }
        
        // Download - show for files
        if !file.isDirectory {
            Button(isSingleSelection ? "Download" : "Download Selected") {
                if isSingleSelection {
                    onDownload(file)
                } else {
                    onBatchDownload?()
                }
            }
            Divider()
        }
        
        // Download folder
        if file.isDirectory && isSingleSelection {
            Button {
                onDownloadFolder?(file)
            } label: {
                Label("Download Folder", systemImage: "folder.badge.gearshape")
            }
            Divider()
        }
        
        // Copy
        Button(isSingleSelection ? "Copy" : "Copy \(selectedFiles.count) items") {
            let items = isSingleSelection ? [file] : selectedItems
            onCopy?(items)
        }
        
        // Cut
        Button(isSingleSelection ? "Cut" : "Cut \(selectedFiles.count) items") {
            let items = isSingleSelection ? [file] : selectedItems
            onCut?(items)
        }
        
        Divider()
        
        // Rename - only for single selection
        if isSingleSelection {
            Button("Rename") {
                let kind = file.isDirectory ? "Folder" : "File"
                if let newName = TextInputDialog.show(
                    title: "Rename \(kind)",
                    message: "Enter a new name for \"\(file.name)\"",
                    placeholder: file.name,
                    initialValue: file.name,
                    confirmLabel: "Rename"
                ), newName != file.name {
                    onRename?(file, newName)
                }
            }
            .disabled(onRename == nil)
        }
        
        // Change Extension - only for multiple files (no folders)
        if selectedFiles.count > 1 && hasOnlyFiles {
            Button("Change Extension...") {
                showExtensionDialog = true
            }
            .disabled(onBatchChangeExtension == nil)
        }
        
        // Move to Trash - always available
        Button(isSingleSelection ? "Move to Trash" : "Move \(selectedFiles.count) items to Trash", role: .destructive) {
            if isSingleSelection {
                fileToDelete = file
                showDeleteConfirmation = true
            } else {
                batchDeleteCount = selectedFiles.count
                showBatchDeleteConfirmation = true
            }
        }
        .disabled(onDelete == nil)
    }
    
    // MARK: - Helper Functions
    
    private func getFileIcon(for file: UnifiedFile) -> String {
        if file.isDirectory {
            switch file.name.lowercased() {
            case "dcim", "camera": return "camera.fill"
            case "download", "downloads": return "arrow.down.circle.fill"
            case "pictures", "photos": return "photo.fill"
            case "music": return "music.note"
            case "movies", "videos": return "film.fill"
            case "documents": return "doc.fill"
            default: return "folder.fill"
            }
        }
        
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "pdf": return "doc.text"
        case "zip", "rar", "7z": return "doc.zipper"
        case "apk": return "app.badge"
        default: return "doc"
        }
    }
    
    private func getFileColor(for file: UnifiedFile) -> Color {
        if file.isDirectory { return .blue }
        
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .purple
        case "mp4", "mov", "avi", "mkv": return .red
        case "mp3", "m4a", "wav", "flac": return .pink
        case "pdf": return .orange
        case "apk": return .green
        default: return .secondary
        }
    }
    
    private func getFileType(for file: UnifiedFile) -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "File" }
        return ext.uppercased()
    }
    
    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.blue, lineWidth: 3)
            .background(Color.blue.opacity(0.1))
            .padding(8)
            .transition(.opacity)
    }
    
    // MARK: - Actions
    
    private func showUploadDialog() {
        let openPanel = NSOpenPanel()
        openPanel.configureForPerformance() // Assuming you have this extension
        openPanel.title = "Select Files to Upload"
        openPanel.message = "Choose files to upload to \(currentPath)"
        
        openPanel.begin { response in
            if response == .OK {
                onUpload(openPanel.urls)
            }
        }
    }
}
// MARK: - Window Drag Area
// Allows dragging the app window from the path bar (like the title bar)
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DraggableNSView { DraggableNSView() }
    func updateNSView(_ nsView: DraggableNSView, context: Context) {}
    
    class DraggableNSView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}
