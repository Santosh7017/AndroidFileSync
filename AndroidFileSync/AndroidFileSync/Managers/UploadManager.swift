//
//  UploadManager.swift
//  AndroidFileSync
//
//  Uses AsyncStream polling for progress (like DownloadManager)
//
import Foundation
internal import Combine

class UploadManager: ObservableObject {
    @Published var activeUploads: [String: UploadProgress] = [:]
    
    // Batch tracking (mirrors DownloadManager)
    @Published var batchTotal: Int = 0
    @Published var batchCompleted: Int = 0
    @Published var isBatchUploading: Bool = false
    @Published var batchCancelled: Bool = false
    
    // Live-adjustable concurrency (1-8 slots), persisted across launches
    @Published var maxConcurrent: Int {
        didSet { UserDefaults.standard.set(maxConcurrent, forKey: "maxConcurrentUploads") }
    }
    
    // Thread-safe storage for progress updates from background
    private let progressLock = NSLock()
    private var backgroundProgress: [String: (bytes: UInt64, speed: Double)] = [:]
    
    // Cancellation flags - thread-safe with lock
    private var cancellationFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    
    // Timer for periodic UI updates - only runs when uploads are active
    private var updateTimer: Timer?
    
    init() {
        let saved = UserDefaults.standard.integer(forKey: "maxConcurrentUploads")
        self.maxConcurrent = saved > 0 ? min(max(saved, 1), 8) : 3
    }
    
