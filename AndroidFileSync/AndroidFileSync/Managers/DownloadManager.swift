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
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSideEffectTime > 0.5 {
                lastSideEffectTime = now
                appManager?.operationEngine.processQueue()
                uploadManager?.triggerProcessQueue()
            }
        }
    }
    private var lastActiveDownloadsCount = 0
    private var lastSideEffectTime: CFAbsoluteTime = 0
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
    private var activeRunningCount: Int = 0
    private var activeRunningWeight: Double = 0.0
    
    var pendingQueueCount: Int {
        queueLock.lock()
        defer { queueLock.unlock() }
        return pendingFiles.count
    }
    
    var runningTransfersCount: Int {
        activeRunningLock.lock()
        defer { activeRunningLock.unlock() }
        return activeRunningCount
    }
    
    var runningTransfersWeight: Double {
        activeRunningLock.lock()
        defer { activeRunningLock.unlock() }
        return activeRunningWeight
    }
    
    /// Calculates dynamic slot weight based on file size
    /// Large files (> 50 MB) take 2.0 slots to avoid choking ADB/USB bus.
    /// Small files (< 2 MB) take 0.5 slots for fast parallel throughput.
    /// Medium files (2 MB - 50 MB) take 1.0 slot.
    private func slotWeight(for fileSize: UInt64) -> Double {
        if fileSize > 50 * 1024 * 1024 {
            return 2.0
        } else if fileSize < 2 * 1024 * 1024 {
            return 0.5
        } else {
            return 1.0
        }
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
            if oldValue != isBatchDownloading {
                updateTimer?.invalidate()
                updateTimer = nil
                if isBatchDownloading || !internalActiveDownloads.isEmpty {
                    startTimerIfNeeded()
                }
            }
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
    
    @Published var isAutoConcurrency: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoConcurrency, forKey: "isAutoConcurrencyDownloads")
            if !isAutoConcurrency {
                // User taking manual control — reset AIMD cap so prior error-halving
                // doesn't silently throttle their manually-chosen concurrency
                activeCongestionCap = maxConcurrent
                successStreak = 0
            }
            triggerProcessQueue()
        }
    }
    
    init() {
        let savedAuto = UserDefaults.standard.object(forKey: "isAutoConcurrencyDownloads") as? Bool ?? true
        self.isAutoConcurrency = savedAuto
        
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
        let clamped = saved > 0 ? min(max(saved, 1), kWiredMaxConcurrent) : 3
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
    
    // Throttled batch counter — updated in background, flushed to @Published by timer
    private var internalBatchCompleted: Int = 0
    
    // Coalesced removals to avoid per-file @Published updates during batch mode
    private var pendingRemovals: Set<String> = []
    
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
        let interval: TimeInterval = isBatchDownloading ? 0.5 : 1.0
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.flushUIUpdates()
        }
    }
    
    private func stopTimerIfNeeded() {
        guard internalActiveDownloads.isEmpty, !isBatchDownloading else { return }
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
    
    private func flushUIUpdates() {
        progressLock.lock()
        let updates = backgroundProgress
        let completedSnapshot = internalBatchCompleted
        progressLock.unlock()
        
        for (devicePath, (bytes, speed)) in updates {
            internalActiveDownloads[devicePath]?.bytesTransferred = bytes
            internalActiveDownloads[devicePath]?.transferSpeed = speed
        }
        
        let removals = pendingRemovals
        pendingRemovals.removeAll()
        if !removals.isEmpty {
            for devicePath in removals {
                internalActiveDownloads.removeValue(forKey: devicePath)
            }
            progressLock.lock()
            for devicePath in removals {
                backgroundProgress.removeValue(forKey: devicePath)
            }
            progressLock.unlock()
        }
        
        activeDownloads = internalActiveDownloads
        
        if completedSnapshot != batchCompleted {
            batchCompleted = completedSnapshot
        }
        
        if internalActiveDownloads.isEmpty && !isBatchDownloading {
            stopTimerIfNeeded()
        }
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
            self.pendingRemovals.remove(devicePath)
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
        
        // Drain the pending queue so nothing else starts
        queueLock.lock()
        pendingFiles.removeAll()
        queueLock.unlock()
        
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
            self.pendingRemovals.removeAll()
            self.activeDownloads.removeAll()
            self.isBatchDownloading = false
            self.batchTotal = 0
            self.batchCompleted = 0
            self.progressLock.lock()
            self.internalBatchCompleted = 0
            self.progressLock.unlock()
            self.currentFolderName = ""
            self.isScanning = false
            self.scanningFolderName = ""
            self.stopTimerIfNeeded()
            self.endPreventingSleep()
            
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
                maxDownloadCap = isAppBusy ? kWirelessDualBusyCap : kWirelessDualCap
            } else {
                maxDownloadCap = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
            }
        } else {
            if uploadsActive {
                maxDownloadCap = isAppBusy ? kWiredDualBusyCap : kWiredDualCap
            } else {
                maxDownloadCap = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
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
        if isCancelled(devicePath: devicePath) || isBatchCancelled {
            AppLogger.log("🛑 Download cancelled for \(devicePath)", level: .info)
            if var download = internalActiveDownloads[devicePath] {
                download.isCancelled = true
                download.error = nil
                download.transferSpeed = 0
                internalActiveDownloads[devicePath] = download
                if !isBatchDownloading {
                    activeDownloads = internalActiveDownloads
                }
            }
            return
        }
        AppLogger.log("❌ Download failed for \(devicePath): \(error.localizedDescription)", level: .error)
        if var download = internalActiveDownloads[devicePath] {
            download.error = error.localizedDescription
            download.transferSpeed = 0
            internalActiveDownloads[devicePath] = download
            if !isBatchDownloading {
                activeDownloads = internalActiveDownloads
            }
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
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
            }
            
            let batchActive = await MainActor.run { self.isBatchDownloading }
            
            Task.detached { [weak self] in
                let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: delayNs)
                
                await MainActor.run {
                    guard let self = self else { return }
                    if self.isBatchDownloading {
                        self.pendingRemovals.insert(devicePath)
                    } else {
                        self.internalActiveDownloads.removeValue(forKey: devicePath)
                        self.activeDownloads = self.internalActiveDownloads
                        self.stopTimerIfNeeded()
                    }
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
                if !self.isBatchDownloading {
                    self.activeDownloads = self.internalActiveDownloads
                }
            }
            
            // Show 100% briefly
            let batchActive = await MainActor.run { self.isBatchDownloading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                if self.isBatchDownloading {
                    self.pendingRemovals.insert(devicePath)
                } else {
                    self.internalActiveDownloads.removeValue(forKey: devicePath)
                    self.activeDownloads = self.internalActiveDownloads
                    self.stopTimerIfNeeded()
                }
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
                progressLock.lock()
                internalBatchCompleted = 0
                progressLock.unlock()
                batchCompleted = 0
            }
            isBatchDownloading = true
            
            let isWireless = self.deviceManager?.connectionType == .wireless
            let isAppBusy = self.appManager?.operationEngine.isBusy ?? false
            let uploadsActive = (self.uploadManager?.runningTransfersCount ?? 0) > 0 || (self.uploadManager?.isBatchUploading ?? false)
            let initialLimit: Int
            if isWireless {
                initialLimit = uploadsActive ? (isAppBusy ? 2 : 3) : (isAppBusy ? 4 : 5)
            } else {
                initialLimit = uploadsActive ? (isAppBusy ? kWiredDualBusyCap : kWiredDualCap) : min(self.maxConcurrent, isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent)
            }
            self.effectiveConcurrentLimit = initialLimit
            
            // Reset AIMD congestion cap:
            // - Solo mode: start at the full connection-type cap so AIMD immediately reacts to errors
            //   (e.g., 8 → error → 4 → error → 2, then recovers 3 successes at a time)
            // - Dual mode: start at initialLimit (conservative) so first error aggressively cuts bandwidth
            let soloMaxCap: Int
            if isWireless {
                soloMaxCap = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
            } else {
                soloMaxCap = min(self.maxConcurrent, isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent)
            }
            self.activeCongestionCap = uploadsActive ? initialLimit : soloMaxCap
            self.successStreak = 0
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
                    // Check if it's just a wireless port rotation on the same IP
                    if ADBManager.isWirelessSerial(currentSerial) && ADBManager.isWirelessSerial(targetSerial),
                       currentSerial.components(separatedBy: ":").first == targetSerial.components(separatedBy: ":").first {
                        // Port rotation on same wireless device — update target serial to match new port
                        await MainActor.run {
                            self.targetDeviceSerial = currentSerial
                        }
                    } else {
                        print("⚠️ DownloadManager: Explicit device switch from \(targetSerial) to \(currentSerial). Aborting batch download.")
                        await MainActor.run {
                            self.cancelAllDownloads()
                        }
                        break
                    }
                }
                
                // Concurrency adjustment for Wi-Fi + active app operations
                // These MUST be read on the main actor — deviceManager/appManager are @MainActor-bound
                let (isWireless, isAppBusy) = await MainActor.run {
                    let wireless = self.deviceManager?.connectionType == .wireless
                    let busy = self.appManager?.operationEngine.isBusy ?? false
                    return (wireless, busy)
                }
                
                // Connection protection: if device is offline, pause queue processing
                let isOffline = (deviceManager.map { !$0.isConnected } ?? true) || isConnectionOffline
                if isOffline {
                    await MainActor.run {
                        for (devicePath, var download) in internalActiveDownloads where !download.isComplete && !download.isCancelled {
                            download.error = "Device offline - waiting for reconnect..."
                            download.transferSpeed = 0
                            internalActiveDownloads[devicePath] = download
                        }
                        if !isBatchDownloading {
                            activeDownloads = internalActiveDownloads
                        }
                    }
                    try? await Task.sleep(nanoseconds: kOfflineCheckIntervalNs)
                    
                    // Reset our local offline flag if device is back online according to deviceManager
                    if let dm = deviceManager, dm.isConnected {
                        isConnectionOffline = false
                        // WiFi reconnect stabilization: give ADB transport time to settle
                        // before dispatching new transfers, preventing immediate re-drops
                        if isWireless {
                            try? await Task.sleep(nanoseconds: kReconnectStabilizationDelayNs)
                        }
                    }
                    continue
                }
                
                // Dynamic wireless/wired concurrency limit with smart asymmetric slot borrowing
                let activeUploadsCount = uploadManager?.runningTransfersCount ?? 0
                let pendingUploadsCount = uploadManager?.pendingQueueCount ?? 0
                // Include isBatchUploading to cover the startup race window where uploads have
                // started but haven't dispatched tasks yet (runningCount=0, pendingCount=0)
                let isBatchUpload = await MainActor.run { self.uploadManager?.isBatchUploading ?? false }
                let uploadsActive = activeUploadsCount > 0
                let isOppositeDemandActive = uploadsActive || pendingUploadsCount > 0 || isBatchUpload
                
                let globalCombinedLimit: Int
                let maxDownloadCap: Int
                if isWireless {
                    if isOppositeDemandActive {
                        // 50-50 Wi-Fi allocation
                        globalCombinedLimit = isAppBusy ? (kWirelessDualBusyCap * 2) : kWirelessMaxConcurrent
                        maxDownloadCap = isAppBusy ? kWirelessDualBusyCap : kWirelessDualCap
                    } else {
                        globalCombinedLimit = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
                        maxDownloadCap = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
                    }
                } else {
                    if isOppositeDemandActive {
                        // 50-50 USB allocation
                        globalCombinedLimit = isAppBusy ? (kWiredDualBusyCap * 2) : kWiredMaxConcurrent
                        maxDownloadCap = isAppBusy ? kWiredDualBusyCap : kWiredDualCap
                    } else {
                        globalCombinedLimit = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
                        maxDownloadCap = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
                    }
                }
                if !isOppositeDemandActive {
                    await MainActor.run { self.temporaryMaxConcurrent = nil }
                }
                
                let baseMax = await MainActor.run { self.isAutoConcurrency ? maxDownloadCap : (self.temporaryMaxConcurrent ?? self.preferredMaxConcurrent) }
                let targetMax = min(fixedMax ?? baseMax, maxDownloadCap)
                if self.maxConcurrent != targetMax {
                    await MainActor.run {
                        self.isAutoClamping = true
                        self.maxConcurrent = targetMax
                        self.isAutoClamping = false
                    }
                }
                
                var limit = min(fixedMax ?? self.maxConcurrent, maxDownloadCap)
                // AIMD congestion cap only applies in auto mode.
                // In manual mode the user explicitly owns the concurrency value.
                let isAuto = await MainActor.run { self.isAutoConcurrency }
                if isAuto {
                    limit = min(limit, self.activeCongestionCap)
                }
                
                let oppositeWeight = uploadManager?.runningTransfersWeight ?? 0.0
                let maxDownloadsAllowed = max(1, Int(Double(globalCombinedLimit) - oppositeWeight))
                limit = min(limit, maxDownloadsAllowed)
                
                // Hard ceiling — can never exceed the connection-type cap under any circumstance
                limit = min(limit, maxDownloadCap)
                
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
                var dispatchedThisRound = 0
                while running < limit && !isBatchCancelled {
                    queueLock.lock()
                    let nextFile = pendingFiles.isEmpty ? nil : pendingFiles.removeFirst()
                    queueLock.unlock()
                    
                    guard let file = nextFile else { break }
                    
                    let weight = slotWeight(for: file.fileSize)
                    
                    // WiFi weight guard: large video files (>50MB) consume 2.0 slots each.
                    // Without this, limit=4 would dispatch 4 large videos (total weight 8.0),
                    // overwhelming WiFi ADB transport. With this guard, only 2 large videos
                    // run concurrently (2×2.0=4.0 ≤ 4), while 8 small files can still burst (8×0.5=4.0).
                    if isWireless {
                        activeRunningLock.lock()
                        let currentWeight = activeRunningWeight
                        activeRunningLock.unlock()
                        if currentWeight + weight > Double(limit) && running > 0 {
                            // Would exceed weight budget — put file back and stop dispatching
                            queueLock.lock()
                            pendingFiles.insert(file, at: 0)
                            queueLock.unlock()
                            break
                        }
                    }
                    
                    // WiFi stagger: ADB's wireless transport is TCP-based and fragile.
                    // Burst-dispatching multiple pull processes simultaneously overwhelms
                    // the connection, causing drops. A 200ms gap lets ADB stabilize each new connection.
                    if isWireless && dispatchedThisRound > 0 {
                            try? await Task.sleep(nanoseconds: kWiFiStaggerDelayNs)
                    }
                    dispatchedThisRound += 1
                    
                    activeRunningLock.lock()
                    activeRunningCount += 1
                    activeRunningWeight += weight
                    running = activeRunningCount
                    activeRunningLock.unlock()
                    
                    group.addTask {
                        defer {
                            self.activeRunningLock.lock()
                            self.activeRunningCount -= 1
                            self.activeRunningWeight = max(0.0, self.activeRunningWeight - weight)
                            self.activeRunningLock.unlock()
                        }
                        
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
                            
                            // Success path: gradually restore congestion cap (AIMD Additive Increase)
                            let aimdEnabled = await MainActor.run { self.isAutoConcurrency }
                            if aimdEnabled {
                                await MainActor.run {
                                    self.successStreak += 1
                                    if self.successStreak >= 3 {
                                        self.activeCongestionCap = min(maxDownloadCap, self.activeCongestionCap + 1)
                                        self.successStreak = 0
                                    }
                                }
                            }
                        } catch {
                            var updatedFile = file
                            updatedFile.retryCount += 1
                            let newRetryCount = updatedFile.retryCount
                            
                            // AIMD Multiplicative Decrease: Cut congestion cap on error/stall
                            let aimdEnabled = await MainActor.run { self.isAutoConcurrency }
                            if aimdEnabled {
                                await MainActor.run {
                                    self.successStreak = 0
                                    self.activeCongestionCap = max(2, self.activeCongestionCap / 2)
                                }
                            }
                            
                            let isDisconnected = await MainActor.run {
                                (self.deviceManager?.isConnected == false) || self.isConnectionError(error)
                            }
                            let deviceSwitched = await MainActor.run {
                                if let current = ADBManager.activeDeviceSerial, let target = self.targetDeviceSerial {
                                    // If both are wireless, compare the IP addresses instead of the port!
                                    if ADBManager.isWirelessSerial(current) && ADBManager.isWirelessSerial(target) {
                                        let currentIP = current.components(separatedBy: ":").first ?? ""
                                        let targetIP = target.components(separatedBy: ":").first ?? ""
                                        return currentIP != targetIP
                                    }
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
                                    if self.isAutoConcurrency {
                                        self.activeCongestionCap = max(2, self.activeCongestionCap / 2)
                                        self.successStreak = 0
                                    }
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
                                        if !self.isBatchDownloading {
                                            self.activeDownloads = self.internalActiveDownloads
                                        }
                                    }
                                }
                                try? await Task.sleep(nanoseconds: kConnectionRetryDelayNs)
                            } else {
                                // Permanent failure (either not a connection error, or exceeded max retries)
                                let finalError = newRetryCount > 5 ? NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed after 5 connection retries."]) : error
                                await MainActor.run {
                                    self.markDownloadFailed(devicePath: file.devicePath, error: finalError)
                                }
                            }
                        }
                        
                        
                        // Increment batch completion ONLY if it successfully transferred or failed permanently
                        let isBatchCanc = await MainActor.run { self.isBatchCancelled }
                        let isItemCanc = await MainActor.run { self.isCancelled(devicePath: file.devicePath) }
                        let currentId = await MainActor.run { self.currentBatchId }
                        if didSucceed || isItemCanc || (!isBatchCanc && !connErrorOccurred) {
                            if currentId == batchId {
                                self.progressLock.lock()
                                self.internalBatchCompleted += 1
                                self.progressLock.unlock()
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
            self.internalActiveDownloads.removeAll()
            self.pendingRemovals.removeAll()
            self.activeDownloads.removeAll()
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
