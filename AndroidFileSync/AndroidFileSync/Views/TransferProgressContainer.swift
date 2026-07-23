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
    @ObservedObject var appManager: AppManager
    
    var body: some View {
        if uploadManager.isPreparing {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.7)
                Text(uploadManager.preparingMessage)
                    .font(.system(.callout, weight: .medium))
                    .foregroundColor(.orange)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
        } else if downloadManager.isScanning {
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
        } else if downloadManager.isBatchDownloading || uploadManager.isBatchUploading || !downloadManager.activeDownloads.isEmpty || !uploadManager.activeUploads.isEmpty {
            TransferProgressView(
                title: "Active Transfers",
                items: getTransferItems(),
                batchInfo: getBatchInfo(),
                onCancel: { item in handleCancel(item) },
                onCancelAll: {
                    downloadManager.cancelAllDownloads()
                    uploadManager.cancelAllUploads()
                },
                onCancelAllUploads: {
                    uploadManager.cancelAllUploads()
                },
                onCancelAllDownloads: {
                    downloadManager.cancelAllDownloads()
                },
                concurrencyBinding: (downloadManager.isBatchDownloading || !downloadManager.activeDownloads.isEmpty) ? $downloadManager.maxConcurrent : nil,
                uploadConcurrencyBinding: (uploadManager.isBatchUploading || !uploadManager.activeUploads.isEmpty) ? $uploadManager.maxConcurrent : nil,
                isAutoDownloadBinding: (downloadManager.isBatchDownloading || !downloadManager.activeDownloads.isEmpty) ? $downloadManager.isAutoConcurrency : nil,
                isAutoUploadBinding: (uploadManager.isBatchUploading || !uploadManager.activeUploads.isEmpty) ? $uploadManager.isAutoConcurrency : nil,
                effectiveDownloadLimit: (downloadManager.isBatchDownloading || !downloadManager.activeDownloads.isEmpty) ? downloadManager.effectiveConcurrentLimit : nil,
                effectiveUploadLimit: (uploadManager.isBatchUploading || !uploadManager.activeUploads.isEmpty) ? uploadManager.effectiveConcurrentLimit : nil,
                isWirelessConnection: deviceManager.connectionType == .wireless,
                isAppOperationBusy: appManager.operationEngine.isBusy,
                isScanning: downloadManager.isScanning,
                scanningFolderName: downloadManager.scanningFolderName,
                folderName: downloadManager.currentFolderName
            )
        }
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
        let downloadsActive = downloadManager.isBatchDownloading || !downloadManager.activeDownloads.isEmpty
        let dlComp = downloadsActive && downloadManager.batchTotal > 0 ? downloadManager.batchCompleted : nil
        let dlTot = downloadsActive && downloadManager.batchTotal > 0 ? downloadManager.batchTotal : nil
        
        let uploadsActive = uploadManager.isBatchUploading || !uploadManager.activeUploads.isEmpty
        let ulComp = uploadsActive && uploadManager.batchTotal > 0 ? uploadManager.batchCompleted : nil
        let ulTot = uploadsActive && uploadManager.batchTotal > 0 ? uploadManager.batchTotal : nil
        
        if dlTot != nil || ulTot != nil {
            return BatchTransferInfo(
                downloadCompleted: dlComp,
                downloadTotal: dlTot,
                uploadCompleted: ulComp,
                uploadTotal: ulTot
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
                isUpload: false,
                retryCount: download.retryCount
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
                isUpload: true,
                retryCount: upload.retryCount
            ))
        }
        
        // Sort items so actively transferring or errored/cancelled items appear first
        items.sort { a, b in
            let aActive = !a.isComplete && (a.bytesTransferred > 0 || a.error != nil)
            let bActive = !b.isComplete && (b.bytesTransferred > 0 || b.error != nil)
            if aActive != bActive { return aActive }
            return a.fileName < b.fileName
        }
        
        // Limit display list so 200+ pending rows never clutter the transfer panel view
        return Array(items.prefix(16))
    }
}
