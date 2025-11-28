//
//  HeaderView.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import SwiftUI


// MARK: - Header View

struct HeaderView: View {
    
//    @StateObject private var deviceManager = DeviceManager()
//    @StateObject private var deviceManager = DeviceManager()
//    @StateObject private var downloadManager = DownloadManager()
//    @StateObject private var uploadManager = UploadManager()
    
    @ObservedObject var deviceManager: DeviceManager
    @ObservedObject var downloadManager: DownloadManager
    @ObservedObject var uploadManager: UploadManager
    
    var body: some View {
        HStack {
            deviceStatusIcon
            deviceInfo
            Spacer()
            
            if deviceManager.isConnected {
                ConnectionBadge(type: deviceManager.connectionType)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var deviceStatusIcon: some View {
        Image(systemName: deviceManager.isConnected ? "iphone.circle.fill" : "iphone.circle")
            .foregroundColor(deviceManager.isConnected ? .green : .gray)
            .font(.title2)
    }
    
    private var deviceInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Android File Sync")
                .font(.headline)
            
            HStack(spacing: 4) {
                Text(deviceManager.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if hasActiveTransfers {
                    transferIndicators
                }
            }
        }
    }
    
    private var hasActiveTransfers: Bool {
        !downloadManager.activeDownloads.isEmpty || !uploadManager.activeUploads.isEmpty
    }
    
    @ViewBuilder
    private var transferIndicators: some View {
        Text("•")
            .foregroundColor(.secondary)
        
        if !downloadManager.activeDownloads.isEmpty {
            Text("\(downloadManager.activeDownloads.count) ⬇️")
                .font(.caption)
                .foregroundColor(.blue)
        }
        
        if !uploadManager.activeUploads.isEmpty {
            Text("\(uploadManager.activeUploads.count) ⬆️")
                .font(.caption)
                .foregroundColor(.green)
        }
    }
}
