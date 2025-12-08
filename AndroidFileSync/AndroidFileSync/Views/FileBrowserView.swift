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
        Table(files, selection: $selectedFiles) {
            TableColumn("Name") { file in
                HStack(spacing: 8) {
                    Image(systemName: getFileIcon(for: file))
                        .foregroundColor(getFileColor(for: file))
                        .frame(width: 20)
                    
                    Text(file.name)
                        .lineLimit(1)
                }
            }
            .width(min: 200, ideal: 300)
            
            TableColumn("Size") { file in
                if file.isDirectory {
                    Text("--")
                        .foregroundColor(.secondary)
                } else {
                    Text(formatBytes(file.size))
                        .foregroundColor(.secondary)
                }
            }
            .width(min: 80, ideal: 100)
            
            TableColumn("Type") { file in
                Text(file.isDirectory ? "Folder" : getFileType(for: file))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 120)
        }
        .contextMenu(forSelectionType: UUID.self) { selectedIds in
            let selectedCount = selectedIds.count
            let isSingleSelection = selectedCount == 1
            let selectedItems = files.filter { selectedIds.contains($0.id) }
            let hasOnlyFiles = !selectedItems.isEmpty && selectedItems.allSatisfy { !$0.isDirectory }
            
            // Download - show for files
            if let firstId = selectedIds.first,
               let file = files.first(where: { $0.id == firstId }),
               !file.isDirectory {
                Button(isSingleSelection ? "Download" : "Download Selected") {
                    if isSingleSelection {
                        onDownload(file)
                    } else {
                        onBatchDownload?()
                    }
                }
                Divider()
            }
            
            // Rename - only for single selection
            if isSingleSelection,
               let firstId = selectedIds.first,
               let file = files.first(where: { $0.id == firstId }) {
                Button("Rename") {
                    fileToRename = file
                    newFileName = file.name
                    showRenameDialog = true
                }
                .disabled(onRename == nil)
            }
            
            // Change Extension - only for multiple files (no folders)
            if selectedCount > 1 && hasOnlyFiles {
                Button("Change Extension...") {
                    showExtensionDialog = true
                }
                .disabled(onBatchChangeExtension == nil)
            }
            
            // Move to Trash - always available
            Button(isSingleSelection ? "Move to Trash" : "Move \(selectedCount) items to Trash", role: .destructive) {
                if isSingleSelection,
                   let firstId = selectedIds.first,
                   let file = files.first(where: { $0.id == firstId }) {
                    fileToDelete = file
                    showDeleteConfirmation = true
                } else {
                    // Show confirmation for batch delete
                    batchDeleteCount = selectedCount
                    showBatchDeleteConfirmation = true
                }
            }
            .disabled(onDelete == nil)
        } primaryAction: { selectedIds in
            // Double-click or Enter key action
            if let firstId = selectedIds.first,
               let file = files.first(where: { $0.id == firstId }) {
                if file.isDirectory {
                    onNavigate(file.path)
                } else {
                    onDownload(file)
                }
            }
        }
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
