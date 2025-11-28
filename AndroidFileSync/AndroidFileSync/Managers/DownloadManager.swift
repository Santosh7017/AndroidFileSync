//
//  DownloadManager.swift
//  (CORRECTED - Single Argument Callback)
//
import Foundation
internal import Combine

class DownloadManager: ObservableObject {
    // Store progress for each file being downloaded (Key: devicePath)
    @Published var activeDownloads: [String: DownloadProgress] = [:]
    
    struct DownloadProgress: Identifiable {
        let id = UUID()
        let fileName: String
        let devicePath: String   // Source (on Android)
        let localPath: String    // Destination (on Mac)
        var bytesTransferred: UInt64 = 0
        var totalBytes: UInt64
        var transferSpeed: Double = 0 // MB/s
        var isComplete: Bool = false
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
    
    func downloadFile(
        devicePath: String,
        fileName: String,
        fileSize: UInt64,
        to localPath: String
    ) async throws {
        
        // Initialize progress state
        var progress = DownloadProgress(
            fileName: fileName,
            devicePath: devicePath,
            localPath: localPath,
            totalBytes: fileSize
        )
        
        // Add to active list
        activeDownloads[devicePath] = progress
        
        do {
            print("📥 Downloading: \(fileName) (\(formatBytes(fileSize)))")
            
            // Call ADBManager directly
            try await ADBManager.pullFileWithProgress(
                devicePath: devicePath,
                localPath: localPath,
                progressCallback: { [weak self] percentOrBytes, speed in
                    
                    // Update UI on Main Thread
                    Task { @MainActor in
                        guard let self = self,
                              var currentProgress = self.activeDownloads[devicePath] else { return }
                        
                        // If the value is small (<= 100), assume it's a percentage (0-100).
                        // If it's large, assume it's raw bytes transferred.
                        if percentOrBytes <= 100 {
                            currentProgress.bytesTransferred =
                                UInt64(Double(fileSize) * Double(percentOrBytes) / 100.0)
                        } else {
                            currentProgress.bytesTransferred = percentOrBytes
                        }
                        
                        currentProgress.transferSpeed = speed
                        self.activeDownloads[devicePath] = currentProgress
                    }
                }
            )
            
            // Mark as complete
            if var download = activeDownloads[devicePath] {
                download.isComplete = true
                download.bytesTransferred = fileSize
                download.transferSpeed = 0
                activeDownloads[devicePath] = download
            }
            
            print("✅ Download complete: \(fileName)")
            
            // Briefly show “100%” before removing it
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            activeDownloads.removeValue(forKey: devicePath)
            
        } catch {
            print("❌ Download Error: \(error.localizedDescription)")
            
            if var download = activeDownloads[devicePath] {
                download.error = error.localizedDescription
                activeDownloads[devicePath] = download
            }
            throw error
        }
    }
}
