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
        }
    }
    private var lastActiveUploadsCount = 0
    private var internalActiveUploads: [String: UploadProgress] = [:]
    
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
    
    @Published var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrentUploads") }
    }
    
    private let progressLock = NSLock()
    private var backgroundProgress: [String: (bytes: UInt64, speed: Double)] = [:]
    
    private var cancellationFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    
    private var updateTimer: Timer?
    
    private var transferActivity: NSObjectProtocol?
    private let activityLock = NSLock()
    
    // Shared upload queue — new drops append here instead of starting a separate batch
    private let queueLock = NSLock()
    private var pendingFiles: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)] = []
    private var isProcessingQueue = false
    
    // Throttled batch counter — updated in background, flushed to @Published by timer
    private var internalBatchCompleted: Int = 0
    
    // Active running tasks counter for queue processor
    private var activeRunningCount: Int = 0
    private let activeRunningLock = NSLock()
    
    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentUploads")
        self.maxConcurrent = saved > 0 ? min(max(saved, 1), 10) : 3
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
    private func markUploadFailed(localPath: String, error: Error) {
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
        }
    }
    
    func uploadFile(
        localPath: String,
        fileName: String,
        fileSize: UInt64,
        to devicePath: String
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
            totalBytes: fileSize
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
        
        await ADBManager.triggerMediaScan(path: safeDevicePath)
        
        let delayNs: UInt64 = isBatchUploading ? 300_000_000 : 1_000_000_000
        try? await Task.sleep(nanoseconds: delayNs)
        
        await MainActor.run {
            internalActiveUploads.removeValue(forKey: localPath)
            activeUploads = internalActiveUploads
            stopTimerIfNeeded()
        }
        
        flagLock.lock()
        cancellationFlags.removeValue(forKey: localPath)
        flagLock.unlock()
        
        if !isBatchUploading && activeUploads.isEmpty {
            endPreventingSleep()
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
            
            await ADBManager.triggerMediaScan(path: safeDevicePath)
            
            let batchActive = await MainActor.run { self.isBatchUploading }
            let delayNs: UInt64 = batchActive ? 300_000_000 : 1_000_000_000
            try? await Task.sleep(nanoseconds: delayNs)
            
            await MainActor.run {
                self.internalActiveUploads.removeValue(forKey: localPath)
                if !self.isBatchUploading {
                    self.activeUploads = self.internalActiveUploads
                }
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
        pendingFiles.append(contentsOf: files)
        let shouldStart = !isProcessingQueue
        if shouldStart { isProcessingQueue = true }
        queueLock.unlock()
        
        Task { @MainActor in
            if !self.isBatchUploading {
                self.batchTotal = files.count
                self.batchCompleted = 0
                
                self.progressLock.lock()
                self.internalBatchCompleted = 0
                self.progressLock.unlock()
                
                self.isBatchUploading = true
                self.batchCancelled = false
                self.startTimerIfNeeded()
            } else {
                self.batchTotal += files.count
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
    
    // MARK: - Queue Processor (single sliding window)
    
    private func processQueue() async {
        beginPreventingSleep()
        
        await withTaskGroup(of: Void.self) { group in
            while !batchCancelled {
                let limit = self.maxConcurrent
                
                activeRunningLock.lock()
                var running = activeRunningCount
                activeRunningLock.unlock()
                
                // Try to fill slots from the pending queue
                while running < limit && !batchCancelled {
                    queueLock.lock()
                    let nextFile = pendingFiles.isEmpty ? nil : pendingFiles.removeFirst()
                    queueLock.unlock()
                    
                    guard let file = nextFile else { break }
                    
                    activeRunningLock.lock()
                    activeRunningCount += 1
                    running = activeRunningCount
                    activeRunningLock.unlock()
                    
                    group.addTask {
                        do {
                            try await self.uploadFile(
                                localPath: file.localPath,
                                fileName: file.fileName,
                                fileSize: file.fileSize,
                                to: file.devicePath
                            )
                        } catch { }
                        
                        self.activeRunningLock.lock()
                        self.activeRunningCount -= 1
                        self.activeRunningLock.unlock()
                        
                        self.progressLock.lock()
                        self.internalBatchCompleted += 1
                        self.progressLock.unlock()
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
                
                if finalRunning >= limit {
                    // All slots are full. Suspend until a task finishes.
                    await group.next()
                } else {
                    // Slots are free but queue is empty.
                    // Sleep for 100ms to wait for new files to be enqueued.
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            
            if batchCancelled {
                group.cancelAll()
            }
            
            await group.waitForAll()
        }
        
        queueLock.lock()
        isProcessingQueue = false
        queueLock.unlock()
        
        await MainActor.run {
            self.flushUIUpdates()
            self.isBatchUploading = false
        }
        
        endPreventingSleep()
        
        if batchCancelled {
            let completed = await MainActor.run { batchCompleted }
            print("🛑 Batch upload cancelled at \(completed)/\(batchTotal)")
        } else {
            let total = await MainActor.run { batchTotal }
            print("✅ All \(total) uploads completed")
        }
    }
}
