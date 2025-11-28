//
//  FileBrowserView.swift
//  AndroidFileSync
//

import SwiftUI
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let files: [UnifiedFile]
    let currentPath: String
    let isLoading: Bool
    let canGoBack: Bool
    let onNavigate: (String) -> Void
    let onGoBack: () -> Void
    let onDownload: (UnifiedFile) -> Void
    let onUpload: ([URL]) -> Void
    
    // FIX 1: Bring back the state variable for UI feedback
    @State private var isDraggingOver = false
    
    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            fileListOrEmptyState
        }
    }
    
    // MARK: - View Components
    
    private var pathBar: some View {
        HStack {
            if canGoBack {
                backButton
            }
            pathDisplay
            Spacer()
            uploadButton
            Divider().frame(height: 16).padding(.horizontal, 8)
            statusIndicator
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    private var backButton: some View {
        Button(action: onGoBack) {
            Image(systemName: "chevron.left").font(.title3)
        }
        .buttonStyle(.plain)
        .help("Go back")
    }
    
    private var pathDisplay: some View {
        HStack {
            Image(systemName: "folder")
            Text(currentPath)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
    
    private var uploadButton: some View {
        Button(action: showUploadDialog) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                Text("Upload").font(.caption)
            }
        }
        .buttonStyle(.borderless)
        .help("Upload files to this folder")
    }
    
    @ViewBuilder
    private var statusIndicator: some View {
        if isLoading {
            ProgressView().scaleEffect(0.7)
        } else {
            Text("\(files.count) items")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    @ViewBuilder
    private var fileListOrEmptyState: some View {
        ZStack {
            if files.isEmpty && !isLoading {
                emptyFolderView
            } else {
                fileList
            }
            
            if isDraggingOver {
                dropOverlay
            }
        }
        // FIX 2: Use the standard .onDrop with async handling
        .onDrop(of: [.fileURL], isTargeted: $isDraggingOver) { providers in
            Task {
                var urls: [URL] = []
                for provider in providers {
                    if let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                       let url = item as? URL {
                        urls.append(url)
                    }
                }
                
                if !urls.isEmpty {
                    await MainActor.run {
                        onUpload(urls)
                    }
                }
            }
            return true
        }
    }
    
    private var emptyFolderView: some View {
        VStack(spacing: 16) {
            Image(systemName: isDraggingOver ? "arrow.down.doc.fill" : "doc.text.magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            Text(isDraggingOver ? "Drop files to upload" : "Folder is empty")
                .foregroundColor(isDraggingOver ? .blue : .secondary)
            
            if !isDraggingOver {
                Text("Drag files here or click the Upload button")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var fileList: some View {
        // Use a List for standard behavior and selection handling
        List(files) { file in
            FileRowView(file: file, onDownload: onDownload)
                .onTapGesture {
                    if file.isDirectory {
                        onNavigate(file.path)
                    } else {
                        onDownload(file)
                    }
                }
        }
    }
    
    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.blue, lineWidth: 3)
            .background(Color.blue.opacity(0.1))
            .padding(8)
            .transition(.opacity)
    }
    
    // MARK: - Actions
    
    private func showUploadDialog() {
        let openPanel = NSOpenPanel()
        openPanel.configureForPerformance() // Assuming you have this extension
        openPanel.title = "Select Files to Upload"
        openPanel.message = "Choose files to upload to \(currentPath)"
        
        openPanel.begin { response in
            if response == .OK {
                onUpload(openPanel.urls)
            }
        }
    }
}
