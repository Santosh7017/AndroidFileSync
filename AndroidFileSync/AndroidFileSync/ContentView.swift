////
////  ContentView.swift
////
//
//import SwiftUI
//import UniformTypeIdentifiers
//
//extension NSSavePanel {
//    func configureForPerformance() {
//        self.showsHiddenFiles = false
//        self.treatsFilePackagesAsDirectories = false
//        self.accessoryView = nil
//        
//        if let openPanel = self as? NSOpenPanel {
//            openPanel.canChooseDirectories = false
//            openPanel.canChooseFiles = true
//            openPanel.allowsMultipleSelection = true
//            openPanel.canCreateDirectories = false
//        } else {
//            self.canCreateDirectories = true
//        }
//    }
//}
//
//struct ContentView: View {
//    
//    @StateObject private var deviceManager = DeviceManager()
//    @StateObject private var downloadManager = DownloadManager()
//    @StateObject private var uploadManager = UploadManager()
//    @State private var files: [UnifiedFile] = []
//    @State private var currentPath: String = ""
//    @State private var loadTask: Task<Void, Never>? = nil
//    @State private var pathHistory: [String] = []
//    @State private var isLoading = false
//    
//    var body: some View {
//        VStack(spacing: 0) {
//            HeaderView(
//                deviceManager: deviceManager,
//                downloadManager: downloadManager,
//                uploadManager: uploadManager
//            )
//            
//            Divider()
//            
//            if deviceManager.isConnected {
//                HSplitView {
//                    SidebarView(
//                        quickAccessItems: QuickAccessItem.commonFolders,
//                        currentPath: currentPath,
//                        onNavigate: { path in
//                            pathHistory = [currentPath]
//                            currentPath = path
//                            Task { await loadFiles() }
//                        }
//                    )
//                    
//                    FileBrowserView(
//                        files: files,
//                        currentPath: currentPath,
//                        isLoading: isLoading,
//                        canGoBack: !pathHistory.isEmpty,
//                        onNavigate: { path in
//                            pathHistory.append(currentPath)
//                            currentPath = path
//                            Task { await loadFiles() }
//                        },
//                        onGoBack: {
//                            if let previousPath = pathHistory.popLast() {
//                                currentPath = previousPath
//                                Task { await loadFiles() }
//                            }
//                        },
//                        onDownload: handleDownload,
//                        onUpload: handleUpload
//                    )
//                }
//            } else {
//                EmptyStateView()
//            }
//            
//            // Simple status indicator - no progress
//            if !downloadManager.activeDownloads.isEmpty {
//                SimpleStatusView(
//                    items: Array(downloadManager.activeDownloads.values),
//                    type: "Downloading"
//                )
//            }
//            
//            if !uploadManager.activeUploads.isEmpty {
//                SimpleStatusView(
//                    items: Array(uploadManager.activeUploads.values),
//                    type: "Uploading"
//                )
//            }
//        }
//        .frame(minWidth: 800, minHeight: 600)
//        .task {
//            await deviceManager.detectDevice()
//            if deviceManager.isConnected {
//                currentPath = await deviceManager.getRealStoragePath()
//                await loadFiles()
//            }
//        }
//    }
//    
//    private func loadFiles() async {
//        isLoading = true
//        files = (try? await deviceManager.listFiles(path: currentPath)) ?? []
//        isLoading = false
//    }
//    
//    private func handleDownload(file: UnifiedFile) {
//        let panel = NSSavePanel()
//        panel.configureForPerformance()
//        panel.nameFieldStringValue = file.name
//        panel.title = "Save File"
//        
//        panel.begin { [downloadManager] response in
//            guard response == .OK, let url = panel.url else { return }
//            Task {
//                try? await downloadManager.downloadFile(
//                    devicePath: file.path,
//                    fileName: file.name,
//                    fileSize: file.size,
//                    to: url.path
//                )
//            }
//        }
//    }
//    
//    private func handleUpload(urls: [URL]) {
//        Task {
//            var filesToUpload: [(String, String, UInt64)] = []
//            
//            for url in urls {
//                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
//                      let size = attrs[.size] as? UInt64 else { continue }
//                filesToUpload.append((url.path, url.lastPathComponent, size))
//            }
//            
//            await uploadManager.uploadMultipleFiles(
//                files: filesToUpload,
//                toDirectory: currentPath
//            )
//            
//            try? await Task.sleep(nanoseconds: 1_000_000_000)
//            await loadFiles()
//        }
//    }
//}
//
//// MARK: - Simple Status View (No Progress Bar)
//
//struct SimpleStatusView<T: Identifiable>: View {
//    let items: [T]
//    let type: String
//    
//    var body: some View {
//        VStack(spacing: 0) {
//            Divider()
//            
//            HStack(spacing: 12) {
//                ProgressView()
//                    .scaleEffect(0.7)
//                
//                Text("\(type) \(items.count) file\(items.count == 1 ? "" : "s")...")
//                    .font(.caption)
//                    .foregroundColor(.secondary)
//                
//                Spacer()
//            }
//            .padding(.horizontal, 16)
//            .padding(.vertical, 12)
//            .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
//        }
//    }
//}
//
//#Preview {
//    ContentView()
//}


