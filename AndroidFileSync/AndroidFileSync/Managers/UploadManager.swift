//
//  UploadManager.swift
//  (CORRECTED - Single Argument Callback)
//
import Foundation
internal import Combine

class UploadManager: ObservableObject {
    @Published var activeUploads: [String: UploadProgress] = [:]
    
    // Cancellation flags - thread-safe with lock
    private var cancellationFlags: [String: Bool] = [:]
    private let flagLock = NSLock()
    
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
        
        var progress = UploadProgress(
            fileName: safeFileName,
            localPath: localPath,
            devicePath: safeDevicePath,
            totalBytes: fileSize
        )
        
        activeUploads[localPath] = progress
        
        // Reset cancellation flag
        setCancelled(localPath: localPath, value: false)
        
        do {
            print("📤 Uploading: \(safeFileName) (\(formatBytes(fileSize)))")
            
            try await ADBManager.pushFileWithProgress(
                localPath: localPath,
                devicePath: safeDevicePath,
                progressCallback: { [weak self] percentOrBytes, speed in
                    guard let self = self else { return }
                    
                    // Check for cancellation
                    guard !self.isCancelled(localPath: localPath) else { return }
                    
                    Task { @MainActor in
                        guard var currentProgress = self.activeUploads[localPath] else { return }
                        
                        if percentOrBytes <= 100 {
                            currentProgress.bytesTransferred =
                                UInt64(Double(fileSize) * Double(percentOrBytes) / 100.0)
                        } else {
                            currentProgress.bytesTransferred = percentOrBytes
                        }
                        
                        currentProgress.transferSpeed = speed
                        self.activeUploads[localPath] = currentProgress
                    }
                },
                cancellationCheck: { [weak self] in
                    self?.isCancelled(localPath: localPath) ?? false
                }
            )
            
            // Check for cancellation after transfer
            if isCancelled(localPath: localPath) {
                print("🛑 Upload was cancelled: \(safeFileName)")
                return
            }
            
            if var upload = activeUploads[localPath] {
                upload.isComplete = true
                upload.bytesTransferred = fileSize
                upload.transferSpeed = 0
                activeUploads[localPath] = upload
            }
            
            print("✅ Upload complete: \(safeFileName)")
            
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            activeUploads.removeValue(forKey: localPath)
            
        } catch {
            // Check if was cancelled
            if isCancelled(localPath: localPath) {
                print("🛑 Upload cancelled: \(safeFileName)")
                return
            }
            
            print("❌ Upload Error: \(error.localizedDescription)")
            
            if var upload = activeUploads[localPath] {
                upload.error = error.localizedDescription
                activeUploads[localPath] = upload
            }
            throw error
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
