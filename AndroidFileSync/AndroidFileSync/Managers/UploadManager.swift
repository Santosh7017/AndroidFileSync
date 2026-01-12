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
    
    // Thread-safe storage for progress updates from background
    private let progressLock = NSLock()
    private var backgroundProgress: [String: (bytes: UInt64, speed: Double)] = [:]
    
    // Cancellation flags - thread-safe with lock
    private var cancellationFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    
    // Timer for periodic UI updates - only runs when uploads are active
    private var updateTimer: Timer?
    
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
    
    func uploadFile(
        localPath: String,
        fileName: String,
        fileSize: UInt64,
        to devicePath: String
    ) async throws {
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
        for await (bytesTransferred, speed) in progressStream {
            // Check for cancellation
            if isCancelled(localPath: localPath) {
                print("🛑 Upload cancelled: \(safeFileName)")
                return
            }
            
            progressLock.lock()
            backgroundProgress[localPath] = (bytesTransferred, speed)
            progressLock.unlock()
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
    
    func uploadMultipleFiles(
        files: [(localPath: String, fileName: String, fileSize: UInt64)],
        toDirectory devicePath: String
    ) async {
        for file in files {
            do {
                try await uploadFile(
                    localPath: file.localPath,
                    fileName: file.fileName,
                    fileSize: file.fileSize,
                    to: devicePath
                )
            } catch {
                print("❌ Failed to upload \(file.fileName): \(error)")
            }
        }
    }
}
