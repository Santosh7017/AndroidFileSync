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
    
    var body: some View {
        if !downloadManager.activeDownloads.isEmpty || !uploadManager.activeUploads.isEmpty {
            TransferProgressView(
                title: "Active Transfers",
                items: getTransferItems(),
                batchInfo: getBatchInfo(),
                onCancel: { item in
                    handleCancel(item)
                }
            )
        }
    }
    
    private func handleCancel(_ item: TransferItemData) {
        if item.isUpload {
            // Extract localPath from the ID (format: "upload_localPath")
            let localPath = String(item.id.dropFirst("upload_".count))
            uploadManager.cancelUpload(localPath: localPath)
        } else {
            // Extract devicePath from the ID (format: "download_devicePath")
            let devicePath = String(item.id.dropFirst("download_".count))
            downloadManager.cancelDownload(devicePath: devicePath)
        }
    }
    
    /// Returns batch info for showing overall progress
    private func getBatchInfo() -> BatchTransferInfo? {
        // Only show batch info if there's an active batch download
        if downloadManager.isBatchDownloading && downloadManager.batchTotal > 1 {
            return BatchTransferInfo(
                completed: downloadManager.batchCompleted,
                total: downloadManager.batchTotal,
                isDownload: true
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
