//
//  UploadManager.swift
//  AndroidFileSync
//
//  Uses AsyncStream polling for progress (like DownloadManager)
//
import Foundation
internal import Combine

class UploadManager: ObservableObject {
    @Published var activeUploads: [String: UploadProgress] = [:] {
        didSet {
            let count = activeUploads.count
            if count != lastActiveUploadsCount {
                lastActiveUploadsCount = count
                NotificationCenter.default.post(
                    name: .afsTransferCountChanged,
                    object: nil,
                    userInfo: ["type": "upload", "count": count]
                )
            }
            appManager?.operationEngine.processQueue()
            downloadManager?.triggerProcessQueue()
        }
    }
    private var lastActiveUploadsCount = 0
    private var internalActiveUploads: [String: UploadProgress] = [:]
    weak var deviceManager: DeviceManager?
    weak var appManager: AppManager?
    weak var downloadManager: DownloadManager?
    private var isConnectionOffline = false
    private var savedWirelessLimitBeforeBackup: Int? = nil
    private var targetDeviceSerial: String? = nil
    
    private var currentBatchId: UUID = UUID()
    
    @Published var batchTotal: Int = 0
    @Published var batchCompleted: Int = 0 {
        didSet {
            NotificationCenter.default.post(
                name: .afsUploadBatchCompleted,
                object: nil,
                userInfo: [
                    "completed": batchCompleted,
                    "total": batchTotal
                ]
            )
        }
    }
    @Published var isBatchUploading: Bool = false {
        didSet {
            NotificationCenter.default.post(
                name: .afsUploadBatchStateChanged,
                object: nil,
                userInfo: [
                    "isUploading": isBatchUploading,
                    "batchTotal": batchTotal
                ]
            )
        }
    }
    @Published var batchCancelled: Bool = false
    
    @Published var isPreparing: Bool = false
    @Published var preparingMessage: String = ""
    
    private var isAutoClamping = false
    private var preferredMaxConcurrent: Int = 3
    private var temporaryMaxConcurrent: Int? = nil
    
    @Published var maxConcurrent: Int = 3 {
        didSet {
            if !isAutoClamping {
                let activeDownloadsCount = downloadManager?.runningTransfersCount ?? 0
                let isDual = activeDownloadsCount > 0
                
                if isDual {
                    temporaryMaxConcurrent = maxConcurrent
                } else {
                    temporaryMaxConcurrent = nil
                    preferredMaxConcurrent = maxConcurrent
                    UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrentUploads")
                }
            }
            triggerProcessQueue()
        }
    }
    
    @Published var effectiveConcurrentLimit: Int = 3
    
    private let progressLock = NSLock()
    private var backgroundProgress: [String: (bytes: UInt64, speed: Double)] = [:]
    
    private var cancellationFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    
    private var updateTimer: Timer?
    
    private var transferActivity: NSObjectProtocol?
    private let activityLock = NSLock()
    
struct UploadQueueItem {
    let localPath: String
    let fileName: String
    let fileSize: UInt64
    let devicePath: String
    var retryCount: Int = 0
}

    // Shared upload queue — new drops append here instead of starting a separate batch
    private let queueLock = NSLock()
    private var pendingFiles: [UploadQueueItem] = []
    private var isProcessingQueue = false
    private var activeCongestionCap: Int = 10
    private var successStreak: Int = 0
    
    // Throttled batch counter — updated in background, flushed to @Published by timer
    private var internalBatchCompleted: Int = 0
    
    // Active running tasks counter for queue processor
    private let activeRunningLock = NSLock()
    private var activeRunningCount = 0
    
