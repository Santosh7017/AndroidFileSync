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
    let onBatchDelete: (() -> Void)?
    let onBatchDownload: (() -> Void)?
    let onBatchChangeExtension: ((String) -> Void)?
    var onCopy: (([UnifiedFile]) -> Void)? = nil
    var onCut: (([UnifiedFile]) -> Void)? = nil
    
    // Sorting support
    var sortOption: ActionToolbar.SortOption = .name
    var onSortChange: ((ActionToolbar.SortOption) -> Void)? = nil
    
    // Equatable implementation - only compare data that affects rendering
    static func == (lhs: FileBrowserView, rhs: FileBrowserView) -> Bool {
        lhs.files.map(\.id) == rhs.files.map(\.id) &&
        lhs.currentPath == rhs.currentPath &&
        lhs.isLoading == rhs.isLoading &&
        lhs.canGoBack == rhs.canGoBack &&
        lhs.selectedFiles == rhs.selectedFiles
    }
    
    // FIX 1: Bring back the state variable for UI feedback
    @State private var isDraggingOver = false
    
    // Delete confirmation state
    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: UnifiedFile? = nil
    @State private var showBatchDeleteConfirmation = false
    @State private var batchDeleteCount = 0
    
    // Rename state (for context menu)
    @State private var showRenameDialog = false
    @State private var fileToRename: UnifiedFile? = nil
    @State private var newFileName = ""
    
    // Change extension state (for context menu)
    @State private var showExtensionDialog = false
    @State private var newExtension = ""
    
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            fileListOrEmptyState
            
            // Selection toolbar
            if !selectedFiles.isEmpty {
                let selectedFilesList = files.filter { selectedFiles.contains($0.id) }
                SelectionToolbar(
                    selectedFiles: selectedFilesList,
                    onClearSelection: { selectedFiles.removeAll() },
                    onDelete: { onBatchDelete?() },
                    onDownload: { onBatchDownload?() },
                    onRename: onRename,
                    onChangeExtension: onBatchChangeExtension
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
        // Rename alert
        .alert("Rename \(fileToRename?.isDirectory == true ? "folder" : "file")", isPresented: $showRenameDialog) {
            TextField("New name", text: $newFileName)
            Button("Cancel", role: .cancel) {
                fileToRename = nil
                newFileName = ""
            }
            Button("Rename") {
                if let file = fileToRename, !newFileName.isEmpty && newFileName != file.name {
                    onRename?(file, newFileName)
                }
                fileToRename = nil
                newFileName = ""
            }
        } message: {
            Text("Enter a new name for \(fileToRename?.name ?? "this item")")
        }
        // Change extension alert
        .alert("Change Extension", isPresented: $showExtensionDialog) {
            TextField("New extension (e.g., jpg, png)", text: $newExtension)
            Button("Cancel", role: .cancel) {
                newExtension = ""
            }
            Button("Apply") {
                if !newExtension.isEmpty {
                    let ext = newExtension.hasPrefix(".") ? String(newExtension.dropFirst()) : newExtension
                    onBatchChangeExtension?(ext)
                }
                newExtension = ""
            }
        } message: {
            Text("Change extension for all selected files")
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
        HStack {
            if canGoBack {
                backButton
            }
            pathDisplay
            Spacer()
            uploadButton
            Divider().frame(height: 16).padding(.horizontal, 8)
            statusIndicator
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var backButton: some View {
        Button(action: onGoBack) {
            Image(systemName: "chevron.left").font(.title3)
        }
        .buttonStyle(.plain)
        .help("Go back")
    }
    
    private var pathDisplay: some View {
        HStack {
            Image(systemName: "folder")
            Text(currentPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    private var uploadButton: some View {
        Button(action: showUploadDialog) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                Text("Upload").font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .help("Upload files to this folder")
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        if isLoading {
            ProgressView().scaleEffect(0.7)
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
    
    private var fileList: some View {
        VStack(spacing: 0) {
            // Custom sortable column headers
            SortableFileHeader(
                currentSort: sortOption,
                onSortChange: { newSort in
                    onSortChange?(newSort)
                }
            )
            
            Divider()
            
            // File list with selection
            ScrollViewReader { proxy in
                List(files, selection: $selectedFiles) { file in
                    SortableFileRow(file: file)
                        .tag(file.id)
                        .contextMenu {
                            fileContextMenu(for: file)
                        }
                        .onTapGesture(count: 2) {
                            if file.isDirectory {
                                onNavigate(file.path)
                            } else {
                                onDownload(file)
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
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
                fileToRename = file
                newFileName = file.name
                showRenameDialog = true
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

// MARK: - Sortable File Header

struct SortableFileHeader: View {
    let currentSort: ActionToolbar.SortOption
    let onSortChange: (ActionToolbar.SortOption) -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            SortableColumnHeader(
                title: "Name",
                option: .name,
                currentSort: currentSort,
                onTap: onSortChange
            )
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            
            SortableColumnHeader(
                title: "Size",
                option: .size,
                currentSort: currentSort,
                onTap: onSortChange
            )
            .frame(width: 90, alignment: .trailing)
            
            SortableColumnHeader(
                title: "Date",
                option: .date,
                currentSort: currentSort,
                onTap: onSortChange
            )
            .frame(width: 100, alignment: .trailing)
            
            SortableColumnHeader(
                title: "Type",
                option: .type,
                currentSort: currentSort,
                onTap: onSortChange
            )
            .frame(width: 80, alignment: .center)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
    }
}

struct SortableColumnHeader: View {
    let title: String
    let option: ActionToolbar.SortOption
    let currentSort: ActionToolbar.SortOption
    let onTap: (ActionToolbar.SortOption) -> Void
    
    var isSelected: Bool { option == currentSort }
    
    var body: some View {
        Button(action: { onTap(option) }) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(.caption, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                
                if isSelected {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}

// MARK: - Sortable File Row View

struct SortableFileRow: View {
    let file: UnifiedFile
    
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    var body: some View {
        HStack(spacing: 0) {
            // Name column
            HStack(spacing: 8) {
                Image(systemName: fileIcon)
                    .foregroundColor(fileColor)
                    .frame(width: 18)
                
                Text(file.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
            
            // Size column
            Text(file.isDirectory ? "--" : formatBytes(file.size))
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .trailing)
            
            // Date column
            Text(dateText)
                .font(.system(.caption, design: .default))
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .trailing)
            
            // Type column
            Text(file.isDirectory ? "Folder" : fileType)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .center)
        }
        .padding(.vertical, 4)
    }
    
    private var dateText: String {
        if let date = file.modificationDate {
            return Self.dateFormatter.string(from: date)
        }
        return "--"
    }
    
    private var fileIcon: String {
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
    
    private var fileColor: Color {
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
    
    private var fileType: String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return "File" }
        return ext.uppercased()
    }
}
