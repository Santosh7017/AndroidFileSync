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
//    
//    @State private var files: [UnifiedFile] = []
//    @State private var currentPath = "/sdcard"
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
    @StateObject private var deviceManager = DeviceManager()
    @StateObject private var downloadManager = DownloadManager() // Use the non-blocking version
    @StateObject private var uploadManager = UploadManager()   // A non-blocking version is needed for this too

    @State private var files: [UnifiedFile] = []
    @State private var currentPath = "/sdcard"
    @State private var pathHistory: [String] = []
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            // Your HeaderView
            HeaderView(deviceManager: deviceManager, downloadManager: downloadManager, uploadManager: uploadManager)
            Divider()

            // Main Content
            if deviceManager.isConnected {
                HSplitView {
                    SidebarView(quickAccessItems: QuickAccessItem.commonFolders, currentPath: currentPath, onNavigate: navigateTo)
                    
                    // CORRECTED INITIALIZER
                    FileBrowserView(
                        files: files,
                        currentPath: currentPath,
                        isLoading: isLoading,
                        canGoBack: !pathHistory.isEmpty,
                        onNavigate: navigateTo,
                        onGoBack: navigateBack,
                        onDownload: handleDownload,
                        onUpload: handleUpload
                    )
                }
            } else {
                // Your EmptyStateView or a loading view
                EmptyStateView()
            }
            
            // Progress/Status Views
            if !downloadManager.activeDownloads.isEmpty {
                // Your progress view implementation
                ForEach(Array(downloadManager.activeDownloads.values)) { download in
                    VStack(alignment: .leading) {
                        Text(download.fileName).font(.caption)
                        ProgressView(value: download.progress)
                    }.padding()
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .task { await initializeDevice() }
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
        isLoading = true
        self.files = (try? await deviceManager.listFiles(path: currentPath)) ?? []
        isLoading = false
    }

    private func navigateTo(_ path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await loadFiles() }
    }

    private func navigateBack() {
        guard let previousPath = pathHistory.popLast() else { return }
        currentPath = previousPath
        Task { await loadFiles() }
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

}