    struct UploadProgress: Identifiable {
        let id = UUID()
        let fileName: String
        let localPath: String
        let devicePath: String
        var bytesTransferred: UInt64 = 0
        var totalBytes: UInt64
        var transferSpeed: Double = 0 // MB/s
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
            self?.updateUIFromBackground()
        }
    }
    
    private func stopTimerIfNeeded() {
        guard activeUploads.isEmpty else { return }
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    private func updateUIFromBackground() {
        progressLock.lock()
        let updates = backgroundProgress
        progressLock.unlock()
        
        for (localPath, (bytes, speed)) in updates {
            if var upload = activeUploads[localPath] {
                upload.bytesTransferred = bytes
                upload.transferSpeed = speed
                activeUploads[localPath] = upload
            }
        }
    }
    
    deinit {
        updateTimer?.invalidate()
    }

    @MainActor
    private func markUploadFailed(localPath: String, error: Error) {
        if var upload = activeUploads[localPath] {
            upload.error = error.localizedDescription
            upload.transferSpeed = 0
            activeUploads[localPath] = upload
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
        print("🛑 Cancelling upload: \(localPath)")
        
        // Set cancellation flag - this will be checked by the Shell
        setCancelled(localPath: localPath, value: true)
        
        // Update UI state
        if var upload = activeUploads[localPath] {
            upload.isCancelled = true
            activeUploads[localPath] = upload
        }
        
        // Remove from UI after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.activeUploads.removeValue(forKey: localPath)
            self?.stopTimerIfNeeded()
            
            // Clean up background progress
            self?.progressLock.lock()
            self?.backgroundProgress.removeValue(forKey: localPath)
            self?.progressLock.unlock()
            
            // Clean up flag
            self?.flagLock.lock()
            self?.cancellationFlags.removeValue(forKey: localPath)
            self?.flagLock.unlock()
        }
    }
    
    /// Cancels all active uploads
    func cancelAllUploads() {
        print("🛑 Cancelling ALL uploads")
        
        // Set batch-level flag to stop the loop from enqueuing new files
        batchCancelled = true
        isBatchUploading = false
        
        // Set all cancellation flags for currently active uploads
        flagLock.lock()
        for key in cancellationFlags.keys {
            cancellationFlags[key] = true
        }
        for key in activeUploads.keys {
            cancellationFlags[key] = true
        }
        flagLock.unlock()
        
        // Mark all as cancelled in UI
        for key in activeUploads.keys {
            activeUploads[key]?.isCancelled = true
        }
        
        // Clear after brief delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.activeUploads.removeAll()
            self?.stopTimerIfNeeded()
            
            self?.progressLock.lock()
            self?.backgroundProgress.removeAll()
            self?.progressLock.unlock()
            
            self?.flagLock.lock()
            self?.cancellationFlags.removeAll()
            self?.flagLock.unlock()
        }
    }
    
    func uploadFile(
        localPath: String,
        fileName: String,
        fileSize: UInt64,
        to devicePath: String
    ) async throws {
        // Early exit if batch was cancelled before this file started
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
        
        // Initialize on main thread
        await MainActor.run {
            activeUploads[localPath] = progress
            startTimerIfNeeded()
        }
        
        // Reset cancellation flag
        setCancelled(localPath: localPath, value: false)
        
        
        // Use the new AsyncStream-based API (like downloads)
        let progressStream = ADBManager.pushFileWithProgress(
            localPath: localPath,
            devicePath: safeDevicePath,
            totalBytes: fileSize,
            cancellationCheck: { [weak self] in
                self?.isCancelled(localPath: localPath) ?? false
            }
        )
        
        // Consume stream and update background storage
        do {
            for try await (bytesTransferred, speed) in progressStream {
                // Check for cancellation
                if isCancelled(localPath: localPath) {
                    print("🛑 Upload cancelled: \(safeFileName)")
                    return
                }
                
                progressLock.lock()
                backgroundProgress[localPath] = (bytesTransferred, speed)
                progressLock.unlock()
            }
        } catch {
            await markUploadFailed(localPath: localPath, error: error)
            throw error
        }
        
        // Check for cancellation
        if isCancelled(localPath: localPath) {
            print("🛑 Upload was cancelled: \(safeFileName)")
            return
        }
        
        // Clear background progress
        progressLock.lock()
        backgroundProgress.removeValue(forKey: localPath)
        progressLock.unlock()
        
        // Mark complete on main thread
        await MainActor.run {
            if var upload = activeUploads[localPath] {
                upload.isComplete = true
                upload.bytesTransferred = fileSize
                upload.transferSpeed = 0
                activeUploads[localPath] = upload
            }
        }
        
        // Trigger media scan so uploaded files appear in Gallery immediately
        await ADBManager.triggerMediaScan(path: safeDevicePath)
        
        // Show 100% briefly
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        
        await MainActor.run {
            activeUploads.removeValue(forKey: localPath)
            stopTimerIfNeeded()
        }
        
        // Clean up flag
        flagLock.lock()
        cancellationFlags.removeValue(forKey: localPath)
        flagLock.unlock()
    }
    
    // MARK: - Parallel Upload Support
    
    /// Starts an upload without waiting for completion (fire-and-forget for parallel execution)
    /// - Returns: The Task that can be used to track or cancel the upload
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
        
        // Add to UI on main thread and start timer
        Task { @MainActor in
            activeUploads[localPath] = progress
            startTimerIfNeeded()
        }
        
        // Reset cancellation flag
        setCancelled(localPath: localPath, value: false)
        
        // Create the upload task
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
            
            // Consume stream and update background storage
            do {
                for try await (bytesTransferred, speed) in progressStream {
                    if self.isCancelled(localPath: localPath) {
                        print("🛑 Upload cancelled: \(safeFileName)")
                        return
                    }
                    
                    self.progressLock.lock()
                    self.backgroundProgress[localPath] = (bytesTransferred, speed)
                    self.progressLock.unlock()
                }
            } catch {
                await self.markUploadFailed(localPath: localPath, error: error)
                return
            }
            
            // Check for cancellation
            if self.isCancelled(localPath: localPath) {
                return
            }
            
            // Clear background progress
            self.progressLock.lock()
            self.backgroundProgress.removeValue(forKey: localPath)
            self.progressLock.unlock()
            
            // Mark complete on main thread
            await MainActor.run {
                self.activeUploads[localPath]?.isComplete = true
                self.activeUploads[localPath]?.bytesTransferred = fileSize
                self.activeUploads[localPath]?.transferSpeed = 0
            }
            
            // Trigger media scan so uploaded files appear in Gallery immediately
            await ADBManager.triggerMediaScan(path: safeDevicePath)
            
            // Show 100% briefly
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await MainActor.run {
                self.activeUploads.removeValue(forKey: localPath)
                self.stopTimerIfNeeded()
            }
            
            // Clean up flag
            self.flagLock.lock()
            self.cancellationFlags.removeValue(forKey: localPath)
            self.flagLock.unlock()
        }
        
        return uploadTask
    }
    
    /// Uploads multiple files in parallel to the SAME directory
    func uploadMultipleFiles(
        files: [(localPath: String, fileName: String, fileSize: UInt64)],
        toDirectory devicePath: String
    ) async {
        guard !files.isEmpty else { return }
        
        // Convert to per-path format and reuse the sliding-window method
        let items = files.map { file in
            (localPath: file.localPath, fileName: file.fileName, fileSize: file.fileSize, devicePath: devicePath)
        }
        await uploadFilesToPaths(files: items)
    }
    
    /// Uploads multiple files in parallel where each file has its OWN unique device path.
    /// Uses a sliding window with live-adjustable concurrency (same pattern as DownloadManager).
    func uploadFilesToPaths(
        files: [(localPath: String, fileName: String, fileSize: UInt64, devicePath: String)]
    ) async {
        guard !files.isEmpty else { return }
        
        await MainActor.run {
            batchTotal = files.count
            batchCompleted = 0
            isBatchUploading = true
            batchCancelled = false
        }
        
        print("📤 Starting parallel upload of \(files.count) files")
        
        await withTaskGroup(of: Void.self) { group in
            var runningCount = 0
            var fileIndex = 0
            
            while fileIndex < files.count && !batchCancelled {
                // Re-read limit each iteration so live slider changes take effect
                let limit = self.maxConcurrent
                
                // Fill up to limit slots
                while runningCount < limit && fileIndex < files.count && !batchCancelled {
                    let file = files[fileIndex]
                    fileIndex += 1
                    runningCount += 1
                    
                    print("📤 [\(fileIndex)/\(files.count)] Starting: \(file.fileName)")
                    
                    group.addTask {
                        do {
                            try await self.uploadFile(
                                localPath: file.localPath,
                                fileName: file.fileName,
                                fileSize: file.fileSize,
                                to: file.devicePath
                            )
                            await MainActor.run { self.batchCompleted += 1 }
                        } catch {
                            print("❌ Failed to upload \(file.fileName): \(error)")
                            await MainActor.run { self.batchCompleted += 1 }
                        }
                    }
                }
                
                // If cancelled, cancel all remaining tasks and break
                if batchCancelled {
                    group.cancelAll()
                    break
                }
                
                // Wait for one slot to free before looping
                if runningCount >= limit && fileIndex < files.count {
                    await group.next()
                    runningCount -= 1
                }
            }
            
            // If cancelled mid-batch, cancel remaining running tasks
            if batchCancelled {
                group.cancelAll()
            }
            
            await group.waitForAll()
        }
        
        await MainActor.run {
            isBatchUploading = false
        }
        
        if batchCancelled {
            print("🛑 Batch upload cancelled at \(await MainActor.run { batchCompleted })/\(files.count)")
        } else {
            print("✅ All \(files.count) uploads completed")
        }
    }
}