//
//  ContentView.swift
//  (DEFINITIVE DETECTION FIX)
//
//
//  ContentView.swift
//
//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {
    // Receive managers from App - don't observe them here
    let deviceManager: DeviceManager
    let downloadManager: DownloadManager
    let uploadManager: UploadManager

    @State private var files: [UnifiedFile] = []
    @State private var currentPath = "/sdcard"
    @State private var pathHistory: [String] = []
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>? = nil
    
    // File action manager
    @StateObject private var fileActionManager = FileActionManager()
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Multi-selection state
    @State private var selectedFiles: Set<UUID> = []
    
    // Trash view state
    @State private var showTrashView = false
    
    // Search and sort state
    @State private var searchQuery = ""
    @State private var sortOption: ActionToolbar.SortOption = .name
    
    // Computed filtered files
    private var filteredFiles: [UnifiedFile] {
        var result = files
        
        // Apply search filter
        if !searchQuery.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        
        // Apply sort
        switch sortOption {
        case .name:
            result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .size:
            result.sort { $0.size > $1.size }
        case .type:
            result.sort { 
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory // Folders first
                }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        
        return result
    }
    
    private func sortFiles(by option: ActionToolbar.SortOption) {
        sortOption = option
    }

    var body: some View {
        VStack(spacing: 0) {
            // Your HeaderView
            HeaderView(deviceManager: deviceManager, downloadManager: downloadManager, uploadManager: uploadManager)
            Divider()

            // Main Content
            if deviceManager.isConnected {
                HSplitView {
                    SidebarView(
                        quickAccessItems: QuickAccessItem.commonFolders,
                        currentPath: currentPath,
                        onNavigate: navigateTo,
                        trashCount: fileActionManager.trashedItems.count,
                        onOpenTrash: { showTrashView = true }
                    )
                    
                    VStack(spacing: 0) {
                        // Action Toolbar
                        ActionToolbar(
                            currentPath: currentPath,
                            fileActionManager: fileActionManager,
                            onRefresh: { await loadFiles() },
                            searchQuery: $searchQuery,
                            totalFileCount: files.count,
                            filteredFileCount: filteredFiles.count,
                            onSortChanged: { option in
                                sortFiles(by: option)
                            }
                        )
                        Divider()
                        
                        // File Browser
                        FileBrowserView(
                            files: filteredFiles,
                            currentPath: currentPath,
                            isLoading: isLoading,
                            canGoBack: !pathHistory.isEmpty,
                            selectedFiles: $selectedFiles,
                            onNavigate: navigateTo,
                            onGoBack: navigateBack,
                            onDownload: handleDownload,
                            onUpload: handleUpload,
                            onDelete: handleDelete,
                            onRename: handleRename,
                            onBatchDelete: handleBatchDelete,
                            onBatchDownload: handleBatchDownload,
                            onBatchChangeExtension: { ext in handleBatchChangeExtension(ext) },
                            onCopy: { files in fileActionManager.copyToClipboard(files) },
                            onCut: { files in fileActionManager.cutToClipboard(files) }
                        )
                    }
                }
            } else {
                // Your EmptyStateView or a loading view
                EmptyStateView()
            }
            
            // Enhanced Progress Views with Speed and Details (Isolated)
            TransferProgressContainer(
                downloadManager: downloadManager,
                uploadManager: uploadManager
            )
        }
        .frame(minWidth: 800, minHeight: 600)
        .task { await initializeDevice() }
        .alert("Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) {
                fileActionManager.clearError()
            }
        } message: {
            Text(errorMessage)
        }
        // Trash view sheet
        .sheet(isPresented: $showTrashView, onDismiss: {
            // Refresh file list after closing trash (in case files were restored)
            Task {
                await loadFiles()
            }
        }) {
            TrashView(fileActionManager: fileActionManager)
                .frame(width: 450, height: 400)
        }
    }
    
    // MARK: - Functions (Your navigation and data loading logic)

    private func initializeDevice() async {
        await deviceManager.detectDevice()
        if deviceManager.isConnected {
            currentPath = await deviceManager.getRealStoragePath()
            await loadFiles()
        }
    }
    
    private func loadFiles() async {
        // Check if cancelled early
        guard !Task.isCancelled else { return }
        
        // Pause download progress updates to avoid ADB contention
        await MainActor.run {
            downloadManager.pauseUpdates()
            isLoading = true
        }
        
        // Check again before expensive operation
        guard !Task.isCancelled else {
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Do the expensive work completely off main thread
        let newFiles = (try? await deviceManager.listFiles(path: currentPath)) ?? []
        
        // Check before updating UI
        guard !Task.isCancelled else {
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Quick, simple update without animation
        await MainActor.run {
            self.files = newFiles
            isLoading = false
            downloadManager.resumeUpdates()  // Resume progress updates
        }
    }

    private func navigateTo(_ path: String) {
        // Cancel any in-progress load
        loadTask?.cancel()
        
        pathHistory.append(currentPath)
        currentPath = path
        
        // Show loading but keep old files visible
        isLoading = true
        
        // Force completely off main thread
        loadTask = Task.detached(priority: .userInitiated) {
            await self.loadFiles()
        }
    }

    private func navigateBack() {
        guard let previousPath = pathHistory.popLast() else { return }
        
        // Cancel any in-progress load
        loadTask?.cancel()
        
        currentPath = previousPath
        
        // Show loading but keep old files visible
        isLoading = true
        
        // Force completely off main thread
        loadTask = Task.detached(priority: .userInitiated) {
            await self.loadFiles()
        }
    }
    
    private func handleDownload(file: UnifiedFile) {
        // Capture manager so the closure does not capture self strongly
        let manager = self.downloadManager

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = file.name
        savePanel.title = "Save File"
        savePanel.message = "Choose where to save \(file.name)"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            Task {
                do {
                    try await manager.downloadFile(
                        devicePath: file.path,
                        fileName: file.name,
                        fileSize: file.size,   // ✅ this was missing
                        to: url.path
                    )
                } catch {
                    print("❌ Download failed: \(error)")
                }
            }
        }
    }
    
    private func handleUpload(urls: [URL]) {
        let manager = self.uploadManager
        let path = self.currentPath
        
        Task {
            var filesToUpload: [(localPath: String, fileName: String, fileSize: UInt64)] = []
            
            for url in urls {
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = attrs[.size] as? UInt64 else { 
                    print("⚠️ Could not get file size for: \(url.lastPathComponent)")
                    continue 
                }
                filesToUpload.append((url.path, url.lastPathComponent, size))
            }
            
            await manager.uploadMultipleFiles(
                files: filesToUpload,
                toDirectory: path
            )
            
            // Refresh file list after upload
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await loadFiles()
        }
    }
    
    private func handleDelete(_ file: UnifiedFile) {
        Task {
            do {
                try await fileActionManager.deleteFile(file)
                
                // Refresh file list after deletion
                await loadFiles()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    private func handleRename(_ file: UnifiedFile, newName: String) {
        Task {
            do {
                try await fileActionManager.renameFile(file, to: newName)
                
                // Refresh file list after rename
                await loadFiles()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    // MARK: - Batch Operations
    
    private func handleBatchDelete() {
        let filesToDelete = files.filter { selectedFiles.contains($0.id) }
        
        guard !filesToDelete.isEmpty else { return }
        
        Task {
            do {
                // Delete files one by one
                for file in filesToDelete {
                    try await fileActionManager.deleteFile(file)
                }
                
                // Clear selection and refresh
                selectedFiles.removeAll()
                await loadFiles()
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showErrorAlert = true
                }
            }
        }
    }
    
    private func handleBatchDownload() {
        let filesToDownload = files.filter { selectedFiles.contains($0.id) && !$0.isDirectory }
        
        guard !filesToDownload.isEmpty else {
            errorMessage = "No downloadable files selected (folders cannot be downloaded)"
            showErrorAlert = true
            return
        }
        
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Download Folder"
        openPanel.message = "Choose where to save \(filesToDownload.count) file(s)"
        
        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else { return }
            
            Task {
                for file in filesToDownload {
                    let destinationPath = directory.appendingPathComponent(file.name).path
                    
                    do {
                        try await downloadManager.downloadFile(
                            devicePath: file.path,
                            fileName: file.name,
                            fileSize: file.size,
                            to: destinationPath
                        )
                    } catch {
                        print("❌ Failed to download \(file.name): \(error)")
                    }
                }
                
                // Clear selection after download
                await MainActor.run {
                    selectedFiles.removeAll()
                }
            }
        }
    }
    
    private func handleBatchChangeExtension(_ newExtension: String) {
        let filesToChange = files.filter { selectedFiles.contains($0.id) && !$0.isDirectory }
        
        guard !filesToChange.isEmpty else {
            errorMessage = "No files selected for extension change"
            showErrorAlert = true
            return
        }
        
        Task {
            var successCount = 0
            var failCount = 0
            
            for file in filesToChange {
                // Get filename without extension
                let nameWithoutExt: String
                if let dotIndex = file.name.lastIndex(of: ".") {
                    nameWithoutExt = String(file.name[..<dotIndex])
                } else {
                    nameWithoutExt = file.name
                }
                
                let newName = "\(nameWithoutExt).\(newExtension)"
                
                do {
                    try await fileActionManager.renameFile(file, to: newName)
                    successCount += 1
                } catch {
                    print("❌ Failed to rename \(file.name): \(error)")
                    failCount += 1
                }
            }
            
            // Refresh and clear selection
            await loadFiles()
            await MainActor.run {
                selectedFiles.removeAll()
                
                if failCount > 0 {
                    errorMessage = "Changed \(successCount) files, \(failCount) failed"
                    showErrorAlert = true
                }
            }
        }
    }
}

