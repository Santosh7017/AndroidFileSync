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
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastSideEffectTime > 0.5 {
                lastSideEffectTime = now
                appManager?.operationEngine.processQueue()
                downloadManager?.triggerProcessQueue()
            }
        }
    }
    private var lastActiveUploadsCount = 0
    private var lastSideEffectTime: CFAbsoluteTime = 0
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
            if oldValue != isBatchUploading {
                updateTimer?.invalidate()
                updateTimer = nil
                if isBatchUploading || !internalActiveUploads.isEmpty {
                    startTimerIfNeeded()
                }
            }
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
    private var activeCongestionCap: Int = 12
    private var successStreak: Int = 0
    
    // Throttled batch counter — updated in background, flushed to @Published by timer
    private var internalBatchCompleted: Int = 0
    
    // Coalesced removals to avoid per-file @Published updates during batch mode
    private var pendingRemovals: Set<String> = []
    
    // Timestamp pairs collected during batch uploads — flushed as batched `touch -t` after completion.
    // Stored as (devicePath, macModificationDate) so we can restore the original mtime on Android.
    private var uploadedTimestamps: [(devicePath: String, date: Date)] = []
    private let timestampLock = NSLock()
    
    // Active running tasks counter for queue processor
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
    
    @Published var isAutoConcurrency: Bool = true {
        didSet {
            UserDefaults.standard.set(isAutoConcurrency, forKey: "isAutoConcurrencyUploads")
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
        self.isAutoConcurrency = true
        
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentUploads")
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
        let interval: TimeInterval = isBatchUploading ? 0.5 : 1.0
        updateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.flushUIUpdates()
        }
    }
    
    private func stopTimerIfNeeded() {
        guard internalActiveUploads.isEmpty, !isBatchUploading else { return }
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
        
        let removals = pendingRemovals
        pendingRemovals.removeAll()
        if !removals.isEmpty {
            for localPath in removals {
                internalActiveUploads.removeValue(forKey: localPath)
            }
            progressLock.lock()
            for localPath in removals {
                backgroundProgress.removeValue(forKey: localPath)
            }
            progressLock.unlock()
        }
        
        // Single batch update to @Published property to minimize SwiftUI updates
        activeUploads = internalActiveUploads
        
        if completedSnapshot != batchCompleted {
            batchCompleted = completedSnapshot
        }
        
        if internalActiveUploads.isEmpty && !isBatchUploading {
            stopTimerIfNeeded()
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
                maxUploadCap = isAppBusy ? kWirelessDualBusyCap : kWirelessDualCap
            } else {
                maxUploadCap = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
            }
        } else {
            if downloadsActive {
                maxUploadCap = isAppBusy ? kWiredDualBusyCap : kWiredDualCap
            } else {
                maxUploadCap = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
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
        if isCancelled(localPath: localPath) || batchCancelled {
            AppLogger.log("🛑 Upload cancelled for \(localPath)", level: .info)
            if var upload = internalActiveUploads[localPath] {
                upload.isCancelled = true
                upload.error = nil
                upload.transferSpeed = 0
                internalActiveUploads[localPath] = upload
                if !isBatchUploading {
                    activeUploads = internalActiveUploads
                }
            }
            return
        }
        AppLogger.log("❌ Upload failed for \(localPath): \(error.localizedDescription)", level: .error)
        if var upload = internalActiveUploads[localPath] {
            upload.error = error.localizedDescription
            upload.transferSpeed = 0
            internalActiveUploads[localPath] = upload
            if !isBatchUploading {
                activeUploads = internalActiveUploads
            }
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
            self.pendingRemovals.remove(localPath)
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
            self.pendingRemovals.removeAll()
            self.activeUploads.removeAll()
            self.stopTimerIfNeeded()
            self.endPreventingSleep()
            
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
            if !isBatchUploading {
                activeUploads = internalActiveUploads
            }
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
        
        // Preserve the Mac file's original modification date on the Android copy.
        // In batch mode: record it for the post-batch batched touch (zero ADB overhead here).
        // In single-file mode: apply it immediately via a single touch -t call.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
           let modDate = attrs[.modificationDate] as? Date {
            if isBatchUploading {
                timestampLock.lock()
                uploadedTimestamps.append((devicePath: safeDevicePath, date: modDate))
                timestampLock.unlock()
            } else {
                // Single-file upload — apply immediately before media scan
                await ADBManager.setRemoteTimestamps([(devicePath: safeDevicePath, date: modDate)])
            }
        }
        
        await MainActor.run {
            if var upload = internalActiveUploads[localPath] {
                upload.isComplete = true
                upload.bytesTransferred = fileSize
                upload.transferSpeed = 0
                internalActiveUploads[localPath] = upload
                if !isBatchUploading {
                    activeUploads = internalActiveUploads
                }
            }
        }
        
        let batchUploading = isBatchUploading
        
        Task.detached { [weak self] in
            
            let delayNs: UInt64 = batchUploading ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                guard let self = self else { return }
                if self.isBatchUploading {
                    self.pendingRemovals.insert(localPath)
                } else {
                    self.internalActiveUploads.removeValue(forKey: localPath)
                    self.activeUploads = self.internalActiveUploads
                    self.stopTimerIfNeeded()
                }
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
                if !self.isBatchUploading {
                    self.activeUploads = self.internalActiveUploads
                }
            }
            
            // Preserve the Mac file's original modification date on the Android copy.
            // Touch must run before media scan so MediaStore indexes the correct mtime.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
               let modDate = attrs[.modificationDate] as? Date {
                let isBatch = await MainActor.run { self.isBatchUploading }
                if isBatch {
                    self.timestampLock.lock()
                    self.uploadedTimestamps.append((devicePath: safeDevicePath, date: modDate))
                    self.timestampLock.unlock()
                } else {
                    await ADBManager.setRemoteTimestamps([(devicePath: safeDevicePath, date: modDate)])
                }
            }
            
            await ADBManager.triggerMediaScan(path: safeDevicePath)
            
            let batchActive = await MainActor.run { self.isBatchUploading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                if self.isBatchUploading {
                    self.pendingRemovals.insert(localPath)
                } else {
                    self.internalActiveUploads.removeValue(forKey: localPath)
                    self.activeUploads = self.internalActiveUploads
                    self.stopTimerIfNeeded()
                }
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
                self.isAutoConcurrency = true
                self.startTimerIfNeeded()
            }
            
            let isWireless = self.deviceManager?.connectionType == .wireless
            let isAppBusy = self.appManager?.operationEngine.isBusy ?? false
            let downloadsActive = (self.downloadManager?.runningTransfersCount ?? 0) > 0 || (self.downloadManager?.isBatchDownloading ?? false)
            let initialLimit: Int
            if isWireless {
                initialLimit = downloadsActive ? (isAppBusy ? 2 : 3) : (isAppBusy ? 4 : 5)
            } else {
                initialLimit = downloadsActive ? (isAppBusy ? kWiredDualBusyCap : kWiredDualCap) : min(self.maxConcurrent, isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent)
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
            self.activeCongestionCap = downloadsActive ? initialLimit : soloMaxCap
            self.successStreak = 0
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
                    // Check if it's just a wireless port rotation on the same IP
                    if ADBManager.isWirelessSerial(currentSerial) && ADBManager.isWirelessSerial(targetSerial),
                       currentSerial.components(separatedBy: ":").first == targetSerial.components(separatedBy: ":").first {
                        // Port rotation on same wireless device — update target serial to match new port
                        await MainActor.run {
                            self.targetDeviceSerial = currentSerial
                        }
                    } else {
                        print("⚠️ UploadManager: Explicit device switch from \(targetSerial) to \(currentSerial). Aborting batch upload.")
                        await MainActor.run {
                            self.cancelAllUploads()
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
                        if !isBatchUploading {
                            activeUploads = internalActiveUploads
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
                let activeDownloadsCount = downloadManager?.runningTransfersCount ?? 0
                let pendingDownloadsCount = downloadManager?.pendingQueueCount ?? 0
                // Include isBatchDownloading to cover the startup race window where downloads have
                // started but haven't dispatched tasks yet (runningCount=0, pendingCount=0)
                let isBatchDownload = await MainActor.run { self.downloadManager?.isBatchDownloading ?? false }
                let downloadsActive = activeDownloadsCount > 0
                let isOppositeDemandActive = downloadsActive || pendingDownloadsCount > 0 || isBatchDownload
                
                let globalCombinedLimit: Int
                let maxUploadCap: Int
                if isWireless {
                    if isOppositeDemandActive {
                        // 50-50 Wi-Fi allocation
                        globalCombinedLimit = isAppBusy ? (kWirelessDualBusyCap * 2) : kWirelessMaxConcurrent
                        maxUploadCap = isAppBusy ? kWirelessDualBusyCap : kWirelessDualCap
                    } else {
                        globalCombinedLimit = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
                        maxUploadCap = isAppBusy ? kWirelessSoloBusyCap : kWirelessMaxConcurrent
                    }
                } else {
                    if isOppositeDemandActive {
                        // 50-50 USB allocation
                        globalCombinedLimit = isAppBusy ? (kWiredDualBusyCap * 2) : kWiredMaxConcurrent
                        maxUploadCap = isAppBusy ? kWiredDualBusyCap : kWiredDualCap
                    } else {
                        globalCombinedLimit = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
                        maxUploadCap = isAppBusy ? kWiredSoloBusyCap : kWiredMaxConcurrent
                    }
                }
                if !isOppositeDemandActive {
                    await MainActor.run { self.temporaryMaxConcurrent = nil }
                }
                
                let baseMax = await MainActor.run { self.isAutoConcurrency ? maxUploadCap : (self.temporaryMaxConcurrent ?? self.preferredMaxConcurrent) }
                let targetMax = min(baseMax, maxUploadCap)
                if self.maxConcurrent != targetMax {
                    await MainActor.run { 
                        self.isAutoClamping = true
                        self.maxConcurrent = targetMax 
                        self.isAutoClamping = false
                    }
                }
                
                var limit = min(self.maxConcurrent, maxUploadCap)
                // AIMD congestion cap only applies in auto mode.
                // In manual mode the user explicitly owns the concurrency value.
                let isAuto = await MainActor.run { self.isAutoConcurrency }
                if isAuto {
                    limit = min(limit, self.activeCongestionCap)
                }
                
                let oppositeWeight = downloadManager?.runningTransfersWeight ?? 0.0
                let maxUploadsAllowed = max(1, Int(Double(globalCombinedLimit) - oppositeWeight))
                limit = min(limit, maxUploadsAllowed)
                
                // Hard ceiling — can never exceed the connection-type cap under any circumstance
                limit = min(limit, maxUploadCap)
                
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
                var dispatchedThisRound = 0
                while running < limit && !batchCancelled {
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
                    // Burst-dispatching multiple push processes simultaneously overwhelms
                    // the connection, causing drops. A 200ms gap lets ADB stabilize each new connection.
                    if isWireless && dispatchedThisRound > 0 {
                        try? await Task.sleep(nanoseconds: kWiFiStaggerDelayNs)
                    }
                    dispatchedThisRound += 1
                    
                    let (safeName, _) = FileNameHelper.getSafeFilename(file.fileName)
                    let fullDevicePath = file.devicePath.hasSuffix("/")
                        ? file.devicePath + safeName
                        : file.devicePath + "/" + safeName
                    
                    scannedFiles.insert(fullDevicePath)
                    
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
                             try await self.uploadFile(
                                 localPath: file.localPath,
                                 fileName: file.fileName,
                                 fileSize: file.fileSize,
                                 to: file.devicePath,
                                 retryCount: file.retryCount
                             )
                            didSucceed = true
                            
                            // Success path: gradually restore congestion cap (AIMD Additive Increase)
                            let aimdEnabled = await MainActor.run { self.isAutoConcurrency }
                            if aimdEnabled {
                                await MainActor.run {
                                    self.successStreak += 1
                                    if self.successStreak >= 3 {
                                        self.activeCongestionCap = min(maxUploadCap, self.activeCongestionCap + 1)
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
                                self.isCancelled(localPath: file.localPath)
                            }
                            let isBatchCanc = await MainActor.run { self.batchCancelled }
                            
                            if isDisconnected && newRetryCount <= 5 && !isBatchCanc && !isItemCancelled && !deviceSwitched {
                                print("📶 UploadManager: Connection lost during upload of \(file.fileName). Retry \(newRetryCount)/5. Re-enqueuing...")
                                
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
                                    if var progress = self.internalActiveUploads[file.localPath] {
                                        progress.error = "Connection lost (Retry \(newRetryCount)/5) - waiting for reconnect..."
                                        progress.transferSpeed = 0
                                        progress.retryCount = newRetryCount
                                        self.internalActiveUploads[file.localPath] = progress
                                        if !self.isBatchUploading {
                                            self.activeUploads = self.internalActiveUploads
                                        }
                                    }
                                }
                                try? await Task.sleep(nanoseconds: kConnectionRetryDelayNs)
                            } else {
                                // Permanent failure (either not a connection error, or exceeded max retries)
                                let finalError = newRetryCount > 5 ? NSError(domain: "UploadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed after 5 connection retries."]) : error
                                await MainActor.run {
                                    self.markUploadFailed(localPath: file.localPath, error: finalError)
                                }
                            }
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
        
        // 1. Restore original timestamps on the Android device before media scanning.
        //    touch -t runs in chunks of 50 (~10 adb shell calls for 500 files vs 500 individual calls).
        //    Must complete before the media scan so MediaStore picks up the correct mtime.
        timestampLock.lock()
        let timestampsToApply = uploadedTimestamps
        uploadedTimestamps.removeAll()
        timestampLock.unlock()
        
        if !timestampsToApply.isEmpty {
            await ADBManager.setRemoteTimestamps(timestampsToApply)
        }
        
        // 2. Scan all modified files so they appear in Gallery / Google Photos
        let filesToScan = Array(scannedFiles)
        Task.detached {
            await ADBManager.triggerMediaScanForFiles(filesToScan)
        }
        
        queueLock.lock()
        isProcessingQueue = false
        queueLock.unlock()
        
        await MainActor.run {
            self.internalActiveUploads.removeAll()
            self.pendingRemovals.removeAll()
            self.activeUploads.removeAll()
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
