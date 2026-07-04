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
            appManager?.operationEngine.processQueue()
            uploadManager?.triggerProcessQueue()
        }
    }
    private var lastActiveDownloadsCount = 0
    private var internalActiveDownloads: [String: DownloadProgress] = [:]
    weak var deviceManager: DeviceManager?
    weak var appManager: AppManager?
    weak var uploadManager: UploadManager?
    private var isConnectionOffline = false
    private var targetDeviceSerial: String? = nil
    
    struct DownloadQueueItem {
        let devicePath: String
        let fileName: String
        let fileSize: UInt64
        let localPath: String
        var retryCount: Int = 0
    }
    
    // Download queue properties
    private var pendingFiles: [DownloadQueueItem] = []
    private let queueLock = NSLock()
    private var isProcessingQueue = false
    private var activeCongestionCap: Int = 10
    private var successStreak: Int = 0
    private let activeRunningLock = NSLock()
    private var activeRunningCount = 0
    
    var runningTransfersCount: Int {
        activeRunningLock.lock()
        defer { activeRunningLock.unlock() }
        return activeRunningCount
    }
    
    // Batch tracking for showing "X of Y completed"
    private var currentBatchId: UUID = UUID()
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
    
    private var isAutoClamping = false
    private var preferredMaxConcurrent: Int = 3
    private var temporaryMaxConcurrent: Int? = nil
    
    // Live-adjustable concurrency (1-10 slots), persisted across launches
    @Published var maxConcurrent: Int = 3 {
        didSet {
            if !isAutoClamping {
                let activeUploadsCount = uploadManager?.runningTransfersCount ?? 0
                let isDual = activeUploadsCount > 0
                
                if isDual {
                    temporaryMaxConcurrent = maxConcurrent
                } else {
                    temporaryMaxConcurrent = nil
                    preferredMaxConcurrent = maxConcurrent
                    UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrentDownloads")
                }
            }
            triggerProcessQueue()
        }
    }
    
    @Published var effectiveConcurrentLimit: Int = 3
    
    // Folder scan state — shown in progress panel while enumerating
    @Published var isScanning: Bool = false
    @Published var scanningFolderName: String = ""
    @Published var currentFolderName: String = ""  // set while a folder batch is running
    
    // Batch cancellation
    private var isBatchCancelled: Bool = false
    
    // Store active tasks for cancellation (Key: devicePath)
    private var activeTasks: [String: Task<Void, Error>] = [:]
    private let taskLock = NSLock()
    
    // App Nap / system sleep prevention — held while any download is active.
    // Without this, macOS may throttle or sleep the app during long transfers,
    // causing ADB processes to stall and downloads to silently fail.
    private var transferActivity: NSObjectProtocol?
    private let activityLock = NSLock()
    
    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        let clamped = saved > 0 ? min(max(saved, 1), 10) : 3
        self.preferredMaxConcurrent = clamped
        self.maxConcurrent = clamped
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
        var retryCount: Int = 0
        
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
    
    func isCancelled(devicePath: String) -> Bool {
        return internalActiveDownloads[devicePath]?.isCancelled ?? false
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
            
            self.uploadManager?.forceReevaluateConcurrencyLimit()
            
            self.progressLock.lock()
            self.backgroundProgress.removeAll()
            self.progressLock.unlock()
        }
    }
    
    @MainActor
    func forceReevaluateConcurrencyLimit() {
        // If we are currently downloading, the processQueue loop is running.
        // We can just update maxConcurrent right now so the UI stepper bounds and values update instantly.
        let isWireless = deviceManager?.connectionType == .wireless
        let isAppBusy = appManager?.operationEngine.isBusy ?? false
        let activeUploadsCount = uploadManager?.runningTransfersCount ?? 0
        let uploadsActive = activeUploadsCount > 0
        
        let maxDownloadCap: Int
        if isWireless {
            if uploadsActive {
                maxDownloadCap = isAppBusy ? 3 : 4
            } else {
                maxDownloadCap = isAppBusy ? 6 : 8
            }
        } else {
            if uploadsActive {
                maxDownloadCap = isAppBusy ? 5 : 8
            } else {
                maxDownloadCap = isAppBusy ? 10 : 10
            }
        }
        
        let targetMax = min(preferredMaxConcurrent, maxDownloadCap)
        if self.maxConcurrent != targetMax {
            self.isAutoClamping = true
            self.maxConcurrent = targetMax
            self.isAutoClamping = false
        }
    }
    
    @MainActor
    private func markDownloadFailed(devicePath: String, error: Error) {
        AppLogger.log("❌ Download failed for \(devicePath): \(error.localizedDescription)", level: .error)
        if var download = internalActiveDownloads[devicePath] {
            download.error = error.localizedDescription
            download.transferSpeed = 0
            internalActiveDownloads[devicePath] = download
            activeDownloads = internalActiveDownloads
        }
        progressLock.lock()
        backgroundProgress.removeValue(forKey: devicePath)
        progressLock.unlock()
    }
    
    private func isConnectionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        // Consider any error as a potential connection/I/O issue that warrants a retry,
        // EXCEPT for permanent file errors.
        if msg.contains("no such file or directory") || msg.contains("file not found") || msg.contains("permission denied") {
            return false
        }
        return true
    }
    
    func downloadFile(
        devicePath: String,
        fileName: String,
        fileSize: UInt64,
        to localPath: String,
        retryCount: Int = 0
    ) async throws {
        
        // Initialize progress
        let progress = DownloadProgress(
            fileName: fileName,
            devicePath: devicePath,
            localPath: localPath,
            totalBytes: fileSize,
            retryCount: retryCount
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
            
            do {
                // Consume stream and update background storage
                for try await (bytesTransferred, speed) in progressStream {
                    // Check for cancellation
                    if Task.isCancelled {
                        print("🛑 Download cancelled: \(fileName)")
                        return
                    }
                    
                    self.progressLock.lock()
                    self.backgroundProgress[devicePath] = (bytesTransferred, speed)
                    self.progressLock.unlock()
                }
            } catch {
                await self.markDownloadFailed(devicePath: devicePath, error: error)
                throw error
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
                self.activeDownloads = self.internalActiveDownloads
            }
            
            let batchActive = await MainActor.run { self.isBatchDownloading }
            
            Task.detached { [weak self] in
                let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                
                await MainActor.run {
                    self?.internalActiveDownloads.removeValue(forKey: devicePath)
                    if let dict = self?.internalActiveDownloads {
                        self?.activeDownloads = dict
                    }
                    self?.stopTimerIfNeeded()
                }
                
                let shouldEndSleep = await MainActor.run {
                    !(self?.isBatchDownloading ?? false) && (self?.activeDownloads.isEmpty ?? true)
                }
                if shouldEndSleep {
                    self?.endPreventingSleep()
                }
            }
        }
        
        // Store the task for cancellation
        taskLock.lock()
        activeTasks[devicePath] = downloadTask
        taskLock.unlock()
        
        // Wait for completion
        try await downloadTask.value
        
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
        to localPath: String,
        retryCount: Int = 0
    ) -> Task<Void, Error> {
        
        // Initialize progress
        let progress = DownloadProgress(
            fileName: fileName,
            devicePath: devicePath,
            localPath: localPath,
            totalBytes: fileSize,
            retryCount: retryCount
        )
        
        // Add to UI on main thread and start timer
        Task { @MainActor in
            internalActiveDownloads[devicePath] = progress
            activeDownloads = internalActiveDownloads
            startTimerIfNeeded()
        }
        
        // Create and store the task for cancellation
        let downloadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let progressStream = ADBManager.pullFileWithProgress(
                devicePath: devicePath,
                localPath: localPath
            )
            
            do {
                // Consume stream and update background storage
                for try await (bytesTransferred, speed) in progressStream {
                    // Check for cancellation
                    if Task.isCancelled {
                        print("🛑 Download cancelled: \(fileName)")
                        return
                    }
                    
                    self.progressLock.lock()
                    self.backgroundProgress[devicePath] = (bytesTransferred, speed)
                    self.progressLock.unlock()
                }
            } catch {
                await self.markDownloadFailed(devicePath: devicePath, error: error)
                throw error
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
                self.activeDownloads = self.internalActiveDownloads
            }
            
            // Show 100% briefly
            let batchActive = await MainActor.run { self.isBatchDownloading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self.internalActiveDownloads.removeValue(forKey: devicePath)
                self.activeDownloads = self.internalActiveDownloads
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
        
        queueLock.lock()
        let items = itemsToDownload.map { DownloadQueueItem(devicePath: $0.devicePath, fileName: $0.fileName, fileSize: $0.fileSize, localPath: $0.localPath) }
        pendingFiles.append(contentsOf: items)
        let shouldStart = !isProcessingQueue
        if shouldStart { isProcessingQueue = true }
        queueLock.unlock()
        
        // Initialize batch tracking
        await MainActor.run {
            self.targetDeviceSerial = ADBManager.activeDeviceSerial
            if isBatchDownloading {
                batchTotal += itemsToDownload.count
            } else {
                currentBatchId = UUID()
                batchTotal = itemsToDownload.count
                batchCompleted = 0
            }
            isBatchDownloading = true
            
            let isWireless = self.deviceManager?.connectionType == .wireless
            let isAppBusy = self.appManager?.operationEngine.isBusy ?? false
            let uploadsActive = (self.uploadManager?.runningTransfersCount ?? 0) > 0 || (self.uploadManager?.isBatchUploading ?? false)
            if isWireless {
                self.effectiveConcurrentLimit = uploadsActive ? (isAppBusy ? 2 : 3) : (isAppBusy ? 4 : 5)
            } else {
                self.effectiveConcurrentLimit = uploadsActive ? (isAppBusy ? 5 : 6) : min(self.maxConcurrent, isAppBusy ? 10 : 12)
            }
        }
        
        // Prevent App Nap / system sleep for the entire batch
        beginPreventingSleep()
        isBatchCancelled = false
        
        if shouldStart {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.processQueue(fixedMax: fixedMax)
            }
        }
    }
    
    func triggerProcessQueue(fixedMax: Int? = nil) {
        queueLock.lock()
        let shouldStart = !isProcessingQueue && !pendingFiles.isEmpty
        if shouldStart { isProcessingQueue = true }
        queueLock.unlock()
        
        if shouldStart {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.processQueue(fixedMax: fixedMax)
            }
        }
    }
    
    private func processQueue(fixedMax: Int? = nil) async {
        beginPreventingSleep()
        
        let batchId = await MainActor.run { self.currentBatchId }
        
        await withTaskGroup(of: Void.self) { group in
            while !isBatchCancelled {
                // Check if target device has switched explicitly (ignore transient nil during ADB refreshes)
                if let currentSerial = ADBManager.activeDeviceSerial, let targetSerial = targetDeviceSerial, currentSerial != targetSerial {
                    print("⚠️ DownloadManager: Explicit device switch from \(targetSerial) to \(currentSerial). Aborting batch download.")
                    await MainActor.run {
                        self.cancelAllDownloads()
                    }
                    break
                }
                
                // Concurrency adjustment for Wi-Fi + active app operations
                let isWireless = deviceManager?.connectionType == .wireless
                let isAppBusy = appManager?.operationEngine.isBusy ?? false
                
                // Connection protection: if device is offline, pause queue processing
                let isOffline = (deviceManager.map { !$0.isConnected } ?? true) || isConnectionOffline
                if isOffline {
                    await MainActor.run {
                        for (devicePath, var download) in internalActiveDownloads where !download.isComplete && !download.isCancelled {
                            download.error = "Device offline - waiting for reconnect..."
                            download.transferSpeed = 0
                            internalActiveDownloads[devicePath] = download
                        }
                        activeDownloads = internalActiveDownloads
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // Sleep 1 second
                    
                    // Reset our local offline flag if device is back online according to deviceManager
                    if let dm = deviceManager, dm.isConnected {
                        isConnectionOffline = false
                    }
                    continue
                }
                
                // Dynamic wireless/wired concurrency limit with 50/50 cross-direction slot budgeting
                let activeUploadsCount = uploadManager?.runningTransfersCount ?? 0
                let uploadsActive = activeUploadsCount > 0
                
                let globalCombinedLimit: Int
                let maxDownloadCap: Int
                if isWireless {
                    if uploadsActive {
                        // 50-50 Wi-Fi allocation: 4 downloads + 4 uploads = 8 total (or 3+3 if app ops active)
                        globalCombinedLimit = isAppBusy ? 6 : 8
                        maxDownloadCap = isAppBusy ? 3 : 4
                    } else {
                        globalCombinedLimit = isAppBusy ? 6 : 8
                        maxDownloadCap = isAppBusy ? 6 : 8
                    }
                } else {
                    if uploadsActive {
                        // USB allocation: 8 downloads + 8 uploads = 16 total (or 5+5 if app ops active)
                        globalCombinedLimit = isAppBusy ? 10 : 16
                        maxDownloadCap = isAppBusy ? 5 : 8
                    } else {
                        globalCombinedLimit = isAppBusy ? 10 : 16
                        maxDownloadCap = isAppBusy ? 10 : 10
                    }
                }
                if !uploadsActive {
                    await MainActor.run { self.temporaryMaxConcurrent = nil }
                }
                
                let baseMax = await MainActor.run { self.temporaryMaxConcurrent ?? self.preferredMaxConcurrent }
                let targetMax = min(fixedMax ?? baseMax, maxDownloadCap)
                if self.maxConcurrent != targetMax {
                    await MainActor.run {
                        self.isAutoClamping = true
                        self.maxConcurrent = targetMax
                        self.isAutoClamping = false
                    }
                }
                
                var limit = min(fixedMax ?? self.maxConcurrent, maxDownloadCap)
                limit = min(limit, self.activeCongestionCap)
                
                let maxDownloadsAllowed = max(1, globalCombinedLimit - activeUploadsCount)
                limit = min(limit, maxDownloadsAllowed)
                
                let newLimit = limit
                await MainActor.run {
                    if self.effectiveConcurrentLimit != newLimit {
                        self.effectiveConcurrentLimit = newLimit
                    }
                }
                
                activeRunningLock.lock()
                var running = activeRunningCount
                activeRunningLock.unlock()
                
                // Fill up to limit slots
                while running < limit && !isBatchCancelled {
                    queueLock.lock()
                    let nextFile = pendingFiles.isEmpty ? nil : pendingFiles.removeFirst()
                    queueLock.unlock()
                    
                    guard let file = nextFile else { break }
                    
                    activeRunningLock.lock()
                    activeRunningCount += 1
                    running = activeRunningCount
                    activeRunningLock.unlock()
                    
                    group.addTask {
                        var didSucceed = false
                        var connErrorOccurred = false
                        do {
                             try await self.downloadFile(
                                 devicePath: file.devicePath,
                                 fileName: file.fileName,
                                 fileSize: file.fileSize,
                                 to: file.localPath,
                                 retryCount: file.retryCount
                             )
                            didSucceed = true
                            
                            // Success path: gradually restore congestion cap
                            await MainActor.run {
                                self.successStreak += 1
                                if self.successStreak >= 3 {
                                    self.activeCongestionCap = min(10, self.activeCongestionCap + 1)
                                    self.successStreak = 0
                                }
                            }
                        } catch {
                            var updatedFile = file
                            updatedFile.retryCount += 1
                            let newRetryCount = updatedFile.retryCount
                            
                            let isDisconnected = await MainActor.run {
                                (self.deviceManager?.isConnected == false) || self.isConnectionError(error)
                            }
                            let deviceSwitched = await MainActor.run {
                                if let current = ADBManager.activeDeviceSerial, let target = self.targetDeviceSerial {
                                    return current != target
                                }
                                return false
                            }
                            let isItemCancelled = await MainActor.run {
                                self.isCancelled(devicePath: file.devicePath)
                            }
                            let isBatchCanc = await MainActor.run { self.isBatchCancelled }
                            
                            if isDisconnected && newRetryCount <= 5 && !isBatchCanc && !isItemCancelled && !deviceSwitched {
                                print("📶 DownloadManager: Connection lost during download of \(file.fileName). Retry \(newRetryCount)/5. Re-enqueuing...")
                                
                                await MainActor.run {
                                    self.isConnectionOffline = true
                                    self.activeCongestionCap = max(2, self.activeCongestionCap / 2)
                                    self.successStreak = 0
                                    self.queueLock.lock()
                                    self.pendingFiles.insert(updatedFile, at: 0)
                                    self.queueLock.unlock()
                                }
                                connErrorOccurred = true
                                
                                // Update UI error status
                                await MainActor.run {
                                    if var progress = self.internalActiveDownloads[file.devicePath] {
                                        progress.error = "Connection lost (Retry \(newRetryCount)/5) - waiting for reconnect..."
                                        progress.transferSpeed = 0
                                        progress.retryCount = newRetryCount
                                        self.internalActiveDownloads[file.devicePath] = progress
                                        self.activeDownloads = self.internalActiveDownloads
                                    }
                                }
                                try? await Task.sleep(nanoseconds: 500_000_000)
                            } else {
                                // Permanent failure (either not a connection error, or exceeded max retries)
                                let finalError = newRetryCount > 5 ? NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed after 5 connection retries."]) : error
                                await MainActor.run {
                                    self.markDownloadFailed(devicePath: file.devicePath, error: finalError)
                                }
                            }
                        }
                        
                        await MainActor.run {
                            self.activeRunningLock.lock()
                            self.activeRunningCount -= 1
                            self.activeRunningLock.unlock()
                        }
                        
                        // Increment batch completion ONLY if it successfully transferred or failed permanently
                        let isBatchCanc = await MainActor.run { self.isBatchCancelled }
                        let isItemCanc = await MainActor.run { self.isCancelled(devicePath: file.devicePath) }
                        let currentId = await MainActor.run { self.currentBatchId }
                        if didSucceed || isItemCanc || (!isBatchCanc && !connErrorOccurred) {
                            if currentId == batchId {
                                await MainActor.run { self.batchCompleted += 1 }
                            }
                        }
                    }
                }
                
                if isBatchCancelled {
                    group.cancelAll()
                    break
                }
                
                // Check if there's more work pending or running
                queueLock.lock()
                let hasMore = !pendingFiles.isEmpty
                queueLock.unlock()
                
                activeRunningLock.lock()
                let finalRunning = activeRunningCount
                activeRunningLock.unlock()
                
                if finalRunning == 0 && !hasMore {
                    break
                }
                
                if finalRunning >= limit || (!hasMore && finalRunning > 0) {
                    await group.next()
                }
            }
            
            if isBatchCancelled {
                group.cancelAll()
            }
            
            await group.waitForAll()
        }
        
        queueLock.lock()
        isProcessingQueue = false
        queueLock.unlock()
        
        await MainActor.run {
            self.isBatchDownloading = false
            self.currentFolderName = ""
            self.activeDownloads = self.internalActiveDownloads
            self.stopTimerIfNeeded()
            self.uploadManager?.forceReevaluateConcurrencyLimit()
        }
        
        // End sleep prevention now that all downloads are done
        endPreventingSleep()
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
