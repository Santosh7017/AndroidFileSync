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
    let retryCount: Int
}

// Batch transfer info
struct BatchTransferInfo {
    let downloadCompleted: Int?
    let downloadTotal: Int?
    let uploadCompleted: Int?
    let uploadTotal: Int?
    
    var hasDownloads: Bool {
        if let total = downloadTotal, total > 0 { return true }
        return false
    }
    
    var hasUploads: Bool {
        if let total = uploadTotal, total > 0 { return true }
        return false
    }
    
    var isDual: Bool {
        hasDownloads && hasUploads
    }
    
    var totalCompleted: Int {
        (downloadCompleted ?? 0) + (uploadCompleted ?? 0)
    }
    
    var totalItems: Int {
        (downloadTotal ?? 0) + (uploadTotal ?? 0)
    }
}

enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case downloads = "Downloads"
    case uploads = "Uploads"
    
    var id: String { rawValue }
}

// MARK: - Main Resizable Transfer View

struct TransferProgressView: View {
    let title: String
    let items: [TransferItemData]
    var batchInfo: BatchTransferInfo? = nil
    var onCancel: ((TransferItemData) -> Void)? = nil
    var onCancelAll: (() -> Void)? = nil
    var onCancelAllUploads: (() -> Void)? = nil
    var onCancelAllDownloads: (() -> Void)? = nil
    
    // Live concurrency control
    var concurrencyBinding: Binding<Int>? = nil
    var uploadConcurrencyBinding: Binding<Int>? = nil
    var effectiveDownloadLimit: Int? = nil
    var effectiveUploadLimit: Int? = nil
    var isWirelessConnection: Bool = false
    var isAppOperationBusy: Bool = false
    
    // Folder-scan state
    var isScanning: Bool = false
    var scanningFolderName: String = ""
    var folderName: String = ""   // shown while downloading a folder
    
