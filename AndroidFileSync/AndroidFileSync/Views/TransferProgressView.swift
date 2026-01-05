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
            
            VStack(alignment: .leading, spacing: 12) {
                // Header with batch progress
                headerView
                
                // Overall batch progress bar (if batch download)
                if let batch = batchInfo {
                    batchProgressView(batch: batch)
                }
                
                // Compact file list (scrollable if many files)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(items) { item in
                            CompactTransferItemView(item: item, onCancel: onCancel)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            .padding(12)
            .background(
                Color(NSColor.controlBackgroundColor).opacity(0.95)
            )
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle.fill")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .font(.title3)
            
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
            
            Spacer()
            
            // Show batch progress: "X / Y completed"
            if let batch = batchInfo {
                HStack(spacing: 6) {
                    Text("\(batch.completed)")
                        .font(.system(.subheadline, design: .rounded, weight: .bold))
                        .foregroundColor(.green)
                    
                    Text("/")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("\(batch.total)")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Text("completed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.green.opacity(0.15))
                )
            } else {
                // Fallback: just show count
                Text("\(items.count) active")
                    .font(.system(.caption, design: .rounded, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.blue.opacity(0.8)))
            }
        }
    }
    
    private func batchProgressView(batch: BatchTransferInfo) -> some View {
        VStack(spacing: 4) {
            // Overall progress bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.8), .green],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * CGFloat(batch.completed) / CGFloat(max(batch.total, 1)))
                }
            }
            .frame(height: 6)
            
            // Percentage text
            HStack {
                Text("Overall Progress")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(Double(batch.completed) / Double(max(batch.total, 1)) * 100))%")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }
}

// MARK: - Compact Transfer Item View

struct CompactTransferItemView: View {
    let item: TransferItemData
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        HStack(spacing: 8) {
            // Status icon
            statusIcon
                .frame(width: 18)
            
            // File name
            Text(item.fileName)
                .font(.system(.caption, design: .default, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            
            // Progress bar (compact)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    
                    RoundedRectangle(cornerRadius: 3)
                        .fill(progressColor)
                        .frame(width: geometry.size.width * item.progress)
                }
            }
            .frame(height: 6)
            
            // Percentage
            Text("\(item.percentage)%")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundColor(.secondary)
                .frame(width: 35, alignment: .trailing)
            
            // Speed (if available)
            if !item.speed.isEmpty && !item.isComplete {
                Text(item.speed)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundColor(.blue)
                    .frame(width: 55, alignment: .trailing)
            } else {
                Color.clear.frame(width: 55)
            }
            
            // Cancel or status
            if item.isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else if item.isCancelled {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.caption)
            } else if let error = item.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
                    .help(error)
            } else {
                Button(action: { onCancel?(item) }) {
                    Image(systemName: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help("Cancel")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
    }
    
    private var statusIcon: some View {
        Image(systemName: item.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
            .foregroundColor(item.isComplete ? .green : (item.isUpload ? .blue : .purple))
            .font(.caption)
    }
    
    private var progressColor: Color {
        if item.error != nil {
            return .red
        } else if item.isComplete {
            return .green
        } else {
            return item.isUpload ? .blue : .purple
        }
    }
    
    private var backgroundColor: Color {
        if item.error != nil {
            return Color.red.opacity(0.08)
        } else if item.isComplete {
            return Color.green.opacity(0.08)
        } else {
            return Color(NSColor.controlBackgroundColor).opacity(0.5)
        }
    }
}
