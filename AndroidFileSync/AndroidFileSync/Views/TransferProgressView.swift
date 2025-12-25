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

struct TransferProgressView: View {
    let title: String
    let items: [TransferItemData]
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                // Header
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
                    
                    // Active transfers count
                    Text("\(items.count)")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(Color.blue.opacity(0.8))
                        )
                }
                .padding(.bottom, 4)
                
                // Transfer items
                ForEach(items) { item in
                    TransferItemView(item: item, onCancel: onCancel)
                }
            }
            .padding(16)
            .background(
                ZStack {
                    // Subtle gradient background
                    LinearGradient(
                        colors: [
                            Color(NSColor.controlBackgroundColor).opacity(0.95),
                            Color(NSColor.controlBackgroundColor).opacity(0.85)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    
                    // Glass morphism effect
                    Color.white.opacity(0.03)
                }
            )
        }
    }
}

// MARK: - Individual Transfer Item

struct TransferItemView: View {
    let item: TransferItemData
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // File name and status
            HStack(spacing: 8) {
                Image(systemName: item.isUpload ? "arrow.up.doc.fill" : "arrow.down.doc.fill")
                    .foregroundColor(statusColor)
                    .font(.body)
                
                Text(item.fileName)
                    .font(.system(.callout, design: .default, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                
                Spacer()
                
                if let error = item.error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                        .help(error)
                } else if item.isCancelled {
                    Text("Cancelled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if item.isComplete {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.body)
                } else {
                    // Cancel button - only show for in-progress transfers
                    Button(action: {
                        onCancel?(item)
                    }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel transfer")
                }
            }
            
            // Progress bar with gradient
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 8)
                    
                    // Progress fill with gradient - NO animation
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(
                                colors: progressGradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: geometry.size.width * item.progress, height: 8)
                }
            }
            .frame(height: 8)
            
            // Stats row
            HStack(spacing: 12) {
                // Percentage with icon
                HStack(spacing: 4) {
                    Image(systemName: "percent")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    Text("\(item.percentage)")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .frame(minWidth: 45, alignment: .leading)
                
                // Speed with animation
                if !item.speed.isEmpty && !item.isComplete {
                    HStack(spacing: 4) {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.8))
                        Text(item.speed)
                            .font(.system(.caption, design: .rounded, weight: .medium))
                            .foregroundColor(.blue.opacity(0.9))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                
                Spacer()
                
                // Bytes transferred / total
                Text("\(formatBytes(item.bytesTransferred)) / \(formatBytes(item.totalBytes))")
                    .font(.system(.caption, design: .monospaced, weight: .regular))
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(itemBackground)
                .shadow(color: Color.black.opacity(0.05), radius: 2, x: 0, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }
    
    private var statusColor: Color {
        if item.error != nil {
            return .red
        } else if item.isCancelled {
            return .secondary
        } else if item.isComplete {
            return .green
        } else {
            return item.isUpload ? .blue : .purple
        }
    }
    
    private var progressGradient: [Color] {
        if item.error != nil {
            return [.red.opacity(0.8), .red]
        } else if item.isComplete {
            return [.green.opacity(0.7), .green]
        } else {
            return item.isUpload 
                ? [.blue.opacity(0.7), .blue]
                : [.purple.opacity(0.7), .purple]
        }
    }
    
    private var itemBackground: Color {
        if item.error != nil {
            return Color.red.opacity(0.08)
        } else if item.isComplete {
            return Color.green.opacity(0.08)
        } else {
            return Color(NSColor.controlBackgroundColor).opacity(0.6)
        }
    }
    
    private var borderColor: Color {
        if item.error != nil {
            return Color.red.opacity(0.2)
        } else if item.isComplete {
            return Color.green.opacity(0.2)
        } else {
            return item.isUpload 
                ? Color.blue.opacity(0.15)
                : Color.purple.opacity(0.15)
        }
    }
    
    // Helper function for formatting bytes
    private func formatBytes(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

// MARK: - Helper Function
