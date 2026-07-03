//
//  DownloadManager.swift
//  (CORRECTED - Single Argument Callback)
//
import Foundation
internal import Combine

class DownloadManager: ObservableObject {
    @Published var activeDownloads: [String: DownloadProgress] = [:] {
        didSet {
            let count = activeDownloads.count
            if count != lastActiveDownloadsCount {
                lastActiveDownloadsCount = count
                NotificationCenter.default.post(
                    name: .afsTransferCountChanged,
                    object: nil,
                    userInfo: ["type": "download", "count": count]
                )
            }
        }
    }
    private var lastActiveDownloadsCount = 0
    private var internalActiveDownloads: [String: DownloadProgress] = [:]
    
    // Batch tracking for showing "X of Y completed"
    @Published var batchTotal: Int = 0
    @Published var batchCompleted: Int = 0 {
        didSet {
            NotificationCenter.default.post(
                name: .afsDownloadBatchCompleted,
                object: nil,
                userInfo: [
                    "completed": batchCompleted,
                    "total": batchTotal
                ]
            )
        }
    }
    @Published var isBatchDownloading: Bool = false {
        didSet {
            NotificationCenter.default.post(
                name: .afsDownloadBatchStateChanged,
                object: nil,
                userInfo: [
                    "isDownloading": isBatchDownloading,
                    "batchTotal": batchTotal
                ]
            )
        }
    }
    