    var runningTransfersCount: Int {
        activeRunningLock.lock()
        defer { activeRunningLock.unlock() }
        return activeRunningCount
    }
    
    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentUploads")
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
            reason: "Uploading files to Android device via ADB"
        )
    }
    
    private func endPreventingSleep() {
        activityLock.lock()
        defer { activityLock.unlock() }
        guard let activity = transferActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        transferActivity = nil
    }
    
    struct UploadProgress: Identifiable {
        let id = UUID()
        let fileName: String
        let localPath: String
        let devicePath: String
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
    
    // MARK: - Timer Management
    
    private func startTimerIfNeeded() {
        guard updateTimer == nil else { return }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushUIUpdates()
        }
    }
    
    private func stopTimerIfNeeded() {
        guard activeUploads.isEmpty, !isBatchUploading else { return }
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func flushUIUpdates() {
        progressLock.lock()
        let updates = backgroundProgress
        let completedSnapshot = internalBatchCompleted
        progressLock.unlock()
        
        for (localPath, (bytes, speed)) in updates {
            if var upload = internalActiveUploads[localPath] {
                upload.bytesTransferred = bytes
                upload.transferSpeed = speed
                internalActiveUploads[localPath] = upload
            }
        }
        
        // Single batch update to @Published property to minimize SwiftUI updates
        activeUploads = internalActiveUploads
        
        if completedSnapshot != batchCompleted {
            batchCompleted = completedSnapshot
        }
    }
    
    deinit {
        updateTimer?.invalidate()
        endPreventingSleep()
    }

    @MainActor
    func forceReevaluateConcurrencyLimit() {
        let isWireless = deviceManager?.connectionType == .wireless
        let isAppBusy = appManager?.operationEngine.isBusy ?? false
        let activeDownloadsCount = downloadManager?.runningTransfersCount ?? 0
        let downloadsActive = activeDownloadsCount > 0
        
        let maxUploadCap: Int
        if isWireless {
            if downloadsActive {
                maxUploadCap = isAppBusy ? 3 : 4
            } else {
                maxUploadCap = isAppBusy ? 6 : 8
            }
        } else {
            if downloadsActive {
                maxUploadCap = isAppBusy ? 5 : 8
            } else {
                maxUploadCap = isAppBusy ? 10 : 10
            }
        }
        
        let targetMax = min(preferredMaxConcurrent, maxUploadCap)
        if self.maxConcurrent != targetMax {
            self.isAutoClamping = true
            self.maxConcurrent = targetMax
            self.isAutoClamping = false
        }
    }

    @MainActor
    private func markUploadFailed(localPath: String, error: Error) {
        AppLogger.log("❌ Upload failed for \(localPath): \(error.localizedDescription)", level: .error)
        if var upload = internalActiveUploads[localPath] {
            upload.error = error.localizedDescription
            upload.transferSpeed = 0
            internalActiveUploads[localPath] = upload
            activeUploads = internalActiveUploads
        }
        progressLock.lock()
        backgroundProgress.removeValue(forKey: localPath)
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
    
    // MARK: - Cancellation
    
    private func isCancelled(localPath: String) -> Bool {
        flagLock.lock()
        defer { flagLock.unlock() }
        return cancellationFlags[localPath] ?? false
    }
    
    private func setCancelled(localPath: String, value: Bool) {
        flagLock.lock()
        cancellationFlags[localPath] = value
        flagLock.unlock()
    }
    
    func cancelUpload(localPath: String) {
        setCancelled(localPath: localPath, value: true)
        
        if var upload = internalActiveUploads[localPath] {
            upload.isCancelled = true
            internalActiveUploads[localPath] = upload
            activeUploads = internalActiveUploads
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.internalActiveUploads.removeValue(forKey: localPath)
            self.activeUploads = self.internalActiveUploads
            self.stopTimerIfNeeded()
            
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: localPath)
            self.progressLock.unlock()
            
            self.flagLock.lock()
            self.cancellationFlags.removeValue(forKey: localPath)
            self.flagLock.unlock()
        }
    }
    
    func cancelAllUploads() {
        batchCancelled = true
        isBatchUploading = false
        
        // Drain the pending queue so nothing else starts
        queueLock.lock()
        pendingFiles.removeAll()
        queueLock.unlock()
        
        flagLock.lock()
        for key in cancellationFlags.keys {
            cancellationFlags[key] = true
        }
        for key in internalActiveUploads.keys {
            cancellationFlags[key] = true
        }
        flagLock.unlock()
        
        for key in internalActiveUploads.keys {
            internalActiveUploads[key]?.isCancelled = true
        }
        activeUploads = internalActiveUploads
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            self.internalActiveUploads.removeAll()
            self.activeUploads.removeAll()
            self.stopTimerIfNeeded()
            
            self.progressLock.lock()
            self.backgroundProgress.removeAll()
            self.internalBatchCompleted = 0
            self.progressLock.unlock()
            
            self.flagLock.lock()
            self.cancellationFlags.removeAll()
            self.flagLock.unlock()
            
            self.batchTotal = 0
            self.batchCompleted = 0
            self.downloadManager?.forceReevaluateConcurrencyLimit()
        }
    }
    
    func uploadFile(
        localPath: String,
        fileName: String,
        fileSize: UInt64,
        to devicePath: String,
        retryCount: Int = 0
    ) async throws {
        if batchCancelled { return }
        
        let (safeFileName, _) = FileNameHelper.getSafeFilename(fileName)
        
        let safeDevicePath: String
        if devicePath.hasSuffix("/") {
            safeDevicePath = devicePath + safeFileName
        } else {
            safeDevicePath = devicePath + "/" + safeFileName
        }
        
        let progress = UploadProgress(
            fileName: safeFileName,
            localPath: localPath,
            devicePath: safeDevicePath,
            totalBytes: fileSize,
            retryCount: retryCount
        )
        
        beginPreventingSleep()
        
        await MainActor.run {
            internalActiveUploads[localPath] = progress
            activeUploads = internalActiveUploads
            startTimerIfNeeded()
        }
        
        setCancelled(localPath: localPath, value: false)
        
        let progressStream = ADBManager.pushFileWithProgress(
            localPath: localPath,
            devicePath: safeDevicePath,
            totalBytes: fileSize,
            cancellationCheck: { [weak self] in
                self?.isCancelled(localPath: localPath) ?? false
            }
        )
        
        do {
            for try await (bytesTransferred, speed) in progressStream {
                if isCancelled(localPath: localPath) { return }
                
                progressLock.lock()
                backgroundProgress[localPath] = (bytesTransferred, speed)
                progressLock.unlock()
            }
        } catch {
            await markUploadFailed(localPath: localPath, error: error)
            throw error
        }
        
        if isCancelled(localPath: localPath) { return }
        
        progressLock.lock()
        backgroundProgress.removeValue(forKey: localPath)
        progressLock.unlock()
        
        AppLogger.log("✅ File uploaded successfully: \(fileName) (\(fileSize) bytes)")
        
        await MainActor.run {
            if var upload = internalActiveUploads[localPath] {
                upload.isComplete = true
                upload.bytesTransferred = fileSize
                upload.transferSpeed = 0
                internalActiveUploads[localPath] = upload
                activeUploads = internalActiveUploads
            }
        }
        
        let batchUploading = isBatchUploading
        
        Task.detached { [weak self] in
            
            let delayNs: UInt64 = batchUploading ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self?.internalActiveUploads.removeValue(forKey: localPath)
                if let dict = self?.internalActiveUploads {
                    self?.activeUploads = dict
                }
                self?.stopTimerIfNeeded()
            }
            
            self?.flagLock.lock()
            self?.cancellationFlags.removeValue(forKey: localPath)
            self?.flagLock.unlock()
            
            let shouldEndSleep = await MainActor.run {
                !(self?.isBatchUploading ?? false) && (self?.activeUploads.isEmpty ?? true)
            }
            if shouldEndSleep {
                self?.endPreventingSleep()
            }
        }
    }
    
    // MARK: - Parallel Upload Support
    
    @discardableResult
    func startUpload(
        localPath: String,
        fileName: String,
        fileSize: UInt64,
        to devicePath: String
    ) -> Task<Void, Never> {
        let (safeFileName, _) = FileNameHelper.getSafeFilename(fileName)
        
        let safeDevicePath: String
        if devicePath.hasSuffix("/") {
            safeDevicePath = devicePath + safeFileName
        } else {
            safeDevicePath = devicePath + "/" + safeFileName
        }
        
        let progress = UploadProgress(
            fileName: safeFileName,
            localPath: localPath,
            devicePath: safeDevicePath,
            totalBytes: fileSize
        )
        
        Task { @MainActor in
            internalActiveUploads[localPath] = progress
            if !isBatchUploading {
                activeUploads = internalActiveUploads
            }
            startTimerIfNeeded()
        }
        
        setCancelled(localPath: localPath, value: false)
        
        let uploadTask = Task.detached { [weak self] in
            guard let self = self else { return }
            
            let progressStream = ADBManager.pushFileWithProgress(
                localPath: localPath,
                devicePath: safeDevicePath,
                totalBytes: fileSize,
                cancellationCheck: { [weak self] in
                    self?.isCancelled(localPath: localPath) ?? false
                }
            )
            
            do {
                for try await (bytesTransferred, speed) in progressStream {
                    if self.isCancelled(localPath: localPath) { return }
                    
                    self.progressLock.lock()
                    self.backgroundProgress[localPath] = (bytesTransferred, speed)
                    self.progressLock.unlock()
                }
            } catch {
                await self.markUploadFailed(localPath: localPath, error: error)
                return
            }
            
            if self.isCancelled(localPath: localPath) { return }
            
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: localPath)
            self.progressLock.unlock()
            
            await MainActor.run {
                self.internalActiveUploads[localPath]?.isComplete = true
                self.internalActiveUploads[localPath]?.bytesTransferred = fileSize
                self.internalActiveUploads[localPath]?.transferSpeed = 0
                self.activeUploads = self.internalActiveUploads
            }
            
            await ADBManager.triggerMediaScan(path: safeDevicePath)
            
            let batchActive = await MainActor.run { self.isBatchUploading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self.internalActiveUploads.removeValue(forKey: localPath)
                self.activeUploads = self.internalActiveUploads
                self.stopTimerIfNeeded()
            }
            
            self.flagLock.lock()
            self.cancellationFlags.removeValue(forKey: localPath)
            self.flagLock.unlock()
            
            let shouldEndSleep = await MainActor.run {
                !self.isBatchUploading && self.activeUploads.isEmpty
            }
            if shouldEndSleep {
                self.endPreventingSleep()
            }
        }
        
        return uploadTask
    }
    
    // MARK: - Shared Upload Queue
    
    func enqueueFiles(
        files: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)]
    ) {
        guard !files.isEmpty else { return }
        
        queueLock.lock()
        let items = files.map { UploadQueueItem(localPath: $0.localPath, fileName: $0.fileName, fileSize: $0.fileSize, devicePath: $0.devicePath) }
        pendingFiles.append(contentsOf: items)
        let shouldStart = !isProcessingQueue
        if shouldStart { isProcessingQueue = true }
        queueLock.unlock()
        
        Task { @MainActor in
            self.targetDeviceSerial = ADBManager.activeDeviceSerial
            if self.isBatchUploading {
                self.batchTotal += files.count
            } else {
                self.currentBatchId = UUID()
                self.batchTotal = files.count
                
                self.progressLock.lock()
                self.internalBatchCompleted = 0
                self.progressLock.unlock()
                self.batchCompleted = 0
                
                self.isBatchUploading = true
                self.batchCancelled = false
                self.startTimerIfNeeded()
            }
            
            let isWireless = self.deviceManager?.connectionType == .wireless
            let isAppBusy = self.appManager?.operationEngine.isBusy ?? false
            let downloadsActive = (self.downloadManager?.runningTransfersCount ?? 0) > 0 || (self.downloadManager?.isBatchDownloading ?? false)
            if isWireless {
                self.effectiveConcurrentLimit = downloadsActive ? (isAppBusy ? 2 : 3) : (isAppBusy ? 4 : 5)
            } else {
                self.effectiveConcurrentLimit = downloadsActive ? (isAppBusy ? 5 : 6) : min(self.maxConcurrent, isAppBusy ? 10 : 12)
            }
        }
        
        if shouldStart {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.processQueue()
            }
        }
    }
    
    /// Uploads multiple files in parallel to the SAME directory
    func uploadMultipleFiles(
        files: [(localPath: String, fileName: String, fileSize: UInt64)],
        toDirectory devicePath: String
    ) async {
        guard !files.isEmpty else { return }
        
        let items = files.map { file in
            (localPath: file.localPath, fileName: file.fileName, fileSize: file.fileSize, devicePath: devicePath)
        }
        enqueueFiles(files: items)
    }
    
    /// Legacy entry point — routes through the shared queue
    func uploadFilesToPaths(
        files: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)]
    ) async {
        enqueueFiles(files: files)
    }
    
    func triggerProcessQueue() {
        queueLock.lock()
        let shouldStart = !isProcessingQueue && !pendingFiles.isEmpty
        if shouldStart { isProcessingQueue = true }
        queueLock.unlock()
        
        if shouldStart {
            Task.detached(priority: .userInitiated) { [weak self] in
                await self?.processQueue()
            }
        }
    }
    
    private func processQueue() async {
        beginPreventingSleep()
        
        let batchId = await MainActor.run { self.currentBatchId }
        
        var scannedFiles = Set<String>()
        
        await withTaskGroup(of: Void.self) { group in
            while !batchCancelled {
                // Check if target device has switched explicitly (ignore transient nil during ADB refreshes)
                if let currentSerial = ADBManager.activeDeviceSerial, let targetSerial = targetDeviceSerial, currentSerial != targetSerial {
                    print("⚠️ UploadManager: Explicit device switch from \(targetSerial) to \(currentSerial). Aborting batch upload.")
                    await MainActor.run {
                        self.cancelAllUploads()
                    }
                    break
                }
                
                
                
                // Concurrency adjustment for Wi-Fi + active app operations
                let isWireless = deviceManager?.connectionType == .wireless
                let isAppBusy = appManager?.operationEngine.isBusy ?? false
                
                if isWireless && isAppBusy {
                    if savedWirelessLimitBeforeBackup == nil {
                        if maxConcurrent > 6 {
                            savedWirelessLimitBeforeBackup = maxConcurrent
                            await MainActor.run {
                                self.maxConcurrent = 6
                            }
                        }
                    }
                } else {
                    if let savedLimit = savedWirelessLimitBeforeBackup {
                        await MainActor.run {
                            self.maxConcurrent = savedLimit
                        }
                        savedWirelessLimitBeforeBackup = nil
                    }
                }
                
                // Connection protection: if device is offline, pause queue processing
                let isOffline = (deviceManager.map { !$0.isConnected } ?? true) || isConnectionOffline
                if isOffline {
                    await MainActor.run {
                        for (localPath, var upload) in internalActiveUploads where !upload.isComplete && !upload.isCancelled {
                            upload.error = "Device offline - waiting for reconnect..."
                            upload.transferSpeed = 0
                            internalActiveUploads[localPath] = upload
                        }
                        activeUploads = internalActiveUploads
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000) // Sleep 1 second
                    
                    // Reset our local offline flag if device is back online according to deviceManager
                    if let dm = deviceManager, dm.isConnected {
                        isConnectionOffline = false
                    }
                    continue
                }
                
                // Dynamic wireless/wired concurrency limit with 50/50 cross-direction slot budgeting
                let activeDownloadsCount = downloadManager?.runningTransfersCount ?? 0
                let downloadsActive = activeDownloadsCount > 0
                
                let globalCombinedLimit: Int
                let maxUploadCap: Int
                if isWireless {
                    if downloadsActive {
                        // 50-50 Wi-Fi allocation: 4 uploads + 4 downloads = 8 total (or 3+3 if app ops active)
                        globalCombinedLimit = isAppBusy ? 6 : 8
                        maxUploadCap = isAppBusy ? 3 : 4
                    } else {
                        globalCombinedLimit = isAppBusy ? 6 : 8
                        maxUploadCap = isAppBusy ? 6 : 8
                    }
                } else {
                    if downloadsActive {
                        // USB allocation: 8 uploads + 8 downloads = 16 total (or 5+5 if app ops active)
                        globalCombinedLimit = isAppBusy ? 10 : 16
                        maxUploadCap = isAppBusy ? 5 : 8
                    } else {
                        globalCombinedLimit = isAppBusy ? 10 : 16
                        maxUploadCap = isAppBusy ? 10 : 10
                    }
                }
                if !downloadsActive {
                    await MainActor.run { self.temporaryMaxConcurrent = nil }
                }
                
                let baseMax = await MainActor.run { self.temporaryMaxConcurrent ?? self.preferredMaxConcurrent }
                let targetMax = min(baseMax, maxUploadCap)
                if self.maxConcurrent != targetMax {
                    await MainActor.run { 
                        self.isAutoClamping = true
                        self.maxConcurrent = targetMax 
                        self.isAutoClamping = false
                    }
                }
                
                var limit = min(self.maxConcurrent, maxUploadCap)
                limit = min(limit, self.activeCongestionCap)
                
                let maxUploadsAllowed = max(1, globalCombinedLimit - activeDownloadsCount)
                limit = min(limit, maxUploadsAllowed)
                
                let newLimit = limit
                await MainActor.run {
                    if self.effectiveConcurrentLimit != newLimit {
                        self.effectiveConcurrentLimit = newLimit
                    }
                }
                
                activeRunningLock.lock()
                var running = activeRunningCount
                activeRunningLock.unlock()
                
                // Try to fill slots from the pending queue
                while running < limit && !batchCancelled {
                    queueLock.lock()
                    let nextFile = pendingFiles.isEmpty ? nil : pendingFiles.removeFirst()
                    queueLock.unlock()
                    
                    guard let file = nextFile else { break }
                    
                    let (safeName, _) = FileNameHelper.getSafeFilename(file.fileName)
                    let fullDevicePath = file.devicePath.hasSuffix("/")
                        ? file.devicePath + safeName
                        : file.devicePath + "/" + safeName
                    
                    scannedFiles.insert(fullDevicePath)
                    
                    activeRunningLock.lock()
                    activeRunningCount += 1
                    running = activeRunningCount
                    activeRunningLock.unlock()
                    
                    group.addTask {
                        var didSucceed = false
                        var connErrorOccurred = false
                        do {
                             try await self.uploadFile(
                                 localPath: file.localPath,
                                 fileName: file.fileName,
                                 fileSize: file.fileSize,
                                 to: file.devicePath,
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
                                self.isCancelled(localPath: file.localPath)
                            }
                            let isBatchCanc = await MainActor.run { self.batchCancelled }
                            
                            if isDisconnected && newRetryCount <= 5 && !isBatchCanc && !isItemCancelled && !deviceSwitched {
                                print("📶 UploadManager: Connection lost during upload of \(file.fileName). Retry \(newRetryCount)/5. Re-enqueuing...")
                                
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
                                    if var progress = self.internalActiveUploads[file.localPath] {
                                        progress.error = "Connection lost (Retry \(newRetryCount)/5) - waiting for reconnect..."
                                        progress.transferSpeed = 0
                                        progress.retryCount = newRetryCount
                                        self.internalActiveUploads[file.localPath] = progress
                                        self.activeUploads = self.internalActiveUploads
                                    }
                                }
                                try? await Task.sleep(nanoseconds: 500_000_000)
                            } else {
                                // Permanent failure (either not a connection error, or exceeded max retries)
                                let finalError = newRetryCount > 5 ? NSError(domain: "UploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed after 5 connection retries."]) : error
                                await MainActor.run {
                                    self.markUploadFailed(localPath: file.localPath, error: finalError)
                                }
                            }
                        }
                        
                        await MainActor.run {
                            self.activeRunningLock.lock()
                            self.activeRunningCount -= 1
                            self.activeRunningLock.unlock()
                        }
                        
                        // Increment batch completion ONLY if it successfully transferred or failed permanently
                        let isBatchCanc = await MainActor.run { self.batchCancelled }
                        let isItemCanc = await MainActor.run { self.isCancelled(localPath: file.localPath) }
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
                
                if batchCancelled {
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
            
            if batchCancelled {
                group.cancelAll()
            }
            
            await group.waitForAll()
        }
        
        // Scan all modified files in chunks in the background
        let filesToScan = Array(scannedFiles)
        Task.detached {
            await ADBManager.triggerMediaScanForFiles(filesToScan)
        }
        
        queueLock.lock()
        isProcessingQueue = false
        queueLock.unlock()
        
        await MainActor.run {
            self.flushUIUpdates()
            self.isBatchUploading = false
            self.stopTimerIfNeeded()
            self.downloadManager?.forceReevaluateConcurrencyLimit()
        }
        
        endPreventingSleep()
        
        if batchCancelled {
            let completed = await MainActor.run { batchCompleted }
            AppLogger.log("🛑 Batch upload cancelled at \(completed)/\(batchTotal)", level: .warning)
        } else {
            let total = await MainActor.run { batchTotal }
            AppLogger.log("✅ All \(total) uploads completed", level: .info)
        }
    }
}
