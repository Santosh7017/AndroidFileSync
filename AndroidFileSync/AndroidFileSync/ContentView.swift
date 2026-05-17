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
internal import Combine
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    // Observe managers from App to react to state changes
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var uploadManager: UploadManager
    @StateObject private var filePreviewManager = FilePreviewManager()
    @StateObject private var sidebarManager = SidebarManager()

    @State private var files: [UnifiedFile] = []
    @State private var currentPath = "/sdcard"
    @State private var pathHistory: [String] = []
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>? = nil
    
    // File action manager
    @StateObject private var fileActionManager = FileActionManager()
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Paste conflict alert
    @State private var showConflictAlert = false
    
    // Multi-selection state
    @State private var selectedFiles: Set<UUID> = []
    
    // Trash view state
    @State private var showTrashView = false
    @State private var showWirelessConnect = false
    @ObservedObject private var updateChecker = UpdateChecker.shared

    // App browser state
    @StateObject private var appManager = AppManager()
    @State private var activeAppFilter: AppFilter? = nil
    
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
            // Sort by file type/extension, folders first
            result.sort { 
                // Folders always come first
                if $0.isDirectory != $1.isDirectory {
                    return $0.isDirectory
                }
                // For files, sort by extension first, then by name
                if !$0.isDirectory && !$1.isDirectory {
                    let ext0 = ($0.name as NSString).pathExtension.lowercased()
                    let ext1 = ($1.name as NSString).pathExtension.lowercased()
                    if ext0 != ext1 {
                        return ext0 < ext1
                    }
                }
                // Same type - sort by name
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .date:
            result.sort { 
                // Newest first; nil dates go to the end
                let date0 = $0.modificationDate ?? Date.distantPast
                let date1 = $1.modificationDate ?? Date.distantPast
                return date0 > date1
            }
        }
        
        return result
    }
    
    private func sortFiles(by option: ActionToolbar.SortOption) {
        sortOption = option
    }

    var body: some View {
        contentWithPresentations
    }

    // Level 1: presentation modifiers (alerts + sheets + keyboard shortcuts)
    // Split from body to stay under Swift type-checker expression complexity limit
    private var contentWithPresentations: some View {
        contentWithAlerts
            .sheet(isPresented: $showTrashView) {
                TrashView(fileActionManager: fileActionManager)
                    .frame(width: 450, height: 400)
            }
            .sheet(isPresented: $showWirelessConnect) {
                WirelessConnectView(deviceManager: deviceManager, onConnected: {
                    Task {
                        currentPath = await deviceManager.getRealStoragePath()
                        await loadFiles()
                    }
                })
            }
            .background(
                Group {
                    Button("") { handleGlobalCopy() }.keyboardShortcut("c", modifiers: .command)
                    Button("") { handleGlobalCut() }.keyboardShortcut("x", modifiers: .command)
                    Button("") { handleGlobalPaste() }.keyboardShortcut("v", modifiers: .command)
                }
                .hidden()
            )
    }

    // Level 2: alert modifiers
    private var contentWithAlerts: some View {
        layoutContent
            .alert("Error", isPresented: $showErrorAlert) {
                Button("OK", role: .cancel) { fileActionManager.clearError() }
            } message: {
                Text(errorMessage)
            }
            .alert(pasteConflictTitle, isPresented: $showConflictAlert) {
                Button("Replace") {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .replace)
                        await loadFiles()
                    }
                }
                Button("Keep Both") {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .keepBoth)
                        await loadFiles()
                    }
                }
                Button("Skip", role: .cancel) {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .skip)
                        await loadFiles()
                    }
                }
            } message: {
                Text(pasteConflictMessage)
            }
            .onChange(of: fileActionManager.pasteConflicts.count) { newCount in
                showConflictAlert = newCount > 0
            }
            .onChange(of: deviceManager.sdCardPath) { newPath in
                sidebarManager.updateSDCard(path: newPath)
            }
    }

    // Level 3: layout + input modifiers
    private var layoutContent: some View {
        VStack(spacing: 0) {
            HeaderView(
                deviceManager: deviceManager,
                downloadManager: downloadManager,
                uploadManager: uploadManager,
                showWirelessConnect: $showWirelessConnect
            )
            Divider()

            if updateChecker.shouldShowBanner {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    Text("Version \(updateChecker.latestVersion) available")
                        .font(.caption.weight(.medium))
                    Spacer()
                    Button(action: { updateChecker.openReleasePage() }) {
                        Text("Download")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .background(Color.blue)
                            .cornerRadius(4)
                    }
                    .buttonStyle(.plain)
                    Button(action: { updateChecker.dismissForToday() }) {
                        Image(systemName: "xmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.08))
            }

            if deviceManager.isConnected {
                connectedContent
            } else {
                EmptyStateView(
                    isDetecting: deviceManager.isDetecting,
                    onRetry: { Task { await initializeDevice() } },
                    onConnectWiFi: { showWirelessConnect = true }
                )
            }

            TransferProgressContainer(
                downloadManager: downloadManager,
                uploadManager: uploadManager,
                deviceManager: deviceManager
            )
        }
        .frame(minWidth: 800, minHeight: 600)
        .onAppear {
            updateChecker.checkForUpdates()
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            var fileURLs: [URL] = []
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let u = url { fileURLs.append(u) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                if !fileURLs.isEmpty { handleUpload(urls: fileURLs) }
            }
            return true
        }
        .task { await initializeDevice() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            if !deviceManager.isConnected && !deviceManager.isDetecting {
                Task {
                    await deviceManager.detectDevice()
                    if deviceManager.isConnected {
                        currentPath = await deviceManager.getRealStoragePath()
                        await loadFiles()
                    }
                }
            }
        }
    }

    // Extracted to keep `body` chain under Swift complexity limit
    @ViewBuilder
    private var connectedContent: some View {
        HSplitView {
            SidebarView(
                sidebarManager: sidebarManager,
                currentPath: currentPath,
                onNavigate: { path in
                    activeAppFilter = nil   // switch back to file mode
                    navigateTo(path)
                },
                trashCount: fileActionManager.trashedItems.count,
                onOpenTrash: { showTrashView = true },
                activeAppFilter: activeAppFilter,
                onSelectAppFilter: { filter in
                    activeAppFilter = filter
                },
                storageStats: deviceManager.storageStats
            )

            ZStack {
                if let appFilter = activeAppFilter {
                    // ── App Browser ───────────────────────────────────────────
                    AppBrowserView(appManager: appManager, initialFilter: appFilter)
                        .transition(.opacity)
                } else {
                // ── File Browser ──────────────────────────────────────────────
                VStack(spacing: 0) {
                    ActionToolbar(
                        currentPath: currentPath,
                        fileActionManager: fileActionManager,
                        onRefresh: { await loadFiles() },
                        searchQuery: $searchQuery,
                        totalFileCount: files.count,
                        filteredFileCount: filteredFiles.count,
                        selectedSort: sortOption,
                        onSortChanged: { option in sortFiles(by: option) }
                    )
                    Divider()
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
                        onPreview: { file in filePreviewManager.previewFile(file) },
                        onBatchDelete: handleBatchDelete,
                        onBatchDownload: handleBatchDownload,
                        onBatchChangeExtension: { ext in handleBatchChangeExtension(ext) },
                        onCopy: { files in fileActionManager.copyToClipboard(files) },
                        onCut: { files in fileActionManager.cutToClipboard(files) },
                        onDownloadFolder: handleFolderDownload,
                        onAddToSidebar: { folder in
                            sidebarManager.addItem(
                                name: folder.name,
                                path: folder.path,
                                icon: "folder.fill",
                                color: "blue"
                            )
                        },
                        onPermanentDelete: handlePermanentDelete,
                        sortOption: sortOption,
                        onSortChange: { option in sortFiles(by: option) }
                    )
                }

                if filePreviewManager.isLoading {
                    VStack(spacing: 12) {
                        ProgressView().scaleEffect(1.2)
                        Text("Loading preview...").font(.subheadline).foregroundColor(.secondary)
                        Text(filePreviewManager.loadingFileName)
                            .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial))
                }
                } // end else (file browser)
            }
        }
    }

        // MARK: - Computed Properties for Alerts
    
    private var pasteConflictTitle: String {
        let count = fileActionManager.pasteConflicts.count
        if count == 1 {
            if let first = fileActionManager.pasteConflicts.first {
                return "“\(first.file.name)” already exists"
            }
            return "File already exists"
        }
        return "\(count) items already exist"
    }
    
    private var pasteConflictMessage: String {
        let count = fileActionManager.pasteConflicts.count
        if count == 1 {
            let name = fileActionManager.pasteConflicts.first?.file.name ?? ""
            return "\"\(name)\" already exists at the destination. Replace it, keep both files, or skip?"
        }
        return "\(count) files already exist at the destination. Choose how to proceed for all of them."
    }

    // MARK: - Global Actions
    
    private func handleGlobalCopy() {
        let items = files.filter { selectedFiles.contains($0.id) }
        if items.isEmpty {
            print("⌘C: No matching files in current listing (selectedFiles=\(selectedFiles.count), files=\(files.count))")
            return
        }
        print("⌘C: Copying \(items.count) item(s): \(items.map(\.name))")
        fileActionManager.copyToClipboard(items)
    }
    
    private func handleGlobalCut() {
        let items = files.filter { selectedFiles.contains($0.id) }
        if items.isEmpty {
            print("⌘X: No matching files in current listing")
            return
        }
        print("⌘X: Cutting \(items.count) item(s): \(items.map(\.name))")
        fileActionManager.cutToClipboard(items)
    }
    
    private func handleGlobalPaste() {
        if !fileActionManager.clipboard.isEmpty {
            // Internal paste — sequential: paste first, then refresh once.
            Task {
                do {
                    try await fileActionManager.paste(to: currentPath)
                } catch {
                    print("❌ Paste failed: \(error.localizedDescription)")
                }
                await loadFiles()
            }
        } else {
            // Finder drag-paste: read URLs from Mac pasteboard
            guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  !urls.isEmpty else { return }
            handleUpload(urls: urls)
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
        
        // Clear selection — UUIDs are re-generated on every listFiles call,
        // so stale IDs would match nothing (or wrong files) in the new folder.
        selectedFiles.removeAll()
        
        pathHistory.append(currentPath)
        currentPath = path
        isLoading = true
        
        loadTask = Task.detached(priority: .userInitiated) {
            await self.loadFiles()
        }
    }

    private func navigateBack() {
        guard let previousPath = pathHistory.popLast() else { return }
        
        loadTask?.cancel()
        
        // Clear selection on back navigation for the same reason.
        selectedFiles.removeAll()
        
        currentPath = previousPath
        isLoading = true
        
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
            // ── Build upload list ───────────────────────────────────────────
            var allItems: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)] = []
            var remoteDirsToCreate: Set<String> = []

            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                    print("⚠️ File does not exist: \(url.lastPathComponent)")
                    continue
                }

                if isDir.boolValue {
                    let basePath = url.path
                    let remoteFolderBase = (path.hasSuffix("/") ? path : path + "/") + url.lastPathComponent
                    remoteDirsToCreate.insert(remoteFolderBase)

                    guard let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    ) else { continue }

                    for case let fileURL as URL in enumerator {
                        guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                              rv.isRegularFile == true else { continue }

                        let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                        let remoteFilePath = remoteFolderBase + "/" + relativePath
                        let remoteDir = (remoteFilePath as NSString).deletingLastPathComponent
                        remoteDirsToCreate.insert(remoteDir)

                        let size = UInt64(rv.fileSize ?? 0)
                        let fileName = (relativePath as NSString).lastPathComponent
                        allItems.append((localPath: fileURL.path, fileName: fileName, fileSize: size, devicePath: remoteDir))
                    }
                } else {
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? UInt64 else {
                        print("⚠️ Could not get file size for: \(url.lastPathComponent)")
                        continue
                    }
                    allItems.append((localPath: url.path, fileName: url.lastPathComponent, fileSize: size, devicePath: path))
                }
            }

            guard !allItems.isEmpty else { return }

            // ── Conflict check: probe device in parallel ────────────────────
            let adb = ADBManager.getADBPath()

            // Build full device paths for each item
            func fullDevicePath(_ item: (localPath: String, fileName: String, fileSize: UInt64, devicePath: String)) -> String {
                let (safeName, _) = FileNameHelper.getSafeFilename(item.fileName)
                return item.devicePath.hasSuffix("/")
                    ? item.devicePath + safeName
                    : item.devicePath + "/" + safeName
            }

            // Run all existence checks concurrently
            var conflictingPaths = Set<String>()
            await withTaskGroup(of: (String, Bool).self) { group in
                for item in allItems {
                    let devPath = fullDevicePath(item)
                    let escaped = devPath.replacingOccurrences(of: "'", with: "'\\''")
                    group.addTask {
                        let (_, out, _) = await Shell.runAsync(
                            adb,
                            args: ADBManager.deviceArgs(["shell", "[ -e '\(escaped)' ] && echo 1 || echo 0"])
                        )
                        let exists = out.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                        return (devPath, exists)
                    }
                }
                for await (devPath, exists) in group {
                    if exists { conflictingPaths.insert(devPath) }
                }
            }

            // ── If conflicts exist, ask user ────────────────────────────────
            if !conflictingPaths.isEmpty {
                let conflictNames = allItems
                    .filter { conflictingPaths.contains(fullDevicePath($0)) }
                    .map { $0.fileName }

                // Brief pause so macOS finishes the drag-and-drop animation
                try? await Task.sleep(nanoseconds: 350_000_000)

                let choice = await MainActor.run {
                    ConflictDialog.show(conflictNames: conflictNames, totalCount: allItems.count)
                }

                switch choice {
                case .replace: break   // keep allItems as-is, overwrite
                case .skip:            // remove conflicting items
                    allItems = allItems.filter { !conflictingPaths.contains(fullDevicePath($0)) }
                case .cancel: return   // abort entirely
                }
            }


            guard !allItems.isEmpty else { return }

            // ── Create remote dirs then upload ──────────────────────────────
            if !remoteDirsToCreate.isEmpty {
                await ADBManager.batchCreateFolders(paths: Array(remoteDirsToCreate))
            }

            await manager.uploadFilesToPaths(files: allItems)

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

    private func handlePermanentDelete() {
        let filesToDelete = files.filter { selectedFiles.contains($0.id) }
        guard !filesToDelete.isEmpty else { return }
        Task {
            do {
                for file in filesToDelete {
                    try await fileActionManager.deleteFile(file, permanent: true)
                }
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
        let selectedItems = files.filter { selectedFiles.contains($0.id) }
        
        guard !selectedItems.isEmpty else {
            errorMessage = "No files or folders selected."
            showErrorAlert = true
            return
        }
        
        let selectedFolders = selectedItems.filter { $0.isDirectory }
        let selectedFileItems = selectedItems.filter { !$0.isDirectory }
        
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Download Folder"
        openPanel.message = "Choose where to save \(selectedItems.count) item(s)"
        
        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else { return }
            
            Task {
                // Build one unified download list
                var allItems: [(devicePath: String, fileName: String, fileSize: UInt64, localPath: String)] = []
                
                // 1. Add individual files
                for file in selectedFileItems {
                    allItems.append((
                        devicePath: file.path,
                        fileName: file.name,
                        fileSize: file.size,
                        localPath: directory.appendingPathComponent(file.name).path
                    ))
                }
                
                // 2. Scan each folder and add its contents
                for folder in selectedFolders {
                    // Show scanning state
                    await MainActor.run {
                        downloadManager.isScanning = true
                        downloadManager.scanningFolderName = folder.name
                    }
                    
                    do {
                        let folderFiles = try await ADBManager.listAllFilesRecursively(path: folder.path)
                        let destination = directory.appendingPathComponent(folder.name)
                        
                        for file in folderFiles {
                            let localFileURL = destination.appendingPathComponent(file.relativePath)
                            let localDir = localFileURL.deletingLastPathComponent()
                            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
                            
                            let fileName = (file.relativePath as NSString).lastPathComponent
                            allItems.append((
                                devicePath: file.devicePath,
                                fileName: fileName,
                                fileSize: file.size,
                                localPath: localFileURL.path
                            ))
                        }
                    } catch {
                        print("❌ Failed to scan folder \(folder.name): \(error)")
                    }
                }
                
                await MainActor.run {
                    downloadManager.isScanning = false
                    downloadManager.scanningFolderName = ""
                }
                
                guard !allItems.isEmpty else {
                    await MainActor.run {
                        errorMessage = "No files found to download."
                        showErrorAlert = true
                    }
                    return
                }
                
                // Set folder name for UI if we downloaded any folders
                if !selectedFolders.isEmpty {
                    await MainActor.run {
                        downloadManager.currentFolderName = selectedFolders.count == 1
                            ? selectedFolders.first!.name
                            : "\(selectedFolders.count) folders"
                    }
                }
                
                // Single unified download call — correct count from the start
                await downloadManager.downloadMultipleFiles(files: allItems)
                await MainActor.run { selectedFiles.removeAll() }
            }
        }
    }
    
    private func handleFolderDownload(_ folder: UnifiedFile) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false
        openPanel.canCreateDirectories = true
        openPanel.allowsMultipleSelection = false
        openPanel.title = "Select Download Location"
        openPanel.message = "Folder '\(folder.name)' will be saved here, preserving its structure."
        
        openPanel.begin { response in
            guard response == .OK, let directory = openPanel.url else { return }
            let destination = directory.appendingPathComponent(folder.name)
            Task {
                await downloadManager.downloadFolder(
                    devicePath: folder.path,
                    folderName: folder.name,
                    to: destination
                )
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

