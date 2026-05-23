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
    @State private var folderSizes: [String: UInt64] = [:]
    
    // File action manager
    @StateObject private var fileActionManager = FileActionManager()
    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Paste conflict alert
    @State private var showConflictAlert = false
    @State private var showGlobalResultAlert = false
    @State private var globalResultAlertMessage = ""
    
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
    @State private var sortAscending: Bool = true
    
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
            result.sort {
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .size:
            func effectiveSize(_ file: UnifiedFile) -> UInt64 {
                if file.isDirectory {
                    return folderSizes[file.path] ?? file.size
                }
                return file.size
            }
            result.sort {
                let lhsSize = effectiveSize($0)
                let rhsSize = effectiveSize($1)
                if lhsSize != rhsSize {
                    return sortAscending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .type:
            result.sort {
                let t0 = $0.sortableType
                let t1 = $1.sortableType
                if t0 != t1 { return sortAscending ? t0 < t1 : t0 > t1 }
                // Within same category, sort by name
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return sortAscending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .date:
            result.sort {
                let d0 = $0.modificationDate ?? Date.distantPast
                let d1 = $1.modificationDate ?? Date.distantPast
                return sortAscending ? d0 < d1 : d0 > d1
            }
        }
        
        return result
    }
    
    private func sortFiles(by option: ActionToolbar.SortOption, ascending: Bool = true) {
        sortOption = option
        sortAscending = ascending
    }

    private var globalOperationAccentColor: Color {
        let message = appManager.globalOperationMessage.lowercased()
        if message.contains("uninstall") || message.contains("delete") { return .red }
        if message.contains("install") { return .green }
        if message.contains("backup") || message.contains("download") { return .blue }
        if message.contains("disable") || message.contains("clear") { return .orange }
        return .secondary
    }

    var body: some View {
        contentWithPresentations
    }

    // Level 1: presentation modifiers (alerts + sheets + keyboard shortcuts)
    // Split from body to stay under Swift type-checker expression complexity limit
    private var contentWithPresentations: some View {
        contentWithAlerts
            .sheet(isPresented: $showTrashView) {
                TrashView(fileActionManager: fileActionManager, onStorageChanged: {
                    Task { 
                        await deviceManager.fetchStorageInfo() 
                        await loadFiles()
                    }
                })
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
                        await deviceManager.fetchStorageInfo()
                    }
                }
                Button("Keep Both") {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .keepBoth)
                        await loadFiles()
                        await deviceManager.fetchStorageInfo()
                    }
                }
                Button("Skip", role: .cancel) {
                    Task {
                        try? await fileActionManager.resumePaste(resolution: .skip)
                        await loadFiles()
                        await deviceManager.fetchStorageInfo()
                    }
                }
            } message: {
                Text(pasteConflictMessage)
            }
            .alert("Result", isPresented: $showGlobalResultAlert) {
                Button("OK", role: .cancel) {
                    appManager.globalResultMessage = nil
                }
            } message: {
                Text(globalResultAlertMessage)
            }
            .onChange(of: fileActionManager.pasteConflicts.count) { newCount in
                showConflictAlert = newCount > 0
            }
            .onChange(of: appManager.globalResultMessage) { newValue in
                guard let message = newValue, !message.isEmpty else { return }
                globalResultAlertMessage = message
                showGlobalResultAlert = true
            }
            .onChange(of: deviceManager.sdCardPath) { newPath in
                sidebarManager.updateSDCard(path: newPath)
            }
            .onChange(of: deviceManager.deviceName) { newName in
                // Reload the file browser whenever the active device changes.
                // deviceName is set at the end of detectDevice(), so this fires
                // once the switch is fully complete and the new serial is active.
                // This is the ONLY place that triggers loadFiles() on connection.
                guard deviceManager.isConnected, !newName.isEmpty, newName != "No Device" else { return }
                Task {
                    currentPath = await deviceManager.getRealStoragePath()
                    pathHistory.removeAll()
                    await loadFiles()
                }
            }
    }

    // Level 3: layout + input modifiers
    private var layoutContent: some View {
        VStack(spacing: 0) {
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
        .overlay(alignment: .topTrailing) {
            if updateChecker.shouldShowBanner {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                    Text("v\(updateChecker.latestVersion) available")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white)
                    
                    Button(action: { updateChecker.openReleasePage() }) {
                        Text("Update")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.white)
                            .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    
                    Button(action: { updateChecker.dismissForToday() }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.blue.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                )
                .padding(.top, 6)
                .padding(.trailing, 280) 
                .transition(.move(edge: .top).combined(with: .opacity))
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: updateChecker.shouldShowBanner)
                .zIndex(100)
            }
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
                    // Just detect — onChange(of: deviceManager.deviceName) will trigger loadFiles()
                    await deviceManager.detectDevice()
                }
            }
        }
    }

    // Extracted to keep `body` chain under Swift complexity limit
    @ViewBuilder
    private var connectedContent: some View {
        NavigationSplitView {
            SidebarView(
                sidebarManager: sidebarManager,
                currentPath: currentPath,
                onNavigate: { path in
                    activeAppFilter = nil
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if appManager.isGlobalOperationInProgress {
                    HStack(spacing: 8) {
                        if appManager.globalOperationShowsSpinner {
                            ProgressView()
                                .tint(globalOperationAccentColor)
                                .scaleEffect(0.65)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: appManager.globalOperationIsError ? "xmark.circle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(appManager.globalOperationIsError ? .red : .green)
                                .frame(width: 12, height: 12)
                        }
                        Text(appManager.globalOperationMessage)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(globalOperationAccentColor.opacity(0.08))
                    Divider()
                }

                ZStack {
                if let appFilter = activeAppFilter {
                    // ── App Browser ───────────────────────────────────────────
                    AppBrowserView(appManager: appManager, initialFilter: appFilter, deviceName: deviceManager.deviceName)
                        .transition(.opacity)
                } else {
                    // ── File Browser ──────────────────────────────────────────
                    VStack(spacing: 0) {
                        // Clipboard indicator (inline, above file list)
                        if fileActionManager.isPerformingAction {
                            HStack(spacing: 8) {
                                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                                Text(fileActionManager.currentAction)
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.12))
                            Divider()
                        } else if !fileActionManager.clipboard.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: fileActionManager.clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                                    .font(.system(size: 11))
                                    .foregroundColor(.blue)
                                Text("\(fileActionManager.clipboard.count) item\(fileActionManager.clipboard.count == 1 ? "" : "s") ready to paste")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    Task {
                                        do { try await fileActionManager.paste(to: currentPath) } catch {}
                                        await loadFiles()
                                    }
                                } label: {
                                    Label("Paste", systemImage: "doc.on.doc")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.borderless)
                                Button { fileActionManager.clearClipboard() } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary.opacity(0.6))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.08))
                            Divider()
                        }

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
                            onSortChange: { option, ascending in sortFiles(by: option, ascending: ascending) },
                            folderSizes: folderSizes
                        )
                    }
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
            }
            .navigationTitle(deviceManager.isConnected ? "Android File Sync" : "")
            .navigationSubtitle(deviceManager.statusMessage)
            .toolbar {
                // ── Left side: New Folder + New File ─────────────────────────
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        if activeAppFilter == nil,
                           let name = TextInputDialog.show(
                            title: "New Folder",
                            message: "Enter a name for the new folder",
                            placeholder: "Folder name",
                            initialValue: "New Folder",
                            confirmLabel: "Create"
                        ) {
                            Task {
                                do {
                                    try await fileActionManager.createFolder(at: currentPath, name: name)
                                    await loadFiles()
                                    await deviceManager.fetchStorageInfo()
                                } catch { print("Failed: \(error)") }
                            }
                        }
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .help("New Folder (⌘⇧N)")
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(activeAppFilter != nil)

                    Button {
                        if activeAppFilter == nil,
                           let name = TextInputDialog.show(
                            title: "New File",
                            message: "Enter a name for the new file",
                            placeholder: "File name",
                            initialValue: "untitled.txt",
                            confirmLabel: "Create"
                        ) {
                            Task {
                                do {
                                    try await fileActionManager.createFile(at: currentPath, name: name)
                                    await loadFiles()
                                    await deviceManager.fetchStorageInfo()
                                } catch { print("Failed: \(error)") }
                            }
                        }
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                    .help("New File")
                    .disabled(activeAppFilter != nil)
                }

                // ── Right side: Sort + Refresh + WiFi ────────────────────────
                ToolbarItemGroup(placement: .primaryAction) {
                    // Sort menu (only in file browser)
                    if activeAppFilter == nil {
                        Menu {
                            ForEach(ActionToolbar.SortOption.allCases, id: \.self) { opt in
                                Button {
                                    sortFiles(by: opt, ascending: sortOption == opt ? !sortAscending : true)
                                } label: {
                                    if sortOption == opt {
                                        Label(opt.rawValue, systemImage: sortAscending ? "chevron.up" : "chevron.down")
                                    } else {
                                        Text(opt.rawValue)
                                    }
                                }
                            }
                        } label: {
                            Label(sortOption.rawValue, systemImage: "arrow.up.arrow.down")
                        }
                        .help("Sort files")
                    }

                    Button {
                        Task { await loadFiles() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)

                    // Connection button — icon reflects current connection type
                    Button { showWirelessConnect = true } label: {
                        if deviceManager.connectionType == .wireless {
                            Label("WiFi", systemImage: "wifi")
                                .foregroundColor(.green)
                        } else if deviceManager.connectionType == .usb {
                            Label("USB", systemImage: "cable.connector")
                                .foregroundColor(.primary)
                        } else {
                            Label("WiFi", systemImage: "wifi")
                        }
                    }
                    .help(deviceManager.connectionType == .wireless
                          ? "Manage WiFi connection"
                          : deviceManager.connectionType == .usb
                            ? "Connected via USB — tap to manage connections"
                            : "Connect via WiFi")
                }

                // ── Status: transfer count ────────────────────────────────────
                if !downloadManager.activeDownloads.isEmpty || !uploadManager.activeUploads.isEmpty {
                    ToolbarItem(placement: .status) {
                        HStack(spacing: 6) {
                            if !downloadManager.activeDownloads.isEmpty {
                                Label("\(downloadManager.activeDownloads.count)", systemImage: "arrow.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.blue)
                            }
                            if !uploadManager.activeUploads.isEmpty {
                                Label("\(uploadManager.activeUploads.count)", systemImage: "arrow.up")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search files...")
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
                await deviceManager.fetchStorageInfo()
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
        // Start IOKit USB monitor FIRST — fires instantly on plug/unplug
        deviceManager.startMonitoring()
        
        await deviceManager.detectDevice()
        
        // Poll for USB cold-start ONLY when there are no saved wireless devices.
        // If saved wireless IPs exist, detectDevice() already kicked off a background
        // reconnect task with its own retry logic. Running both simultaneously causes
        // the polling loop to flash "No Device Connected" while the reconnect is in progress.
        let savedWirelessIPs = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
        if !deviceManager.isConnected && savedWirelessIPs.isEmpty {
            for _ in 1...10 {
                try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
                await deviceManager.detectDevice()
                if deviceManager.isConnected { break }
            }
        }
        
        // NOTE: We do NOT call loadFiles() here.
        // The .onChange(of: deviceManager.deviceName) observer fires whenever detectDevice()
        // sets a new device name, and it is the single source of truth for loading files.
        // Calling loadFiles() here too caused a race condition where files were loaded twice.
    }
    
    /// Refreshes the sidebar storage stats (Internal Storage bar) after a file operation
    private func refreshStorageStats() {
        Task { await deviceManager.fetchStorageInfo() }
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
        
        // Now that files are loaded, fetch SD card and storage info in the background.
        // Doing this here prevents ADB contention during the critical file loading phase!
        Task {
            await deviceManager.detectSDCard()
            await deviceManager.fetchStorageInfo()
        }
        
        // Fire-and-forget background folder sizing
        let pathSnapshot = currentPath
        let dirsSnapshot = newFiles.filter { $0.isDirectory }
        
        // If folderSizes is already populated, we're refreshing after an operation
        if !folderSizes.isEmpty {
            folderSizes = [:]
        }
        
        Task.detached(priority: .background) {
            await withTaskGroup(of: (String, UInt64?).self) { group in
                let maxConcurrent = 3
                var index = 0
                
                // Add initial tasks
                while index < min(maxConcurrent, dirsSnapshot.count) {
                    let dir = dirsSnapshot[index]
                    group.addTask { return (dir.path, await ADBManager.fetchSingleFolderSize(path: dir.path)) }
                    index += 1
                }
                
                // Process results and add more tasks
                for await (path, sizeOpt) in group {
                    if let size = sizeOpt {
                        await MainActor.run {
                            guard self.currentPath == pathSnapshot else { return }
                            self.folderSizes[path] = size
                        }
                    }
                    if index < dirsSnapshot.count {
                        let nextDir = dirsSnapshot[index]
                        group.addTask { return (nextDir.path, await ADBManager.fetchSingleFolderSize(path: nextDir.path)) }
                        index += 1
                    }
                }
            }
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
        folderSizes = [:]
        
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
        folderSizes = [:]
        
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
            ADBManager.invalidateFolderSizeCache()
            await loadFiles()
            await deviceManager.fetchStorageInfo()
        }
    }

    
    private func handleDelete(_ file: UnifiedFile) {
        Task {
            do {
                try await fileActionManager.deleteFile(file)
                
                // Invalidate cache and refresh
                ADBManager.invalidateFolderSizeCache()
                await loadFiles()
                await deviceManager.fetchStorageInfo()
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
                
                // Invalidate cache and refresh
                ADBManager.invalidateFolderSizeCache()
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
                ADBManager.invalidateFolderSizeCache()
                await loadFiles()
                await deviceManager.fetchStorageInfo()
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
                await deviceManager.fetchStorageInfo()
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
