//
//  TransferProgressView.swift
//  AndroidFileSync
//
//  Displays detailed progress for file transfers (upload/download)
//

import SwiftUI

// Simple data structure for transfer items
struct TransferItemData: Identifiable {
    let id: String  // Use stable ID based on file path
    let fileName: String
    let progress: Double
    let percentage: Int
    let speed: String
    let bytesTransferred: UInt64
    let totalBytes: UInt64
    let isComplete: Bool
    let isCancelled: Bool
    let error: String?
    let isUpload: Bool
}

// Batch transfer info for showing overall progress
struct BatchTransferInfo {
    let completed: Int
    let total: Int
    let isDownload: Bool
}

struct TransferProgressView: View {
    let title: String
    let items: [TransferItemData]
    var batchInfo: BatchTransferInfo? = nil
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 16) {
                // Header with batch progress
                headerView
                
                // Overall batch progress bar (if batch download)
                if let batch = batchInfo {
                    batchProgressView(batch: batch)
                }
                
                // File list (scrollable if many files)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(items) { item in
                            TransferFileCard(item: item, onCancel: onCancel)
                        }
                    }
                }
                .frame(maxHeight: 250)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.windowBackgroundColor))
                    .shadow(color: .black.opacity(0.1), radius: 8, y: -2)
            )
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 10) {
            // Animated icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.2), .purple.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            
            Text(title)
                .font(.system(.title3, design: .rounded, weight: .bold))
            
            Spacer()
            
            // Batch progress badge
            if let batch = batchInfo {
                HStack(spacing: 4) {
                    Text("\(batch.completed)")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundColor(.green)
                    
                    Text("/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(batch.total)")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text("completed")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.15))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                        )
                )
            }
        }
    }
    
    private func batchProgressView(batch: BatchTransferInfo) -> some View {
        let progress = Double(batch.completed) / Double(max(batch.total, 1))
        let percentage = Int(progress * 100)
        
        return VStack(spacing: 8) {
            // Progress bar with glow effect
            ZStack(alignment: .leading) {
                // Background track
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(height: 12)
                
                // Animated progress fill
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: [.green, .green.opacity(0.8)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * progress, progress > 0 ? 12 : 0))
                        .shadow(color: .green.opacity(0.4), radius: 4, x: 0, y: 0)
                }
                .frame(height: 12)
            }
            
            // Stats row
            HStack {
                Text("Overall Progress")
                    .font(.system(.caption, weight: .medium))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("\(percentage)%")
                    .font(.system(.subheadline, design: .rounded, weight: .bold))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Transfer File Card

struct TransferFileCard: View {
    let item: TransferItemData
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator
            
            // File info
            VStack(alignment: .leading, spacing: 4) {
                // File name
                Text(item.fileName)
                    .font(.system(.subheadline, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                // Progress bar
                progressBar
                
                // Stats row
                HStack(spacing: 8) {
                    // Size info
                    if item.totalBytes > 0 {
                        Text("\(formatBytes(item.bytesTransferred)) / \(formatBytes(item.totalBytes))")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Speed (if transferring)
                    if !item.speed.isEmpty && !item.isComplete && item.percentage > 0 {
                        Text(item.speed)
                            .font(.system(.caption2, design: .rounded, weight: .medium))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.blue.opacity(0.1))
                            )
                    }
                    
                    // Status label
                    statusLabel
                }
            }
            
            // Cancel button or status icon
            actionButton
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(borderColor, lineWidth: 1)
                )
        )
    }
    
    private var statusIndicator: some View {
        ZStack {
            Circle()
                .fill(indicatorBackgroundColor)
                .frame(width: 38, height: 38)
            
            if item.isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            } else if item.error != nil {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
            } else if item.percentage == 0 {
                // Queued - show queue icon
                Image(systemName: "clock")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
            } else {
                // In progress - show percentage
                Text("\(item.percentage)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
    }
    
    private var progressBar: some View {
        ZStack(alignment: .leading) {
            // Background track
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 8)
            
            // Progress fill
            GeometryReader { geometry in
                if item.percentage > 0 || item.isComplete {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(progressGradient)
                        .frame(width: max(geometry.size.width * item.progress, item.progress > 0 ? 8 : 0))
                } else {
                    // Show striped pattern for queued items
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.gray.opacity(0.2), .gray.opacity(0.1)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * 0.15)
                }
            }
            .frame(height: 8)
        }
    }
    
    private var statusLabel: some View {
        Group {
            if item.isComplete {
                Text("Complete")
                    .foregroundColor(.green)
            } else if item.error != nil {
                Text("Failed")
                    .foregroundColor(.red)
            } else if item.isCancelled {
                Text("Cancelled")
                    .foregroundColor(.secondary)
            } else if item.percentage == 0 {
                Text("Queued")
                    .foregroundColor(.orange)
            } else {
                Text("\(item.percentage)%")
                    .foregroundColor(.blue)
            }
        }
        .font(.system(.caption, design: .rounded, weight: .semibold))
    }
    
    private var actionButton: some View {
        Group {
            if item.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
            } else if item.error != nil || item.isCancelled {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(item.error != nil ? .red : .secondary)
            } else {
                Button(action: { onCancel?(item) }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("Cancel transfer")
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var indicatorBackgroundColor: Color {
        if item.isComplete {
            return .green
        } else if item.error != nil {
            return .red
        } else if item.percentage == 0 {
            return Color.secondary.opacity(0.15)
        } else {
            return item.isUpload ? .blue : .purple
        }
    }
    
    private var progressGradient: LinearGradient {
        let colors: [Color]
        if item.isComplete {
            colors = [.green, .green.opacity(0.8)]
        } else if item.error != nil {
            colors = [.red, .red.opacity(0.8)]
        } else {
            colors = item.isUpload ? [.blue, .cyan] : [.purple, .blue]
        }
        return LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
    
    private var backgroundColor: Color {
        if item.isComplete {
            return Color.green.opacity(0.06)
        } else if item.error != nil {
            return Color.red.opacity(0.06)
        } else if item.percentage == 0 {
            return Color.orange.opacity(0.04)
        } else {
            return Color(NSColor.controlBackgroundColor).opacity(0.6)
        }
    }
    
    private var borderColor: Color {
        if item.isComplete {
            return Color.green.opacity(0.2)
        } else if item.error != nil {
            return Color.red.opacity(0.2)
        } else if item.percentage == 0 {
            return Color.orange.opacity(0.15)
        } else {
            return Color.secondary.opacity(0.1)
        }
    }
    
    // Format bytes helper
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