    @State private var panelHeight: CGFloat = 120
    @State private var isCollapsed: Bool = false
    @State private var filterMode: TransferFilter = .all
    
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
        .onChange(of: items.count) { _ in
            let hasDownloads = items.contains { !$0.isUpload }
            let hasUploads = items.contains { $0.isUpload }
            
            if filterMode == .downloads && !hasDownloads && hasUploads {
                filterMode = .all
            } else if filterMode == .uploads && !hasUploads && hasDownloads {
                filterMode = .all
            }
        }
    }
    
    // MARK: - Minimized Content
    
    private var minimizedContent: some View {
        let hasDownloads = items.contains { !$0.isUpload }
        let hasUploads = items.contains { $0.isUpload }
        let isDual = hasDownloads && hasUploads
        let iconName = isDual ? "arrow.up.arrow.down.circle.fill" : (hasUploads ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
        let fillColor = isDual ? Color.purple : (hasUploads ? Color.orange : Color.blue)
        
        return HStack(spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 10))
                .foregroundColor(fillColor)
            
            // Overall progress bar filling behind
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.15))
                    
                    // Progress fill
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor.opacity(0.4))
                        .frame(width: geometry.size.width * fileFractionProgress)
                    
                    // Text overlay
                    HStack {
                        Text("\(completedCount)/\(totalCount) transfers")
                            .font(.system(.caption2, weight: .medium))
                        Spacer()
                        Text("\(Int(fileFractionProgress * 100))%")
                            .font(.system(.caption2, weight: .bold))
                            .foregroundColor(fillColor)
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
        let hasDownloads = items.contains { !$0.isUpload }
        let hasUploads = items.contains { $0.isUpload }
        let isDual = hasDownloads && hasUploads
        
        return VStack(alignment: .leading, spacing: 4) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: isScanning ? "magnifyingglass.circle" : (isDual ? "arrow.up.arrow.down.circle.fill" : (hasUploads ? "arrow.up.circle.fill" : (folderName.isEmpty ? "arrow.down.circle.fill" : "folder.badge.gearshape"))))
                    .font(.system(size: 12))
                    .foregroundColor(isScanning ? .orange : (isDual ? .purple : (hasUploads ? .orange : .blue)))
                
                if isScanning {
                    Text("Scanning \(scanningFolderName)…")
                        .font(.system(.caption, weight: .semibold))
                        .foregroundColor(.orange)
                } else if !folderName.isEmpty {
                    Text("\(folderName) — \(title)")
                        .font(.system(.caption, weight: .semibold))
                } else if isDual {
                    Text("Active Transfers (Dual)")
                        .font(.system(.caption, weight: .semibold))
                } else {
                    Text(title)
                        .font(.system(.caption, weight: .semibold))
                }
                
                Spacer()
                
                if let batch = batchInfo {
                    HStack(spacing: 6) {
                        if let dlComp = batch.downloadCompleted, let dlTot = batch.downloadTotal {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(dlComp)/\(dlTot)")
                            }
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundColor(.blue)
                        }
                        if let ulComp = batch.uploadCompleted, let ulTot = batch.uploadTotal {
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 9, weight: .bold))
                                Text("\(ulComp)/\(ulTot)")
                            }
                            .font(.system(.caption2, design: .monospaced, weight: .bold))
                            .foregroundColor(.orange)
                        }
                    }
                }
                
                // Concurrency steppers (Downloads and/or Uploads)
                if concurrencyBinding != nil || uploadConcurrencyBinding != nil {
                    Divider().frame(height: 12)
                    
                    if let binding = concurrencyBinding {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.down").font(.system(size: 9, weight: .bold)).foregroundColor(.blue)
                            Button {
                                binding.wrappedValue = max(1, binding.wrappedValue - 1)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Fewer simultaneous downloads")
                            
                            Text("\(binding.wrappedValue)")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .frame(minWidth: 12, alignment: .center)
                            
                            Button {
                                let isDual = (concurrencyBinding != nil) && (uploadConcurrencyBinding != nil)
                                let maxLimit = isWirelessConnection ? (isAppOperationBusy ? (isDual ? 3 : 6) : (isDual ? 4 : 8)) : (isAppOperationBusy ? (isDual ? 5 : 10) : (isDual ? 6 : 12))
                                binding.wrappedValue = min(maxLimit, binding.wrappedValue + 1)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("More simultaneous downloads")
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    if let ulBinding = uploadConcurrencyBinding {
                        HStack(spacing: 2) {
                            Image(systemName: "arrow.up").font(.system(size: 9, weight: .bold)).foregroundColor(.orange)
                            Button {
                                ulBinding.wrappedValue = max(1, ulBinding.wrappedValue - 1)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Fewer simultaneous uploads")
                            
                            Text("\(ulBinding.wrappedValue)")
                                .font(.system(.caption2, design: .monospaced, weight: .bold))
                                .frame(minWidth: 12, alignment: .center)
                            
                            Button {
                                let isDual = (concurrencyBinding != nil) && (uploadConcurrencyBinding != nil)
                                let maxLimit = isWirelessConnection ? (isAppOperationBusy ? (isDual ? 3 : 6) : (isDual ? 4 : 8)) : (isAppOperationBusy ? (isDual ? 5 : 10) : (isDual ? 6 : 12))
                                ulBinding.wrappedValue = min(maxLimit, ulBinding.wrappedValue + 1)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("More simultaneous uploads")
                        }
                        .foregroundColor(.secondary)
                    }
                    
                    // Wireless hint
                    if isWirelessConnection {
                        if isAppOperationBusy {
                            Text("⚠️ WiFi max: 4 (backup active)")
                               .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red)
                        } else {
                            Text("Best: 1–5 on WiFi")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.orange.opacity(0.8))
                        }
                    }
                }
                
                // Filter Menu (if dual transfers active)
                if isDual {
                    Divider().frame(height: 12)
                    Menu {
                        Button {
                            filterMode = .all
                        } label: {
                            HStack {
                                Text("All Transfers (\(items.count))")
                                if filterMode == .all { Image(systemName: "checkmark") }
                            }
                        }
                        
                        Button {
                            filterMode = .downloads
                        } label: {
                            HStack {
                                Text("Downloads Only (\(downloadCount))")
                                if filterMode == .downloads { Image(systemName: "checkmark") }
                            }
                        }
                        
                        Button {
                            filterMode = .uploads
                        } label: {
                            HStack {
                                Text("Uploads Only (\(uploadCount))")
                                if filterMode == .uploads { Image(systemName: "checkmark") }
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 11))
                            Text(filterMode == .all ? "Filter" : filterMode.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundColor(filterMode == .all ? .secondary : .accentColor)
                    }
                    .menuStyle(.borderlessButton)
                    .help("Filter transfers list")
                }
                
                // Cancel options
                if items.count > 1 || batchInfo != nil {
                    Divider().frame(height: 12)
                    if isDual {
                        Menu {
                            Button(role: .destructive) {
                                onCancelAllUploads?()
                            } label: {
                                Label("Cancel All Uploads (\(uploadCount))", systemImage: "arrow.up.circle")
                            }
                            
                            Button(role: .destructive) {
                                onCancelAllDownloads?()
                            } label: {
                                Label("Cancel All Downloads (\(downloadCount))", systemImage: "arrow.down.circle")
                            }
                            
                            Divider()
                            
                            Button(role: .destructive) {
                                onCancelAll?()
                            } label: {
                                Label("Cancel All Transfers (\(items.count))", systemImage: "xmark.circle.fill")
                            }
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                Text("Cancel…")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            .foregroundColor(.red.opacity(0.85))
                        }
                        .menuStyle(.borderlessButton)
                        .help("Cancel options")
                    } else {
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
            }
            
            if filteredItems.isEmpty {
                VStack(spacing: 4) {
                    Spacer()
                    Text("No active \(filterMode.rawValue.lowercased()) transfers")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(.secondary)
                    Button("Show All Transfers (\(items.count))") {
                        filterMode = .all
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredItems) { item in
                            OverlayProgressRow(item: item, onCancel: onCancel)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
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
    
    private var downloadCount: Int {
        if let batch = batchInfo, let total = batch.downloadTotal { return total }
        return items.filter { !$0.isUpload }.count
    }
    
    private var uploadCount: Int {
        if let batch = batchInfo, let total = batch.uploadTotal { return total }
        return items.filter { $0.isUpload }.count
    }
    
    private var filteredItems: [TransferItemData] {
        switch filterMode {
        case .all:
            return items
        case .downloads:
            return items.filter { !$0.isUpload }
        case .uploads:
            return items.filter { $0.isUpload }
        }
    }
    
    private var completedCount: Int {
        if let batch = batchInfo { return batch.totalCompleted }
        return items.filter { $0.isComplete }.count
    }
    
    private var totalCount: Int {
        if let batch = batchInfo { return batch.totalItems }
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
            if item.bytesTransferred > 0 {
                return "<1%"
            } else {
                return item.retryCount > 0 ? "Retrying…" : "Starting…"
            }
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
