//
//  FileRowView.swift
//  AndroidFileSync
//
//  Created by Santosh Morya on 22/11/25.
//

import SwiftUI

// MARK: - File Row View

struct FileRowView: View {
    let file: UnifiedFile
    var isSelected: Bool = false
    let onDownload: (UnifiedFile) -> Void
    let onDelete: ((UnifiedFile) -> Void)?
    let onRename: ((UnifiedFile, String) -> Void)?
    
    @State private var showingDeleteConfirmation = false
    @State private var showingRenameDialog = false
    @State private var newFileName = ""
    
    
    var body: some View {
        HStack(spacing: 12) {
            // Selection Checkbox (Visual Only)
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .foregroundColor(isSelected ? .blue : .secondary)
                .font(.title3)
            
            fileIcon
            fileInfo
            Spacer()
            actionIndicator
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            contextMenuItems
        }
        .alert("Delete \(file.name)?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                onDelete?(file)
            }
        } message: {
            Text("This action cannot be undone.")
        }
        .alert("Rename \(file.name)", isPresented: $showingRenameDialog) {
            TextField("New name", text: $newFileName)
                .onAppear {
                    newFileName = file.name
                }
            Button("Cancel", role: .cancel) {
                newFileName = ""
            }
            Button("Rename") {
                if !newFileName.isEmpty && newFileName != file.name {
                    onRename?(file, newFileName)
                }
                newFileName = ""
            }
        } message: {
            Text("Enter a new name for this \(file.isDirectory ? "folder" : "file")")
        }
    }
    
    // MARK: - View Components
    
    private var fileIcon: some View {
        Image(systemName: getFileIcon())
            .foregroundColor(getFileColor())
            .font(.title3)
            .frame(width: 24, height: 24)
    }
    
    private var fileInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name)
                .font(.body)
                .lineLimit(1)
            
            if !file.isDirectory {
                Text(formatBytes(file.size))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    @ViewBuilder
    private var actionIndicator: some View {
        if file.isDirectory {
            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        } else {
            Button(action: { onDownload(file) }) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .help("Download to Mac")
        }
    }
    
    @ViewBuilder
    private var contextMenuItems: some View {
        if !file.isDirectory {
            Button {
                onDownload(file)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            
            Divider()
        }
        
        Button {
            showingRenameDialog = true
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        .disabled(onRename == nil)
        
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            Label("Delete", systemImage: "trash")
        }
        .disabled(onDelete == nil)
    }
    
    // MARK: - Icon Selection
    
    private func getFileIcon() -> String {
        if file.isDirectory {
            return getFolderIcon()
        } else {
            return getFileTypeIcon()
        }
    }
    
    private func getFolderIcon() -> String {
        switch file.name.lowercased() {
        case "dcim", "camera": return "camera.fill"
        case "download", "downloads": return "arrow.down.circle.fill"
        case "pictures", "photos": return "photo.fill"
        case "music": return "music.note"
        case "movies", "videos": return "film.fill"
        case "documents": return "doc.fill"
        case "whatsapp": return "bubble.left.and.bubble.right.fill"
        default: return "folder.fill"
        }
    }
    
    private func getFileTypeIcon() -> String {
        let ext = (file.name as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return "photo"
        case "mp4", "mov", "avi", "mkv": return "film"
        case "mp3", "m4a", "wav", "flac": return "music.note"
        case "pdf": return "doc.text"
        case "zip", "rar", "7z": return "doc.zipper"
        case "apk": return "app.badge"
        case "txt", "doc", "docx": return "doc.text"
        case "xls", "xlsx": return "tablecells"
        case "ppt", "pptx": return "slider.horizontal.3"
        default: return "doc"
        }
    }
    
    // MARK: - Color Selection
    
    private func getFileColor() -> Color {
        if file.isDirectory {
            return .blue
        }
        
        let ext = (file.name as NSString).pathExtension.lowercased()
        
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp": return .purple
        case "mp4", "mov", "avi", "mkv": return .red
        case "mp3", "m4a", "wav", "flac": return .pink
        case "pdf": return .orange
        case "apk": return .green
        case "zip", "rar", "7z": return .gray
        case "txt", "doc", "docx": return .blue
        default: return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    List {
        FileRowView(
            file: UnifiedFile(
                from: ADBFile(
                    name: "Sample Video.mp4",
                    path: "/sdcard/Sample Video.mp4",
                    isDirectory: false,
                    size: 1024 * 1024 * 150,
                    modificationDate: Date()
                )
            ),
            isSelected: false,
            onDownload: { _ in },
            onDelete: { _ in },
            onRename: { _, _ in }
        )
        
        FileRowView(
            file: UnifiedFile(
                from: ADBFile(
                    name: "DCIM",
                    path: "/sdcard/DCIM",
                    isDirectory: true,
                    size: 0,
                    modificationDate: nil
                )
            ),
            isSelected: true,
            onDownload: { _ in },
            onDelete: { _ in },
            onRename: { _, _ in }
        )
    }
}