    // Live-adjustable concurrency (1-10 slots), persisted across launches
    @Published var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrentDownloads") }
    }
    
    // Folder scan state — shown in progress panel while enumerating
    @Published var isScanning: Bool = false
    @Published var scanningFolderName: String = ""
    @Published var currentFolderName: String = ""  // set while a folder batch is running
    
    // Batch cancellation
    private var isBatchCancelled: Bool = false
    
    // Store active tasks for cancellation (Key: devicePath)
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let taskLock = NSLock()
    
    // App Nap / system sleep prevention — held while any download is active.
    // Without this, macOS may throttle or sleep the app during long transfers,
    // causing ADB processes to stall and downloads to silently fail.
    private var transferActivity: NSObjectProtocol?
    private let activityLock = NSLock()
    
    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        self.maxConcurrent = saved > 0 ? min(max(saved, 1), 10) : 3
    }
    
    // MARK: - Sleep Prevention
    
    private func beginPreventingSleep() {
        activityLock.lock()
        defer { activityLock.unlock() }
        guard transferActivity == nil else { return }
        transferActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Downloading files from Android device via ADB"
        )
    }
    
    private func endPreventingSleep() {
        activityLock.lock()
        defer { activityLock.unlock() }
        guard let activity = transferActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        transferActivity = nil
    }
    
    // Thread-safe storage for progress updates from background
    private let progressLock = NSLock()
    private var backgroundProgress: [String: (bytes: UInt64, speed: Double)] = [:]
    
    // Timer for periodic UI updates - only runs when downloads are active
    private var updateTimer: Timer?
    
    struct DownloadProgress: Identifiable {
        let id = UUID()
        let fileName: String
        let devicePath: String
        let localPath: String
        var bytesTransferred: UInt64 = 0
        var totalBytes: UInt64
        var transferSpeed: Double = 0
        var isComplete: Bool = false
        var isCancelled: Bool = false
        var error: String?
        
        var progress: Double {
            guard totalBytes > 0 else { return 0 }
            return Double(bytesTransferred) / Double(totalBytes)
        }
        
        var progressPercentage: Int {
            Int(progress * 100)
        }
        
       var speedText: String {
            if transferSpeed > 0 {
                return String(format: "%.1f MB/s", transferSpeed)
            }
            return ""
        }
    }
    
    private func startTimerIfNeeded() {
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateUIFromBackground()
        }
    }
    
    private func stopTimerIfNeeded() {
        guard internalActiveDownloads.isEmpty else { return }
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    // Public methods to pause/resume during navigation
    func pauseUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    func resumeUpdates() {
        guard !internalActiveDownloads.isEmpty else { return }
        startTimerIfNeeded()
    }
    
    deinit {
        updateTimer?.invalidate()
        endPreventingSleep()
    }
    
    private func updateUIFromBackground() {
        progressLock.lock()
        let updates = backgroundProgress
        progressLock.unlock()
        
        for (devicePath, (bytes, speed)) in updates {
            internalActiveDownloads[devicePath]?.bytesTransferred = bytes
            internalActiveDownloads[devicePath]?.transferSpeed = speed
        }
        
        activeDownloads = internalActiveDownloads
    }
    
    // MARK: - Cancellation
    
    func cancelDownload(devicePath: String) {
        print("🛑 Cancelling download: \(devicePath)")
        
        // Cancel the task
        taskLock.lock()
        if let task = activeTasks[devicePath] {
            task.cancel()
            activeTasks.removeValue(forKey: devicePath)
        }
        taskLock.unlock()
        
        // Update UI state
        if var download = internalActiveDownloads[devicePath] {
            download.isCancelled = true
            internalActiveDownloads[devicePath] = download
            activeDownloads = internalActiveDownloads
            
            // Clean up partial file
            let localPath = download.localPath
            DispatchQueue.global(qos: .utility).async {
                if FileManager.default.fileExists(atPath: localPath) {
                    try? FileManager.default.removeItem(atPath: localPath)
                }
            }
        }
        
        // Remove from UI after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.internalActiveDownloads.removeValue(forKey: devicePath)
            self.activeDownloads = self.internalActiveDownloads
            self.stopTimerIfNeeded()
            
            // Clear background progress
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: devicePath)
            self.progressLock.unlock()
        }
    }
    
    /// Cancels all active downloads and aborts batch loop
    func cancelAllDownloads() {
        print("🛑 Cancelling ALL downloads")
        isBatchCancelled = true
        
        taskLock.lock()
        let allTasks = activeTasks
        activeTasks.removeAll()
        taskLock.unlock()
        
        for (_, task) in allTasks {
            task.cancel()
        }
        
        // Mark all as cancelled
        for key in internalActiveDownloads.keys {
            internalActiveDownloads[key]?.isCancelled = true
        }
        activeDownloads = internalActiveDownloads
        
        // Clear after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.internalActiveDownloads.removeAll()
            self.activeDownloads.removeAll()
            self.isBatchDownloading = false
            self.batchTotal = 0
            self.batchCompleted = 0
            self.currentFolderName = ""
            self.isScanning = false
            self.scanningFolderName = ""
            self.stopTimerIfNeeded()
            
            self.progressLock.lock()
            self.backgroundProgress.removeAll()
            self.progressLock.unlock()
        }
    }
    
    func downloadFile(
        devicePath: String,
        fileName: String,
        fileSize: UInt64,
        to localPath: String
    ) async throws {
        
        // Initialize progress
        let progress = DownloadProgress(
            fileName: fileName,
            devicePath: devicePath,
            localPath: localPath,
            totalBytes: fileSize
        )
        
        // Add to UI on main thread and start timer
        await MainActor.run {
            internalActiveDownloads[devicePath] = progress
            if !isBatchDownloading {
                activeDownloads = internalActiveDownloads
            }
            startTimerIfNeeded()
        }
        
        // Prevent App Nap / system sleep during transfer
        beginPreventingSleep()
        
        
        // Create and store the task for cancellation
        let downloadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let progressStream = ADBManager.pullFileWithProgress(
                devicePath: devicePath,
                localPath: localPath
            )
            
            // Consume stream and update background storage
            for await (bytesTransferred, speed) in progressStream {
                // Check for cancellation
                if Task.isCancelled {
                    print("🛑 Download cancelled: \(fileName)")
                    return
                }
                
                self.progressLock.lock()
                self.backgroundProgress[devicePath] = (bytesTransferred, speed)
                self.progressLock.unlock()
            }
            
            // Check for cancellation before marking complete
            if Task.isCancelled {
                return
            }
            
            // Clear background progress
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: devicePath)
            self.progressLock.unlock()
            
            // Mark complete on main thread
            await MainActor.run {
                self.internalActiveDownloads[devicePath]?.isComplete = true
                self.internalActiveDownloads[devicePath]?.bytesTransferred = fileSize
                self.internalActiveDownloads[devicePath]?.transferSpeed = 0
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
            }
            
            
            // Show 100% briefly
            let batchActive = await MainActor.run { self.isBatchDownloading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self.internalActiveDownloads.removeValue(forKey: devicePath)
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
                self.stopTimerIfNeeded()
            }
            
            let shouldEndSleep = await MainActor.run {
                !self.isBatchDownloading && self.activeDownloads.isEmpty
            }
            if shouldEndSleep {
                self.endPreventingSleep()
            }
        }
        
        // Store the task for cancellation
        taskLock.lock()
        activeTasks[devicePath] = downloadTask
        taskLock.unlock()
        
        // Wait for completion
        await downloadTask.value
        
        // Clean up task reference
        taskLock.lock()
        activeTasks.removeValue(forKey: devicePath)
        taskLock.unlock()
    }
    
    // MARK: - Parallel Download Support
    
    /// Starts a download without waiting for completion (fire-and-forget for parallel execution)
    /// - Returns: The Task that can be used to track or cancel the download
    @discardableResult
    func startDownload(
        devicePath: String,
        fileName: String,
        fileSize: UInt64,
        to localPath: String
    ) -> Task<Void, Never> {
        
        // Initialize progress
        let progress = DownloadProgress(
            fileName: fileName,
            devicePath: devicePath,
            localPath: localPath,
            totalBytes: fileSize
        )
        
        // Add to UI on main thread and start timer
        Task { @MainActor in
            internalActiveDownloads[devicePath] = progress
            if !isBatchDownloading {
                activeDownloads = internalActiveDownloads
            }
            startTimerIfNeeded()
        }
        
        // Create and store the task for cancellation
        let downloadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let progressStream = ADBManager.pullFileWithProgress(
                devicePath: devicePath,
                localPath: localPath
            )
            
            // Consume stream and update background storage
            for await (bytesTransferred, speed) in progressStream {
                // Check for cancellation
                if Task.isCancelled {
                    print("🛑 Download cancelled: \(fileName)")
                    return
                }
                
                self.progressLock.lock()
                self.backgroundProgress[devicePath] = (bytesTransferred, speed)
                self.progressLock.unlock()
            }
            
            // Check for cancellation before marking complete
            if Task.isCancelled {
                return
            }
            
            // Clear background progress
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: devicePath)
            self.progressLock.unlock()
            
            // Mark complete on main thread
            await MainActor.run {
                self.internalActiveDownloads[devicePath]?.isComplete = true
                self.internalActiveDownloads[devicePath]?.bytesTransferred = fileSize
                self.internalActiveDownloads[devicePath]?.transferSpeed = 0
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
            }
            
            // Show 100% briefly
            let batchActive = await MainActor.run { self.isBatchDownloading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self.internalActiveDownloads.removeValue(forKey: devicePath)
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
                self.stopTimerIfNeeded()
            }
            
            // Clean up task reference
            self.taskLock.lock()
            self.activeTasks.removeValue(forKey: devicePath)
            self.taskLock.unlock()
            
            let shouldEndSleep = await MainActor.run {
                !self.isBatchDownloading && self.internalActiveDownloads.isEmpty
            }
            if shouldEndSleep {
                self.endPreventingSleep()
            }
        }
        
        // Store the task for cancellation
        taskLock.lock()
        activeTasks[devicePath] = downloadTask
        taskLock.unlock()
        
        return downloadTask
    }
    
    /// Downloads multiple files in parallel with a sliding window approach.
    /// Reads `maxConcurrent` dynamically so live adjustments take effect on the next slot.
    func downloadMultipleFiles(
        files: [(devicePath: String, fileName: String, fileSize: UInt64, localPath: String)],
        maxConcurrent fixedMax: Int? = nil   // nil = use self.maxConcurrent (live)
    ) async {
        guard !files.isEmpty else { return }
        
        var itemsToDownload = files
        
        // Native Mac check: identify files that already exist on the local destination
        let conflictingItems = files.filter { FileManager.default.fileExists(atPath: $0.localPath) }
        if !conflictingItems.isEmpty {
            let conflictNames = conflictingItems.map { $0.fileName }
            let choice = await MainActor.run {
                ConflictDialog.show(conflictNames: conflictNames, totalCount: files.count)
            }
            switch choice {
            case .replace:
                break // Proceed with all files (will overwrite)
            case .skip:
                itemsToDownload = files.filter { !FileManager.default.fileExists(atPath: $0.localPath) }
            case .cancel:
                return
            }
        }
        
        guard !itemsToDownload.isEmpty else { return }
        
        // Initialize batch tracking
        await MainActor.run {
            if isBatchDownloading {
                batchTotal += itemsToDownload.count
            } else {
                batchTotal = itemsToDownload.count
                batchCompleted = 0
            }
            isBatchDownloading = true
        }
        
        // Prevent App Nap / system sleep for the entire batch
        beginPreventingSleep()
        
        print("📥 Starting parallel download of \(itemsToDownload.count) files")
        isBatchCancelled = false
        
        await withTaskGroup(of: Void.self) { group in
            var runningCount = 0
            var fileIndex = 0
            
            while fileIndex < itemsToDownload.count && !isBatchCancelled {
                // Re-read limit each iteration so live slider changes take effect
                let limit = fixedMax ?? self.maxConcurrent
                
                // Fill up to limit slots
                while runningCount < limit && fileIndex < itemsToDownload.count {
                    let file = itemsToDownload[fileIndex]
                    fileIndex += 1
                    runningCount += 1
                    
                    print("📥 [\(fileIndex)/\(itemsToDownload.count)] Starting: \(file.fileName)")
                    
                    group.addTask {
                        do {
                            try await self.downloadFile(
                                devicePath: file.devicePath,
                                fileName: file.fileName,
                                fileSize: file.fileSize,
                                to: file.localPath
                            )
                            await MainActor.run { self.batchCompleted += 1 }
                        } catch {
                            print("❌ Failed to download \(file.fileName): \(error)")
                            await MainActor.run { self.batchCompleted += 1 }
                        }
                    }
                }
                
                // Wait for ONE slot to free before looping
                if runningCount >= limit && fileIndex < itemsToDownload.count {
                    await group.next()
                    runningCount -= 1
                }
            }
            
            await group.waitForAll()
        }
        
        await MainActor.run {
            isBatchDownloading = false
            currentFolderName = ""
            activeDownloads = internalActiveDownloads
            stopTimerIfNeeded()
        }
        
        // End sleep prevention now that all downloads are done
        endPreventingSleep()
        
        print("✅ All \(itemsToDownload.count) downloads completed")
    }
    
    // MARK: - Folder Download
    
    /// Recursively scans `devicePath` on the Android device then downloads the whole tree,
    /// preserving the directory structure under `localDirectory`.
    func downloadFolder(devicePath: String, folderName: String, to localDirectory: URL) async {
        // Show scanning state
        await MainActor.run {
            isScanning = true
            scanningFolderName = folderName
        }
        
        let files: [(devicePath: String, relativePath: String, size: UInt64)]
        do {
            files = try await ADBManager.listAllFilesRecursively(path: devicePath)
        } catch {
            print("❌ Folder scan failed: \(error)")
            await MainActor.run { isScanning = false; scanningFolderName = "" }
            return
        }
        
        await MainActor.run {
            isScanning = false
            scanningFolderName = ""
            currentFolderName = folderName
        }
        
        guard !files.isEmpty else {
            print("📂 Folder is empty, nothing to download.")
            await MainActor.run { currentFolderName = "" }
            return
        }
        
        // Build local directory structure and collect download items
        var downloadItems: [(devicePath: String, fileName: String, fileSize: UInt64, localPath: String)] = []
        
        for file in files {
            let localFileURL = localDirectory.appendingPathComponent(file.relativePath)
            let localDir = localFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
            
            // Use just the last path component as display name
            let fileName = (file.relativePath as NSString).lastPathComponent
            downloadItems.append((
                devicePath: file.devicePath,
                fileName: fileName,
                fileSize: file.size,
                localPath: localFileURL.path
            ))
        }
        
        print("📂 Downloading folder '\(folderName)': \(downloadItems.count) files → \(localDirectory.path)")
        await downloadMultipleFiles(files: downloadItems)
    }
}
