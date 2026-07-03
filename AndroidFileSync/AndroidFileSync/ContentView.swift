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
    @ObservedObject var deviceManager: DeviceManager
    var downloadManager: DownloadManager
    var uploadManager: UploadManager
    
    @State private var activeDownloadsCount = 0
    @State private var activeUploadsCount = 0
    @State private var isDownloading = false
    @State private var isUploading = false
    
    @StateObject private var filePreviewManager = FilePreviewManager()
    @StateObject private var sidebarManager = SidebarManager()

    @State private var files: [UnifiedFile] = []
    @State private var currentPath = "/sdcard"
    @State private var pathHistory: [String] = []
    @State private var forwardHistory: [String] = []
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>? = nil
    @State private var folderSizes: [String: UInt64] = [:]
    /// Buffer for collecting folder sizes off the main render cycle.
    /// Flushed to `folderSizes` periodically to avoid per-folder re-renders.
    private var folderSizesBuffer: [String: UInt64] {
        get { _folderSizesBuffer }
        nonmutating set { _folderSizesBuffer = newValue }
    }
    @State private var _folderSizesBuffer: [String: UInt64] = [:]
    @State private var folderSizeFlushTask: Task<Void, Never>? = nil
    
    // Directory cache — stores last 10 visited directories for instant back-navigation
    @State private var directoryCache: [String: [UnifiedFile]] = [:]
    @State private var directoryCacheOrder: [String] = []  // LRU order tracking
    
    // Metadata enrichment tracking
    @State private var metadataTask: Task<Void, Never>? = nil
    @State private var isLoadingMetadata = false
    @State private var metadataLoadedCount = 0
    @State private var metadataTotalCount = 0
    
    // Progressive loading (paginated content:// fallback)
    @State private var isLoadingMoreFiles = false
    
    // File action manager
    @StateObject private var fileActionManager = FileActionManager()

    @State private var showErrorAlert = false
    @State private var errorMessage = ""
    
    // Paste conflict alert
    @State private var showConflictAlert = false
    @State private var showGlobalResultAlert = false
    @State private var globalResultAlertMessage = ""
    
    // Multi-selection state
    @State private var selectedFiles: Set<String> = []
    
    // Trash view state
    @State private var showTrashView = false
    @State private var showWirelessConnect = false
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var supportPromptManager = SupportPromptManager.shared
    @ObservedObject private var diagnosticsControl = DiagnosticsControl.shared

    // Get Info panel state (⌘I)
    @State private var infoFile: UnifiedFile? = nil
    @State private var fileInfoData: [String: String] = [:]
    @State private var isLoadingFileInfo = false
    @State private var fileInfoTask: Task<Void, Never>? = nil

    // Permanent delete confirmation (⌘⌥⌫)
    @State private var showPermanentDeleteConfirmation = false
    @State private var permanentDeleteCount = 0

    // Move to Trash confirmation (⌘⌫)
    @State private var showTrashConfirmation = false
    @State private var trashConfirmCount = 0


    @State private var showReportIssuePopover = false

    // App browser state
    @StateObject private var appManager = AppManager()
    @State private var activeAppFilter: AppFilter? = nil
    @State private var showOperationDetails = false
    
    // Search and sort state
    @State private var searchQuery = ""
    @State private var sortOption: ActionToolbar.SortOption = .name
    @State private var sortAscending: Bool = true
    
    // Filtered and sorted files for display.
    @State private var displayedFiles: [UnifiedFile] = []
    
    // Monotonically increasing version — incremented ONLY when sort parameters change
    // (not on every data refresh). Used by FileBrowserView Equatable to detect re-sorts.
    @State private var sortVersion: Int = 0
    
    /// Recompute the displayed (filtered + sorted) file list.
    private func updateDisplayedFiles() {
        var result = files
        
        // Apply search filter
        if !searchQuery.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
        }
        
        // Apply sort
        let ascending = sortAscending
        let sizes = folderSizes
        switch sortOption {
        case .name:
            result.sort {
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .size:
            result.sort {
                let lhsSize = $0.isDirectory ? (sizes[$0.path] ?? $0.size) : $0.size
                let rhsSize = $1.isDirectory ? (sizes[$1.path] ?? $1.size) : $1.size
                if lhsSize != rhsSize {
                    return ascending ? lhsSize < rhsSize : lhsSize > rhsSize
                }
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .type:
            result.sort {
                let t0 = $0.sortableType
                let t1 = $1.sortableType
                if t0 != t1 { return ascending ? t0 < t1 : t0 > t1 }
                let cmp = $0.name.localizedCaseInsensitiveCompare($1.name)
                return ascending ? cmp == .orderedAscending : cmp == .orderedDescending
            }
        case .date:
            result.sort {
                let d0 = $0.modificationDate ?? Date.distantPast
                let d1 = $1.modificationDate ?? Date.distantPast
                return ascending ? d0 < d1 : d0 > d1
            }
        }
        
        displayedFiles = result
        print("🔄 [SORT] updateDisplayedFiles — \(result.count) files, sort: \(sortOption.rawValue) \(ascending ? "ASC" : "DESC"), ver: \(sortVersion)")
    }
    
    /// Called when the user changes sort (via column header or toolbar menu).
    /// Increments sortVersion to force FileBrowserView re-render.
    private func sortFiles(by option: ActionToolbar.SortOption, ascending: Bool = true) {
        print("🔄 [SORT] sortFiles() — \(option.rawValue) \(ascending ? "ASC" : "DESC") (was: \(sortOption.rawValue) \(sortAscending ? "ASC" : "DESC"))")
        sortOption = option
        sortAscending = ascending
        sortVersion += 1  // Always bump — guarantees Equatable detects the change
        updateDisplayedFiles()
    }

    private var isAnyOperationActive: Bool {
        appManager.operationEngine.isBusy ||
        uploadManager.isBatchUploading ||
        downloadManager.isBatchDownloading ||
        !uploadManager.activeUploads.isEmpty ||
        !downloadManager.activeDownloads.isEmpty ||
        uploadManager.isPreparing ||
        downloadManager.isScanning
    }

    private var unifiedStatusText: String {
        let activeGroups = appManager.operationEngine.activeGroups
        let hasAppOps = !activeGroups.isEmpty
        
        let uploadsCount = uploadManager.activeUploads.count
        let downloadsCount = downloadManager.activeDownloads.count
        let hasTransfers = uploadsCount > 0 || downloadsCount > 0
        
        if hasAppOps && hasTransfers {
            let appVerb = activeGroups.first?.actionVerb ?? "Processing"
            let appCount = activeGroups.count
            let transferText = uploadsCount > 0 ? "\(uploadsCount) upload\(uploadsCount > 1 ? "s" : "")" : "\(downloadsCount) download\(downloadsCount > 1 ? "s" : "")"
            return "\(appVerb) apps (\(appCount) active) • Copying files (\(transferText))"
        } else if hasAppOps {
            let isMultiGroup = activeGroups.count > 1
            let group = activeGroups.first
            let completed = group?.completedCount ?? 0
            let total = group?.totalCount ?? 0
            let verb = group?.actionVerb ?? "Processing"
            let currentApp = group?.currentRunningName ?? ""
            
            if isMultiGroup {
                return "Multiple operations executing... (\(activeGroups.count) active)"
            } else if total > 1 {
                return "\(verb) apps... \(completed + 1) of \(total) (\(currentApp))"
            } else {
                return "\(verb) \(currentApp)…"
            }
        } else if hasTransfers {
            if uploadManager.isPreparing {
                return uploadManager.preparingMessage
            }
            if downloadManager.isScanning {
                return "Scanning \(downloadManager.scanningFolderName)..."
            }
            
            let uploads = uploadsCount > 0 ? "\(uploadsCount) upload\(uploadsCount > 1 ? "s" : "")" : ""
            let downloads = downloadsCount > 0 ? "\(downloadsCount) download\(downloadsCount > 1 ? "s" : "")" : ""
            let parts = [uploads, downloads].filter { !$0.isEmpty }
            return "Copying files... " + parts.joined(separator: ", ")
        }
        
        return ""
    }

    private var unifiedProgressFraction: Double {
        let activeGroups = appManager.operationEngine.activeGroups
        let totalOps = activeGroups.reduce(0) { $0 + $1.totalCount }
        let completedOps = activeGroups.reduce(0) { $0 + $1.completedCount }
        let opFraction = totalOps > 0 ? Double(completedOps) / Double(totalOps) : 0.0
        
        let uploadTotal = uploadManager.batchTotal
        let uploadCompleted = uploadManager.batchCompleted
        let uploadFraction = uploadTotal > 0 ? Double(uploadCompleted) / Double(uploadTotal) : 0.0
        
        let downloadTotal = downloadManager.batchTotal
        let downloadCompleted = downloadManager.batchCompleted
        let downloadFraction = downloadTotal > 0 ? Double(downloadCompleted) / Double(downloadTotal) : 0.0
        
        var totalFractions: [Double] = []
        if totalOps > 0 { totalFractions.append(opFraction) }
        
        if uploadTotal > 0 {
            totalFractions.append(uploadFraction)
        } else if !uploadManager.activeUploads.isEmpty {
            let sum = uploadManager.activeUploads.values.reduce(0.0) { $0 + $1.progress }
            totalFractions.append(sum / Double(uploadManager.activeUploads.count))
        }
        
        if downloadTotal > 0 {
            totalFractions.append(downloadFraction)
        } else if !downloadManager.activeDownloads.isEmpty {
            let sum = downloadManager.activeDownloads.values.reduce(0.0) { $0 + $1.progress }
            totalFractions.append(sum / Double(downloadManager.activeDownloads.count))
        }
        
        return totalFractions.isEmpty ? 0.0 : totalFractions.reduce(0.0, +) / Double(totalFractions.count)
    }

    private var unifiedStatusColor: Color {
        let activeGroups = appManager.operationEngine.activeGroups
        if !activeGroups.isEmpty {
            return activeGroups.first?.color ?? .blue
        }
        return .blue
    }

    @ViewBuilder
    private var unifiedStatusBanner: some View {
        if isAnyOperationActive {
            let color = unifiedStatusColor
            let fraction = unifiedProgressFraction
            let statusText = unifiedStatusText
            
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                    
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Button {
                        showOperationDetails.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Text("Details")
                            Image(systemName: showOperationDetails ? "chevron.up" : "chevron.down")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .popover(isPresented: $showOperationDetails, arrowEdge: .bottom) {
                        unifiedDetailsPopoverView
                    }
                    
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(color)
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 6)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(color.opacity(0.15))
                            .frame(height: 3)
                        Rectangle()
                            .fill(color)
                            .frame(width: geo.size.width * fraction, height: 3)
                            .animation(.linear(duration: 0.3), value: fraction)
                    }
                }
                .frame(height: 3)
                Divider()
            }
            .background(color.opacity(0.08))
        }
    }

    private var unifiedDetailsPopoverView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Tasks")
                .font(.system(size: 13, weight: .bold))
                .padding(.bottom, 4)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let activeGroups = appManager.operationEngine.activeGroups
                    if !activeGroups.isEmpty {
                        Text("App Operations")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ForEach(activeGroups, id: \OperationEngine.OperationGroup.id) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(group.actionVerb)
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text("\(group.completedCount)/\(group.totalCount)")
                                        .font(.system(size: 10, design: .monospaced))
                                    
                                    Button {
                                        appManager.operationEngine.cancelPending(in: group.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                let fraction = group.totalCount > 0 ? Double(group.completedCount) / Double(group.totalCount) : 0.0
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(group.color.opacity(0.2))
                                        .frame(height: 4)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(group.color)
                                                .frame(width: geo.size.width * fraction)
                                        }
                                }
                                .frame(height: 4)
                                
                                ForEach(group.operations, id: \OperationEngine.LiveOperation.id) { op in
                                    LiveOperationRow(op: op)
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        Divider()
                    }
                    
                    let uploads = uploadManager.activeUploads.values
                    let downloads = downloadManager.activeDownloads.values
                    if !uploads.isEmpty || !downloads.isEmpty {
                        Text("File Transfers")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        
                        ForEach(Array(uploads)) { upload in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundColor(.blue)
                                    Text(upload.fileName)
                                        .font(.system(size: 11))
                                    Spacer()
                                    Text(upload.speedText)
                                        .font(.system(size: 10))
                                    
                                    Button {
                                        uploadManager.cancelUpload(localPath: upload.localPath)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(height: 4)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.blue)
                                                .frame(width: geo.size.width * upload.progress)
                                        }
                                }
                                .frame(height: 4)
                            }
                        }
                        
                        ForEach(Array(downloads)) { download in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundColor(.blue)
                                    Text(download.fileName)
                                        .font(.system(size: 11))
                                    Spacer()
                                    Text(download.speedText)
                                        .font(.system(size: 10))
                                    
                                    Button {
                                        downloadManager.cancelDownload(devicePath: download.devicePath)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                }
                                
                                GeometryReader { geo in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.2))
                                        .frame(height: 4)
                                        .overlay(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.blue)
                                                .frame(width: geo.size.width * download.progress)
                                        }
                                }
                                .frame(height: 4)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 250)
            
            Button(role: .destructive) {
                appManager.operationEngine.cancelAllPending()
                uploadManager.cancelAllUploads()
                downloadManager.cancelAllDownloads()
                showOperationDetails = false
            } label: {
                Text("Cancel All Active Tasks")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 280)
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
                    // ── Clipboard shortcuts ────────────────────────────────
                    Button("") { handleGlobalCopy() }.keyboardShortcut("c", modifiers: .command)
                    Button("") { handleGlobalCut() }.keyboardShortcut("x", modifiers: .command)
                    Button("") { handleGlobalPaste() }.keyboardShortcut("v", modifiers: .command)
                    
                    // ── Delete shortcuts (moved here for reliability) ─────
                    Button("") { handleDeleteShortcut() }.keyboardShortcut(.delete, modifiers: .command)
                    Button("") { handlePermanentDeleteShortcut() }.keyboardShortcut(.delete, modifiers: [.command, .option])

                    // ── Finder-style navigation ───────────────────────────
                    Button("") { handleDeselectAll() }.keyboardShortcut("a", modifiers: [.command, .shift])
                    Button("") { handleNavigateUp() }.keyboardShortcut(.upArrow, modifiers: .command)
                    Button("") { handleOpenSelected() }.keyboardShortcut(.downArrow, modifiers: .command)
                    Button("") { navigateBack() }.keyboardShortcut("[", modifiers: .command)
                    Button("") { navigateForward() }.keyboardShortcut("]", modifiers: .command)

                    // ── File actions ──────────────────────────────────────
                    Button("") { handleGetInfo() }.keyboardShortcut("i", modifiers: .command)
                    Button("") { handleRenameShortcut() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    Button("") { handleQuickPreview() }.keyboardShortcut(.space, modifiers: [])
                }
                .hidden()
            )
            .onReceive(NotificationCenter.default.publisher(for: .afsDeleteShortcut)) { _ in
                handleDeleteShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsPermanentDeleteShortcut)) { _ in
                handlePermanentDeleteShortcut()
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDeletionsChanged)) { _ in
                Task {
                    ADBManager.invalidateFolderSizeCache()
                    await loadFiles()
                    await deviceManager.fetchStorageInfo()
                }
            }
            .sheet(item: $infoFile, onDismiss: {
                fileInfoTask?.cancel()
                fileInfoTask = nil
                fileInfoData = [:]
                isLoadingFileInfo = false
            }) { file in
                FileInfoView(file: file, info: fileInfoData, isLoading: isLoadingFileInfo)
            }
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
            .alert("Is AndroidFileSync helping you?", isPresented: $supportPromptManager.shouldShowPrompt) {
                Button("Star on GitHub") {
                    supportPromptManager.openGitHubAndMarkDone()
                }
                Button("Send Feedback") {
                    supportPromptManager.openFeedbackAndSnooze()
                }
                Button("Not Now", role: .cancel) {
                    supportPromptManager.snooze()
                }
            } message: {
                Text("If the app saved you time, a GitHub star helps other users find it. If something can be better, feedback is welcome too.")
            }
            .alert("Result", isPresented: $showGlobalResultAlert) {
                Button("OK", role: .cancel) {
                    appManager.globalResultMessage = nil
                }
            } message: {
                Text(globalResultAlertMessage)
            }
            .alert("Permanently Delete \(permanentDeleteCount) item\(permanentDeleteCount == 1 ? "" : "s")?", isPresented: $showPermanentDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    permanentDeleteCount = 0
                }
                Button("Delete Permanently", role: .destructive) {
                    handlePermanentDelete()
                    permanentDeleteCount = 0
                }
            } message: {
                Text("This cannot be undone. The item\(permanentDeleteCount == 1 ? " will" : "s will") be permanently removed from the device.")
            }
            .alert("Move \(trashConfirmCount) item\(trashConfirmCount == 1 ? "" : "s") to Trash?", isPresented: $showTrashConfirmation) {
                Button("Cancel", role: .cancel) {
                    trashConfirmCount = 0
                }
                Button("Move to Trash", role: .destructive) {
                    executeTrashShortcut()
                    trashConfirmCount = 0
                }
            } message: {
                Text("You can restore \(trashConfirmCount == 1 ? "this item" : "these items") from the Trash.")
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
                guard deviceManager.isConnected, !newName.isEmpty, newName != "No Device" else { return }
                Task {
                    currentPath = await deviceManager.getRealStoragePath()
                    pathHistory.removeAll()
                    forwardHistory.removeAll()
                    await loadFiles()
                }
            }
            .onChange(of: deviceManager.isConnected) { connected in
                if !connected {
                    // Immediately clear file browser state on disconnect
                    loadTask?.cancel()
                    metadataTask?.cancel()
                    metadataTask = nil
                    folderSizeFlushTask?.cancel()
                    folderSizeFlushTask = nil
                    files = []
                    displayedFiles = []
                    selectedFiles.removeAll()
                    folderSizes = [:]
                    _folderSizesBuffer = [:]
                    isLoading = false
                    isLoadingMetadata = false
                } else {
                    // Reconnected! Reload files to restore list from empty state
                    Task {
                        await loadFiles()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsTransferCountChanged)) { notification in
                if let type = notification.userInfo?["type"] as? String,
                   let count = notification.userInfo?["count"] as? Int {
                    if type == "download" {
                        self.activeDownloadsCount = count
                    } else if type == "upload" {
                        self.activeUploadsCount = count
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDownloadBatchCompleted)) { notification in
                if let completed = notification.userInfo?["completed"] as? Int,
                   let total = notification.userInfo?["total"] as? Int {
                    guard completed > 0, completed == total else { return }
                    supportPromptManager.recordSuccessfulBatch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsUploadBatchCompleted)) { notification in
                if let completed = notification.userInfo?["completed"] as? Int,
                   let total = notification.userInfo?["total"] as? Int {
                    guard completed > 0, completed == total else { return }
                    supportPromptManager.recordSuccessfulBatch()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsUploadBatchStateChanged)) { notification in
                if let isUploading = notification.userInfo?["isUploading"] as? Bool,
                   let batchTotal = notification.userInfo?["batchTotal"] as? Int {
                    let oldUploading = self.isUploading
                    self.isUploading = isUploading
                    deviceManager.isTransferActive = isUploading || self.isDownloading
                    if !isUploading && oldUploading && batchTotal > 0 {
                        Task {
                            ADBManager.invalidateFolderSizeCache()
                            await loadFiles()
                            await deviceManager.fetchStorageInfo()
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .afsDownloadBatchStateChanged)) { notification in
                if let isDownloading = notification.userInfo?["isDownloading"] as? Bool,
                   let batchTotal = notification.userInfo?["batchTotal"] as? Int {
                    let oldDownloading = self.isDownloading
                    self.isDownloading = isDownloading
                    deviceManager.isTransferActive = self.isUploading || isDownloading
                    if !isDownloading && oldDownloading && batchTotal > 0 {
                        Task {
                            await loadFiles()
                            await deviceManager.fetchStorageInfo()
                        }
                    }
                }
            }
            .onChange(of: diagnosticsControl.isEnabled) { enabled in
                deviceManager.setDiagnosticsEnabled(enabled)
            }
            // ── displayedFiles sync ─────────────────────────────────
            // Rebuild the sorted/filtered list when data or search changes.
            .onChange(of: files) { _ in updateDisplayedFiles() }
            .onChange(of: searchQuery) { _ in updateDisplayedFiles() }
            .onChange(of: folderSizes) { _ in
                if sortOption == .size {
                    updateDisplayedFiles()
                }
            }

    }

    // Level 3: layout + input modifiers
    private var layoutContent: some View {
        VStack(spacing: 0) {
            if deviceManager.isConnected {
                connectedContent
            } else {
                let showCustomMessage = !deviceManager.availableDevices.isEmpty
                EmptyStateView(
                    isDetecting: deviceManager.isDetecting,
                    customMessage: showCustomMessage ? deviceManager.statusMessage : nil,
                    onRetry: { Task { await initializeDevice() } },
                    onConnectWiFi: { showWirelessConnect = true }
                )
            }

            if !isAnyOperationActive {
                TransferProgressContainer(
                    downloadManager: downloadManager,
                    uploadManager: uploadManager,
                    deviceManager: deviceManager
                )
            }
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
            deviceManager.setDiagnosticsEnabled(diagnosticsControl.isEnabled)
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
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !deviceManager.isConnected && !deviceManager.isDetecting {
                Task {
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
                unifiedStatusBanner

                ZStack {
                if let appFilter = activeAppFilter {
                    // ── App Browser ───────────────────────────────────────────
                    AppBrowserView(appManager: appManager, initialFilter: appFilter, deviceName: deviceManager.deviceName)
                        .transition(.opacity)
                } else {
                    // ── File Browser ──────────────────────────────────────────
                    VStack(spacing: 0) {
                        FileBrowserView(
                            files: displayedFiles,
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
                            isPerformingAction: fileActionManager.isPerformingAction,
                            currentActionText: fileActionManager.currentAction,
                            onCancelAction: { fileActionManager.requestCancellation() },
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
                            clipboardCount: fileActionManager.clipboard.count,
                            clipboardOperation: fileActionManager.clipboardOperation,
                            onPaste: {
                                Task {
                                    do { try await fileActionManager.paste(to: currentPath) } catch {}
                                    await loadFiles()
                                }
                            },
                            onClearClipboard: { fileActionManager.clearClipboard() },
                            activeDeletions: fileActionManager.activeDeletions,
                            onCancelDeletion: { id in fileActionManager.cancelDeletion(id: id) },
                            onCancelAllDeletions: { fileActionManager.cancelAllDeletions() },
                            sortOption: sortOption,
                            sortAscending: sortAscending,
                            sortVersion: sortVersion,
                            onSortChange: { option, ascending in sortFiles(by: option, ascending: ascending) },
                            folderSizes: folderSizes,
                            isLoadingMetadata: isLoadingMetadata,
                            metadataLoadedCount: metadataLoadedCount,
                            metadataTotalCount: metadataTotalCount,
                            isLoadingMoreFiles: isLoadingMoreFiles
                        )
                        .equatable()
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
            .navigationTitle(deviceManager.isConnected ? "AndroidFileSync" : "")
            .navigationSubtitle(customSubtitle)
            .toolbar {
                // ── Left side: New Folder + New File ─────────────────────────
                ToolbarItemGroup(placement: .automatic) {
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

                    Button { showReportIssuePopover = true } label: {
                        Label("Report Issue", systemImage: "exclamationmark.bubble")
                    }
                    .help("Report an issue")
                    .popover(isPresented: $showReportIssuePopover, arrowEdge: .bottom) {
                        ReportIssuePopoverView(diagnosticsControl: diagnosticsControl)
                    }

                }
            }
            .searchable(text: $searchQuery, placement: .toolbar, prompt: "Search files...")
            }
        }
    }

        // MARK: - Computed Properties for Alerts
    
    private var customSubtitle: String {
        var status = deviceManager.statusMessage
        
        if deviceManager.isConnected {
            let downloadsCount = activeDownloadsCount
            let uploadsCount = activeUploadsCount
            
            var transfers: [String] = []
            if downloadsCount > 0 {
                transfers.append("\(downloadsCount) download\(downloadsCount > 1 ? "s" : "")")
            }
            if uploadsCount > 0 {
                transfers.append("\(uploadsCount) upload\(uploadsCount > 1 ? "s" : "")")
            }
            
            if !transfers.isEmpty {
                status += " • " + transfers.joined(separator: ", ")
            }
        }
        
        return status
    }
    
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

    // MARK: - Keyboard Shortcut Handlers
    
    private func handleDeselectAll() {
        guard activeAppFilter == nil else { return }
        selectedFiles.removeAll()
    }
    
    private func handleNavigateUp() {
        guard activeAppFilter == nil else { return }
        // Navigate to the parent directory of currentPath
        let parent = (currentPath as NSString).deletingLastPathComponent
        // Don't go above root
        guard !parent.isEmpty, parent != currentPath else { return }
        navigateTo(parent)
    }
    
    private func handleOpenSelected() {
        guard activeAppFilter == nil else { return }
        // Open the first selected item (same as double-click)
        guard let firstId = selectedFiles.first,
              let file = files.first(where: { $0.id == firstId }) else { return }
        
        if file.isDirectory {
            navigateTo(file.path)
        } else if FilePreviewManager.isPreviewable(file) {
            filePreviewManager.previewFile(file)
        } else {
            handleDownload(file: file)
        }
    }
    
    private func handleDeleteShortcut() {
        guard activeAppFilter == nil else { return }
        let items = files.filter { selectedFiles.contains($0.id) }
        guard !items.isEmpty else { return }
        
        // Single file (not folder) → delete immediately without confirmation
        if items.count == 1, let file = items.first, !file.isDirectory {
            handleDelete(file)
            return
        }
        
        // Folder or multiple items → show confirmation
        trashConfirmCount = items.count
        showTrashConfirmation = true
    }
    
    /// Actually performs the trash operation after user confirms
    private func executeTrashShortcut() {
        let items = files.filter { selectedFiles.contains($0.id) }
        guard !items.isEmpty else { return }
        
        if items.count == 1 {
            handleDelete(items.first!)
        } else {
            handleBatchDelete()
        }
    }
    
    private func handlePermanentDeleteShortcut() {
        guard activeAppFilter == nil else { return }
        let items = files.filter { selectedFiles.contains($0.id) }
        guard !items.isEmpty else { return }
        permanentDeleteCount = items.count
        showPermanentDeleteConfirmation = true
    }
    
    private func handleRenameShortcut() {
        guard activeAppFilter == nil else { return }
        // Only rename when exactly one item is selected
        guard selectedFiles.count == 1,
              let fileId = selectedFiles.first,
              let file = files.first(where: { $0.id == fileId }) else { return }
        
        let kind = file.isDirectory ? "Folder" : "File"
        if let newName = TextInputDialog.show(
            title: "Rename \(kind)",
            message: "Enter a new name for \"\(file.name)\"",
            placeholder: file.name,
            initialValue: file.name,
            confirmLabel: "Rename"
        ), newName != file.name {
            handleRename(file, newName: newName)
        }
    }
    
    private func handleQuickPreview() {
        guard activeAppFilter == nil else { return }
        guard selectedFiles.count == 1,
              let fileId = selectedFiles.first,
              let file = files.first(where: { $0.id == fileId }),
              !file.isDirectory,
              FilePreviewManager.isPreviewable(file) else { return }
        
        filePreviewManager.previewFile(file)
    }
    
    private func handleGetInfo() {
        guard activeAppFilter == nil else { return }
        guard selectedFiles.count == 1,
              let fileId = selectedFiles.first,
              let file = files.first(where: { $0.id == fileId }) else { return }
        
        fileInfoTask?.cancel()
        fileInfoTask = nil

        fileInfoData = [:]
        isLoadingFileInfo = true
        infoFile = file

        let selectedFileID = file.id
        fileInfoTask = Task {
            do {
                let info = try await ADBManager.getFileInfo(path: file.path, isDirectory: file.isDirectory)
                await MainActor.run {
                    guard infoFile?.id == selectedFileID else { return }
                    fileInfoData = info
                    isLoadingFileInfo = false
                }
            } catch {
                await MainActor.run {
                    guard infoFile?.id == selectedFileID else { return }
                    isLoadingFileInfo = false
                }
            }
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
        AppLogger.log("📂 [loadFiles] Request to load directory: \(currentPath) (connection: \(deviceManager.connectionType.rawValue))")
        // Check if cancelled early
        guard !Task.isCancelled else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled before starting (user navigated away?)")
            return
        }
        
        // Cancel any in-progress metadata loading
        metadataTask?.cancel()
        metadataTask = nil
        
        // Pause download progress updates to avoid ADB contention
        await MainActor.run {
            downloadManager.pauseUpdates()
            isLoading = true
            isLoadingMetadata = false
            metadataLoadedCount = 0
            metadataTotalCount = 0
        }
        
        // Invalidate the ADB-level folder size cache so stale sizes are never shown
        // (e.g., after paste/delete operations change folder contents)
        ADBManager.invalidateFolderSizeCache()
        
        // Check again before expensive operation
        guard !Task.isCancelled else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled before listFiles call (user navigated away?)")
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Do the expensive work completely off main thread
        var newFiles: [UnifiedFile]
        var receivedProgressiveUpdates = false
        let pathSnapshot = currentPath
        do {
            newFiles = try await deviceManager.listFiles(path: currentPath) { pageFiles in
                // This callback fires for each page of content:// pagination results.
                // Append to UI immediately so user can start browsing while more pages load.
                receivedProgressiveUpdates = true
                Task { @MainActor in
                    guard self.currentPath == pathSnapshot else { return }
                    self.files.append(contentsOf: pageFiles)
                    if self.isLoading {
                        // First page arrived — stop spinner, show subtle "loading more" indicator
                        self.isLoading = false
                        self.isLoadingMoreFiles = true
                    }
                }
            }
        } catch {
            AppLogger.log("❌ [loadFiles] listFiles threw error: \(error.localizedDescription)", level: .error)
            // Restore loading state and keep the existing file list intact instead of clearing it
            await MainActor.run {
                isLoading = false
                isLoadingMoreFiles = false
                downloadManager.resumeUpdates()
            }
            return
        }
        AppLogger.log("📂 [loadFiles] Finished fetching files. Count: \(newFiles.count)\(receivedProgressiveUpdates ? " (progressive mode)" : "")")
        
        // Check before updating UI
        guard !Task.isCancelled else {
            AppLogger.log("⚠️ [loadFiles] Task cancelled AFTER fetching \(newFiles.count) files — results DISCARDED (user navigated away?)")
            await MainActor.run {
                isLoading = false
                downloadManager.resumeUpdates()
            }
            return
        }
        
        // Quick, simple update without animation
        await MainActor.run {
            // In progressive mode, files were already added via callback during pagination.
            // The final newFiles array has stat-enriched metadata — replace to upgrade placeholders.
            // In normal mode (ls worked), this is the first and only update.
            self.files = newFiles
            isLoading = false
            isLoadingMoreFiles = false
            downloadManager.resumeUpdates()  // Resume progress updates
            // Cache the directory listing
            cacheDirectory(path: pathSnapshot, files: newFiles)
        }
        if newFiles.isEmpty {
            AppLogger.log("⚠️ [loadFiles] ❗ UI set to EMPTY file list for path: \(pathSnapshot)")
        } else {
            AppLogger.log("📂 [loadFiles] ✅ UI updated with \(newFiles.count) files for path: \(pathSnapshot)")
        }


        
        // Now that files are loaded, fetch SD card and storage info in the background.
        // Doing this here prevents ADB contention during the critical file loading phase!
        Task {
            await deviceManager.detectSDCard()
            await deviceManager.fetchStorageInfo()
        }
        
        // ── Background metadata enrichment for large directories ────────────
        // Find files that came back without metadata (size == 0 and no date = placeholder)
        let filesNeedingMetadata = newFiles.filter { !$0.isDirectory && $0.size == 0 && $0.modificationDate == nil }
        if !filesNeedingMetadata.isEmpty {
            let fileNamesNeedingMeta = filesNeedingMetadata.map { $0.name }
            await MainActor.run {
                isLoadingMetadata = true
                metadataTotalCount = fileNamesNeedingMeta.count
                metadataLoadedCount = 0
            }
            
            metadataTask = Task.detached(priority: .utility) {
                await ADBManager.fetchMetadataBatched(
                    path: pathSnapshot,
                    fileNames: fileNamesNeedingMeta
                ) { batchFiles in
                    // Build a lookup dict from the batch results
                    let batchDict = Dictionary(batchFiles.map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
                    
                    Task { @MainActor in
                        guard self.currentPath == pathSnapshot else { return }
                        
                        // Update existing files array in-place
                        var updatedFiles = self.files
                        for i in updatedFiles.indices {
                            if let updated = batchDict[updatedFiles[i].name] {
                                updatedFiles[i] = UnifiedFile(
                                    name: updated.name,
                                    path: updated.path,
                                    isDirectory: updated.isDirectory,
                                    size: updated.size,
                                    modificationDate: updated.modificationDate
                                )
                            }
                        }
                        self.files = updatedFiles
                        self.metadataLoadedCount += batchFiles.count
                        
                        // Update cache with enriched data
                        self.cacheDirectory(path: pathSnapshot, files: updatedFiles)
                    }
                }
                
                // Mark metadata loading complete
                await MainActor.run {
                    guard self.currentPath == pathSnapshot else { return }
                    self.isLoadingMetadata = false
                }
            }
        }
        
        // Fire-and-forget background folder sizing
        let dirsSnapshot = newFiles.filter { $0.isDirectory }
        
        // If folderSizes is already populated, we're refreshing after an operation
        if !folderSizes.isEmpty {
            folderSizes = [:]
        }
        _folderSizesBuffer = [:]
        folderSizeFlushTask?.cancel()
        
        Task.detached(priority: .background) {
            // Accumulate sizes in a local dict, flush to @State periodically
            var localBuffer: [String: UInt64] = [:]
            var lastFlush = Date()
            let flushInterval: TimeInterval = 0.5  // 500ms debounce
            
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
                        localBuffer[path] = size
                    }
                    
                    // Flush to UI if enough time has passed
                    let now = Date()
                    if now.timeIntervalSince(lastFlush) >= flushInterval {
                        let batch = localBuffer
                        localBuffer = [:]
                        lastFlush = now
                        await MainActor.run {
                            guard self.currentPath == pathSnapshot else { return }
                            self.folderSizes.merge(batch) { _, new in new }
                        }
                    }
                    
                    if index < dirsSnapshot.count {
                        let nextDir = dirsSnapshot[index]
                        group.addTask { return (nextDir.path, await ADBManager.fetchSingleFolderSize(path: nextDir.path)) }
                        index += 1
                    }
                }
            }
            
            // Final flush — any remaining sizes
            if !localBuffer.isEmpty {
                let remaining = localBuffer
                await MainActor.run {
                    guard self.currentPath == pathSnapshot else { return }
                    self.folderSizes.merge(remaining) { _, new in new }
                }
            }
        }
    }

    private func navigateTo(_ path: String) {
        // Cancel any in-progress load and metadata enrichment
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        
        // Clear selection — navigating to a new folder means different files.
        selectedFiles.removeAll()
        
        pathHistory.append(currentPath)
        forwardHistory.removeAll()  // new navigation branch — clear forward stack
        currentPath = path
        isLoading = true
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        loadTask = Task.detached(priority: .userInitiated) {
            await self.loadFiles()
        }
    }

    private func navigateBack() {
        guard let previousPath = pathHistory.popLast() else { return }
        
        // Push current path to forward history so ⌘] can return here
        forwardHistory.append(currentPath)
        
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        
        // Clear selection on back navigation for the same reason.
        selectedFiles.removeAll()
        
        currentPath = previousPath
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        // Try to use cached data for instant back-navigation
        if let cachedFiles = directoryCache[previousPath] {
            // Show cached data immediately — no loading spinner
            files = cachedFiles
            isLoading = false
            
            // Silently refresh in background
            loadTask = Task.detached(priority: .utility) {
                await self.loadFiles()
            }
        } else {
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                await self.loadFiles()
            }
        }
    }

    private func navigateForward() {
        guard let nextPath = forwardHistory.popLast() else { return }
        
        loadTask?.cancel()
        metadataTask?.cancel()
        metadataTask = nil
        selectedFiles.removeAll()
        
        // Push current path to back history
        pathHistory.append(currentPath)
        currentPath = nextPath
        isLoadingMetadata = false
        isLoadingMoreFiles = false
        folderSizes = [:]
        
        // Try to use cached data for instant navigation
        if let cachedFiles = directoryCache[nextPath] {
            files = cachedFiles
            isLoading = false
            loadTask = Task.detached(priority: .utility) {
                await self.loadFiles()
            }
        } else {
            isLoading = true
            loadTask = Task.detached(priority: .userInitiated) {
                await self.loadFiles()
            }
        }
    }
    
    // MARK: - Diagnostic Upload Helpers



    // MARK: - Directory Cache Helpers
    
    private func cacheDirectory(path: String, files: [UnifiedFile]) {
        // Remove existing entry from order tracking if it exists
        directoryCacheOrder.removeAll { $0 == path }
        
        // Add to end (most recent)
        directoryCacheOrder.append(path)
        directoryCache[path] = files
        
        // Evict oldest entries if cache exceeds 10
        while directoryCacheOrder.count > 10 {
            let oldest = directoryCacheOrder.removeFirst()
            directoryCache.removeValue(forKey: oldest)
        }
    }
    
    private func invalidateCache(for path: String) {
        directoryCache.removeValue(forKey: path)
        directoryCacheOrder.removeAll { $0 == path }
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

        // Show immediate feedback so the user doesn't stare at a blank screen
        Task { @MainActor in
            manager.isPreparing = true
            manager.preparingMessage = "Preparing upload…"
        }

        Task {
            AppLogger.log("📂 [handleUpload] Starting upload for \(urls.count) URLs. Target destination path: \(path)")
            var allItems: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)] = []
            var remoteDirsToCreate: Set<String> = []

            for url in urls {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
                    AppLogger.log("⚠️ [handleUpload] File does not exist at local path: \(url.path)", level: .warning)
                    continue
                }

                if isDir.boolValue {
                    AppLogger.log("📂 [handleUpload] Processing local directory: \(url.path)")
                    let basePath = url.path
                    let remoteFolderBase = (path.hasSuffix("/") ? path : path + "/") + url.lastPathComponent
                    remoteDirsToCreate.insert(remoteFolderBase)

                    guard let enumerator = FileManager.default.enumerator(
                        at: url,
                        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
                        options: []
                    ) else {
                        AppLogger.log("⚠️ [handleUpload] Failed to create directory enumerator for: \(url.path)", level: .warning)
                        continue
                    }

                    var folderFilesCount = 0
                    for case let fileURL as URL in enumerator {
                        guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) else {
                            continue
                        }

                        let isDir = rv.isDirectory ?? false
                        if isDir {
                            continue
                        }

                        guard rv.isRegularFile == true else { continue }

                        let relativePath = String(fileURL.path.dropFirst(basePath.count + 1))
                        let remoteFilePath = remoteFolderBase + "/" + relativePath
                        let remoteDir = (remoteFilePath as NSString).deletingLastPathComponent
                        remoteDirsToCreate.insert(remoteDir)

                        let size = UInt64(rv.fileSize ?? 0)
                        let fileName = (relativePath as NSString).lastPathComponent
                        allItems.append((localPath: fileURL.path, fileName: fileName, fileSize: size, devicePath: remoteDir))
                        folderFilesCount += 1
                    }
                    AppLogger.log("📂 [handleUpload] Enumerated directory: \(url.path) — found \(folderFilesCount) files")
                } else {
                    AppLogger.log("📂 [handleUpload] Processing local file: \(url.path)")
                    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                          let size = attrs[.size] as? UInt64 else {
                        AppLogger.log("⚠️ [handleUpload] Failed to retrieve attributes for local file: \(url.path)", level: .warning)
                        continue
                    }
                    allItems.append((localPath: url.path, fileName: url.lastPathComponent, fileSize: size, devicePath: path))
                }
            }

            AppLogger.log("📂 [handleUpload] Collected \(allItems.count) files to upload.")

            guard !allItems.isEmpty else {
                AppLogger.log("⚠️ [handleUpload] No files collected for upload. Exiting.", level: .warning)
                await MainActor.run { manager.isPreparing = false }
                return
            }

            let adb = ADBManager.getADBPath()

            func fullDevicePath(_ item: (localPath: String, fileName: String, fileSize: UInt64, devicePath: String)) -> String {
                let (safeName, _) = FileNameHelper.getSafeFilename(item.fileName)
                return item.devicePath.hasSuffix("/")
                    ? item.devicePath + safeName
                    : item.devicePath + "/" + safeName
            }

            await MainActor.run {
                manager.preparingMessage = "Checking for conflicts (\(allItems.count) files)…"
            }

            var conflictingPaths = Set<String>()
            let allDevicePaths = allItems.map { fullDevicePath($0) }
            let chunkSize = 50
            for chunkStart in stride(from: 0, to: allDevicePaths.count, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, allDevicePaths.count)
                let chunk = Array(allDevicePaths[chunkStart..<chunkEnd])
                
                let checks = chunk.map { path in
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    return "[ -e '\(escaped)' ] && echo '\(escaped)'"
                }.joined(separator: "; ")
                
                let (code, out, _) = await Shell.runAsync(
                    adb,
                    args: ADBManager.deviceArgs(["shell", checks])
                )
                if code == 0 {
                    for line in out.split(separator: "\n") {
                        let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !path.isEmpty { conflictingPaths.insert(path) }
                    }
                }
            }

            await MainActor.run { manager.isPreparing = false }

            if !conflictingPaths.isEmpty {
                let conflictNames = allItems
                    .filter { conflictingPaths.contains(fullDevicePath($0)) }
                    .map { $0.fileName }

                try? await Task.sleep(nanoseconds: 350_000_000)

                let choice = await MainActor.run {
                    ConflictDialog.show(conflictNames: conflictNames, totalCount: allItems.count)
                }

                switch choice {
                case .replace: break
                case .skip:
                    allItems = allItems.filter { !conflictingPaths.contains(fullDevicePath($0)) }
                case .cancel: return
                }
            }

            guard !allItems.isEmpty else { return }

            let totalBytes = allItems.reduce(UInt64(0)) { $0 + $1.fileSize }
            
            // Storage Capacity Pre-flight Check
            let rootPath = path.hasPrefix("/storage/emulated") ? "/storage/emulated/0" : (path.components(separatedBy: "/").dropLast(path.components(separatedBy: "/").count - 3).joined(separator: "/"))
            let resolvedStorageRoot = rootPath.isEmpty ? "/storage/emulated/0" : rootPath
            
            if let stats = await MainActor.run(body: { self.deviceManager.storageStats[resolvedStorageRoot] }) {
                let freeBytes = UInt64(stats.totalBytes - stats.usedBytes)
                if totalBytes > freeBytes {
                    let requiredSize = formatBytes(totalBytes)
                    let availableSize = formatBytes(freeBytes)
                    let deficit = formatBytes(totalBytes - freeBytes)
                    
                    // Let macOS finish drag-and-drop cleanup before blocking with modal
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Not Enough Storage"
                        alert.informativeText = "You are trying to upload \(requiredSize), but only \(availableSize) is available on the device.\n\nPlease free up at least \(deficit) before uploading."
                        alert.alertStyle = .critical
                        alert.addButton(withTitle: "OK")
                        alert.runModal()
                    }
                    return
                }
            }


            if !remoteDirsToCreate.isEmpty {
                await ADBManager.batchCreateFolders(paths: Array(remoteDirsToCreate))
                // Refresh list immediately so the newly created folders appear on screen
                await loadFiles()
            }

            manager.enqueueFiles(files: allItems)
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
                try await fileActionManager.deleteFiles(filesToDelete)
                
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
                try await fileActionManager.deleteFiles(filesToDelete, permanent: true)
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

struct LiveOperationRow: View {
    let op: OperationEngine.LiveOperation
    
    var stateIconName: String {
        switch op.state {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed(let success, let message):
            if message == "Cancelled" { return "slash.circle" }
            return success ? "checkmark.circle" : "xmark.circle"
        }
    }
    
    var stateColor: Color {
        switch op.state {
        case .pending: return .secondary
        case .running: return .blue
        case .completed(let success, let message):
            if message == "Cancelled" { return .secondary }
            return success ? .green : .red
        }
    }
    
    var body: some View {
        HStack {
            Image(systemName: stateIconName)
                .font(.system(size: 10))
                .foregroundColor(stateColor)
            Text(op.displayName)
                .font(.system(size: 10))
            Spacer()
            if case .running = op.state {
                ProgressView().scaleEffect(0.5).frame(width: 10, height: 10)
            }
        }
        .padding(.leading, 8)
    }
}
