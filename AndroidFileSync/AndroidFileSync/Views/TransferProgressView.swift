//
//  TransferProgressView.swift
//  AndroidFileSync
//
//  Resizable transfer progress panel with overlay progress bars
//

import SwiftUI

// Simple data structure for transfer items
struct TransferItemData: Identifiable {
    let id: String
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

// Batch transfer info
struct BatchTransferInfo {
    let completed: Int
    let total: Int
    let isDownload: Bool
}

// MARK: - Main Resizable Transfer View

struct TransferProgressView: View {
    let title: String
    let items: [TransferItemData]
    var batchInfo: BatchTransferInfo? = nil
    var onCancel: ((TransferItemData) -> Void)? = nil
    var onCancelAll: (() -> Void)? = nil
    
    // Live concurrency control
    var concurrencyBinding: Binding<Int>? = nil
    var isWirelessConnection: Bool = false
    
    // Folder-scan state
    var isScanning: Bool = false
    var scanningFolderName: String = ""
    var folderName: String = ""   // shown while downloading a folder
    
    @State private var panelHeight: CGFloat = 120
    @State private var isCollapsed: Bool = false
    
    private let minHeight: CGFloat = 0
    private let maxHeight: CGFloat = 250
    private let collapsedThreshold: CGFloat = 30
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            // Drag handle
            dragHandle
            
            if isCollapsed {
                minimizedContent
            } else {
                expandedContent
            }
        }
        .frame(height: isCollapsed ? 34 : panelHeight)
        .background(
            NonDraggableBackground()
                .background(Color(NSColor.controlBackgroundColor))
        )
    }
    
    // MARK: - Minimized Content
    
    private var minimizedContent: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.blue)
            
            // Overall progress bar filling behind
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: geometry.size.width * fileFractionProgress)
                    
                    // Text overlay
                    HStack {
                        Text("\(completedCount)/\(totalCount) transfers")
                            .font(.system(.caption2, weight: .medium))
                        Spacer()
                        Text("\(Int(fileFractionProgress * 100))%")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 6)
                }
            }
            .frame(height: 18)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
    }
    
    // MARK: - Expanded Content
    
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: isScanning ? "magnifyingglass.circle" : (folderName.isEmpty ? "arrow.down.circle.fill" : "folder.badge.gearshape"))
                    .font(.system(size: 12))
                    .foregroundColor(isScanning ? .orange : .blue)
                
                if isScanning {
                    Text("Scanning \(scanningFolderName)…")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(.orange)
                } else if !folderName.isEmpty {
                    Text("\(folderName) — \(title)")
                        .font(.system(.caption, weight: .semibold))
                } else {
                    Text(title)
                        .font(.system(.caption, weight: .semibold))
                }
                
                Spacer()
                
                if let batch = batchInfo {
                    Text("\(batch.completed)/\(batch.total)")
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundColor(.green)
                }
                
                // Live concurrency stepper
                if let binding = concurrencyBinding {
                    Divider().frame(height: 12)
                    HStack(spacing: 4) {
                        Button { binding.wrappedValue = max(1, binding.wrappedValue - 1) } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("Fewer simultaneous downloads")
                        
                        Text("\(binding.wrappedValue)")
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .frame(minWidth: 14, alignment: .center)
                        
                        Button { binding.wrappedValue = min(10, binding.wrappedValue + 1) } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .help("More simultaneous downloads")
                    }
                    .foregroundColor(.secondary)
                    
                    // Wireless hint
                    if isWirelessConnection {
                        Text("Best: 1–5 on WiFi")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }
                
                // Cancel All button
                if items.count > 1 || batchInfo != nil {
                    Divider().frame(height: 12)
                    Button(action: { onCancelAll?() }) {
                        HStack(spacing: 2) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                            Text("Cancel All")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel all active transfers")
                }
            }
            
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(items) { item in
                        OverlayProgressRow(item: item, onCancel: onCancel)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }
    
    // MARK: - Drag Handle
    
    private var dragHandle: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 40, height: 4)
                .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let baseHeight = isCollapsed ? 34 : panelHeight
                    let newHeight = baseHeight - value.translation.height
                    if newHeight < collapsedThreshold {
                        isCollapsed = true
                        panelHeight = 34
                    } else {
                        isCollapsed = false
                        panelHeight = min(max(newHeight, 60), maxHeight)
                    }
                }
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                isCollapsed.toggle()
                if !isCollapsed {
                    panelHeight = 120
                } else {
                    panelHeight = 34
                }
            }
        }
        .onHover { isHovered in
            if isHovered {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
    }
    
    // MARK: - Computed Properties
    
    private var completedCount: Int {
        if let batch = batchInfo { return batch.completed }
        return items.filter { $0.isComplete }.count
    }
    
    private var totalCount: Int {
        if let batch = batchInfo { return batch.total }
        return items.count
    }
    
    private var overallProgress: Double {
        guard !items.isEmpty else { return 0 }
        let totalProgress = items.reduce(0.0) { $0 + $1.progress }
        return totalProgress / Double(items.count)
    }
    
    private var fileFractionProgress: Double {
        let total = totalCount
        guard total > 0 else { return 0 }
        return Double(completedCount) / Double(total)
    }
}

// MARK: - Row with Overlay Progress Bar

struct OverlayProgressRow: View {
    let item: TransferItemData
    var onCancel: ((TransferItemData) -> Void)? = nil
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Progress bar as background
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                
                // Animated progress fill
                RoundedRectangle(cornerRadius: 4)
                    .fill(progressColor.opacity(0.25))
                    .frame(width: geometry.size.width * (item.isComplete ? 1.0 : item.progress))
                
                // Content overlay
                HStack(spacing: 6) {
                    // Status icon
                    statusIcon
                        .frame(width: 14)
                    
                    // File name
                    Text(item.fileName)
                        .font(.system(.caption2, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Speed/Status
                    Text(statusText)
                        .font(.system(.caption2, weight: .semibold))
                        .foregroundColor(statusColor)
                        .frame(width: 55, alignment: .trailing)
                    
                    // Cancel button
                    if !item.isComplete && !item.isCancelled && item.error == nil {
                        Button(action: { onCancel?(item) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
        .frame(height: 24)
    }
    
    private var progressColor: Color {
        if item.isComplete { return .green }
        if item.error != nil { return .red }
        return item.isUpload ? .orange : .blue
    }
    
    private var statusIcon: some View {
        Group {
            if item.isComplete {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if item.error != nil {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
            } else if item.percentage == 0 && item.bytesTransferred == 0 {
                Image(systemName: "clock").foregroundColor(.secondary)
            } else {
                Image(systemName: item.isUpload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundColor(item.isUpload ? .orange : .blue)
            }
        }
        .font(.system(size: 11))
    }
    
    private var statusText: String {
        if item.isComplete { return "Done" }
        if item.error != nil { return "Error" }
        if !item.speed.isEmpty { return item.speed }
        if item.percentage == 0 {
            return item.bytesTransferred > 0 ? "<1%" : "Starting…"
        }
        return "\(item.percentage)%"
    }
    
    private var statusColor: Color {
        if item.isComplete { return .green }
        if item.error != nil { return .red }
        if item.percentage == 0 && item.bytesTransferred == 0 { return .secondary }
        return .blue
    }
}

// MARK: - Non-Draggable Background (stops AppKit window background dragging)

class NonDraggableNSView: NSView {
    override var mouseDownCanMoveWindow: Bool {
        return false
    }
}

struct NonDraggableBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return NonDraggableNSView()
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {}
}
