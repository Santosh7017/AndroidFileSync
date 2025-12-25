//
//  DownloadManager.swift
//  (CORRECTED - Single Argument Callback)
//
import Foundation
internal import Combine

class DownloadManager: ObservableObject {
    // Store progress for each file being downloaded (Key: devicePath)
    @Published var activeDownloads: [String: DownloadProgress] = [:]
    
    // Store active tasks for cancellation (Key: devicePath)
    private var activeTasks: [String: Task<Void, Never>] = [:]
    private let taskLock = NSLock()
    
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
        guard activeDownloads.isEmpty else { return }
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    // Public methods to pause/resume during navigation
    func pauseUpdates() {
        updateTimer?.invalidate()
        updateTimer = nil
    }
    
    func resumeUpdates() {
        guard !activeDownloads.isEmpty else { return }
        startTimerIfNeeded()
    }
    
    deinit {
        updateTimer?.invalidate()
    }
    
    private func updateUIFromBackground() {
        progressLock.lock()
        let updates = backgroundProgress
        progressLock.unlock()
        
        for (devicePath, (bytes, speed)) in updates {
            activeDownloads[devicePath]?.bytesTransferred = bytes
            activeDownloads[devicePath]?.transferSpeed = speed
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
        if var download = activeDownloads[devicePath] {
            download.isCancelled = true
            activeDownloads[devicePath] = download
            
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
            self?.activeDownloads.removeValue(forKey: devicePath)
            self?.stopTimerIfNeeded()
            
            // Clear background progress
            self?.progressLock.lock()
            self?.backgroundProgress.removeValue(forKey: devicePath)
            self?.progressLock.unlock()
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
            activeDownloads[devicePath] = progress
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
                self.activeDownloads[devicePath]?.isComplete = true
                self.activeDownloads[devicePath]?.bytesTransferred = fileSize
                self.activeDownloads[devicePath]?.transferSpeed = 0
            }
            
            
            // Show 100% briefly
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            
            await MainActor.run {
                self.activeDownloads.removeValue(forKey: devicePath)
                self.stopTimerIfNeeded()
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
}
