//
//  TransferProgressContainer.swift
//  AndroidFileSync
//
//  Isolates transfer progress updates from the main ContentView
//

import SwiftUI

struct TransferProgressContainer: View {
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var uploadManager: UploadManager
    @ObservedObject var deviceManager: DeviceManager
    
    var body: some View {
        if downloadManager.isScanning {
            // Show scanning placeholder when enumerating a folder
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text("Scanning \(downloadManager.scanningFolderName)...")
                    .font(.system(.callout, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
                Text("Building file list…")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        } else if !downloadManager.activeDownloads.isEmpty || !uploadManager.activeUploads.isEmpty {
            TransferProgressView(
                title: "Active Transfers",
                items: getTransferItems(),
                batchInfo: getBatchInfo(),
                onCancel: { item in handleCancel(item) },
                onCancelAll: {
                    downloadManager.cancelAllDownloads()
                    uploadManager.cancelAllUploads()
                },
                concurrencyBinding: getConcurrencyBinding(),
                isWirelessConnection: deviceManager.connectionType == .wireless,
                isScanning: downloadManager.isScanning,
                scanningFolderName: downloadManager.scanningFolderName,
                folderName: downloadManager.currentFolderName
            )
        }
    }
    
    private func getConcurrencyBinding() -> Binding<Int>? {
        if downloadManager.isBatchDownloading {
            return $downloadManager.maxConcurrent
        } else if uploadManager.isBatchUploading {
            return $uploadManager.maxConcurrent
        }
        return nil
    }
    
    private func handleCancel(_ item: TransferItemData) {
        if item.isUpload {
            let localPath = String(item.id.dropFirst("upload_".count))
            uploadManager.cancelUpload(localPath: localPath)
        } else {
            let devicePath = String(item.id.dropFirst("download_".count))
            downloadManager.cancelDownload(devicePath: devicePath)
        }
    }
    
    /// Returns batch info for showing overall progress
    private func getBatchInfo() -> BatchTransferInfo? {
        if downloadManager.isBatchDownloading && downloadManager.batchTotal > 1 {
            return BatchTransferInfo(
                completed: downloadManager.batchCompleted,
                total: downloadManager.batchTotal,
                isDownload: true
            )
        }
        if uploadManager.isBatchUploading && uploadManager.batchTotal > 1 {
            return BatchTransferInfo(
                completed: uploadManager.batchCompleted,
                total: uploadManager.batchTotal,
                isDownload: false
            )
        }
        return nil
    }
    
    private func getTransferItems() -> [TransferItemData] {
        var items: [TransferItemData] = []
        
        // Add downloads (use devicePath as stable ID)
        for download in downloadManager.activeDownloads.values {
            items.append(TransferItemData(
                id: "download_\(download.devicePath)",
                fileName: download.fileName,
                progress: download.progress,
                percentage: download.progressPercentage,
                speed: download.speedText,
                bytesTransferred: download.bytesTransferred,
                totalBytes: download.totalBytes,
                isComplete: download.isComplete,
                isCancelled: download.isCancelled,
                error: download.error,
                isUpload: false
            ))
        }
        
        // Add uploads (use localPath as stable ID)
        for upload in uploadManager.activeUploads.values {
            items.append(TransferItemData(
                id: "upload_\(upload.localPath)",
                fileName: upload.fileName,
                progress: upload.progress,
                percentage: upload.progressPercentage,
                speed: upload.speedText,
                bytesTransferred: upload.bytesTransferred,
                totalBytes: upload.totalBytes,
                isComplete: upload.isComplete,
                isCancelled: upload.isCancelled,
                error: upload.error,
                isUpload: true
            ))
        }
        
        return items
    }
}
