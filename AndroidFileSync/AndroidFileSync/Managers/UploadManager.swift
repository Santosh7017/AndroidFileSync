//
//  UploadManager.swift
//  (CORRECTED - Single Argument Callback)
//
import Foundation
internal import Combine

class UploadManager: ObservableObject {
    @Published var activeUploads: [String: UploadProgress] = [:]
    
    struct UploadProgress: Identifiable {
        let id = UUID()
        let fileName: String
        let localPath: String
        let devicePath: String
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
        
        do {
            print("📤 Uploading: \(safeFileName) (\(formatBytes(fileSize)))")
            
            try await ADBManager.pushFileWithProgress(
                localPath: localPath,
                devicePath: safeDevicePath,
                progressCallback: { [weak self] percentOrBytes, speed in
                    Task { @MainActor in
                        guard let self = self,
                              var currentProgress = self.activeUploads[localPath] else { return }
                        
                        if percentOrBytes <= 100 {
                            currentProgress.bytesTransferred =
                                UInt64(Double(fileSize) * Double(percentOrBytes) / 100.0)
                        } else {
                            currentProgress.bytesTransferred = percentOrBytes
                        }
                        
                        currentProgress.transferSpeed = speed
                        self.activeUploads[localPath] = currentProgress
                    }
                }
            )
            
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
            print("❌ Upload Error: \(error.localizedDescription)")
            
            if var upload = activeUploads[localPath] {
                upload.error = error.localizedDescription
                activeUploads[localPath] = upload
            }
            throw error
        }
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
