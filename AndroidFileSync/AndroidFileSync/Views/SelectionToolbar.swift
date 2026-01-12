//
//  SelectionToolbar.swift
//  AndroidFileSync
//
//  Toolbar for batch operations on selected files
//

import SwiftUI

struct SelectionToolbar: View {
    let selectedFiles: [UnifiedFile]
    let onClearSelection: () -> Void
    let onDelete: () -> Void
    let onDownload: () -> Void
    let onRename: ((UnifiedFile, String) -> Void)?
    let onChangeExtension: ((String) -> Void)?
    
    @State private var showingDeleteConfirmation = false
    @State private var showingRenameDialog = false
    @State private var showingExtensionDialog = false
    @State private var newFileName = ""
    @State private var newExtension = ""
    
    private var selectedCount: Int { selectedFiles.count }
    private var isSingleSelection: Bool { selectedCount == 1 }
    private var singleItem: UnifiedFile? { isSingleSelection ? selectedFiles.first : nil }
    
    // Check if ALL selected items are files (no folders)
    private var hasOnlyFiles: Bool { 
        !selectedFiles.isEmpty && selectedFiles.allSatisfy { !$0.isDirectory } 
    }
    
    // Show rename for single selection (file OR folder)
    private var showRename: Bool {
        isSingleSelection && onRename != nil
    }
    
    // Show change extension for multiple files only (no folders)
    private var showChangeExtension: Bool {
        selectedCount > 1 && hasOnlyFiles && onChangeExtension != nil
    }
    
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 12) {
                // Selection count
                Label("\(selectedCount) selected", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundColor(.blue)
                
                Spacer()
                
                // Clear selection
                Button {
                    onClearSelection()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                
                Divider()
                    .frame(height: 20)
                
                // Rename (only for single selection - file or folder)
                if showRename {
                    Button {
                        if let item = singleItem {
                            newFileName = item.name
                            showingRenameDialog = true
                        }
                    } label: {
                        Label("Rename", systemImage: "pencil")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                // Change Extension (only for multiple files, no folders)
                if showChangeExtension {
                    Button {
                        showingExtensionDialog = true
                    } label: {
                        Label("Change Ext", systemImage: "doc.badge.gearshape")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                
                // Download
                Button {
                    onDownload()
                } label: {
                    Label(isSingleSelection ? "Download" : "Download All", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                
                // Move to Trash
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Label(isSingleSelection ? "Move to Trash" : "Move All to Trash", systemImage: "trash.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.95))
        }
        // Move to Trash confirmation
        .alert(isSingleSelection ? "Move \(singleItem?.name ?? "item") to Trash?" : "Move \(selectedCount) items to Trash?", 
               isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Move to Trash", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("You can restore \(isSingleSelection ? "this item" : "these items") from the Trash.")
        }
        // Rename dialog
        .alert("Rename \(singleItem?.isDirectory == true ? "folder" : "file")", isPresented: $showingRenameDialog) {
            TextField("New name", text: $newFileName)
            Button("Cancel", role: .cancel) {
                newFileName = ""
            }
            Button("Rename") {
                if let item = singleItem, !newFileName.isEmpty && newFileName != item.name {
                    onRename?(item, newFileName)
                }
                newFileName = ""
            }
        } message: {
            Text("Enter a new name for \(singleItem?.name ?? "this item")")
        }
        // Change extension dialog
        .alert("Change Extension", isPresented: $showingExtensionDialog) {
            TextField("New extension (e.g., jpg, png)", text: $newExtension)
            Button("Cancel", role: .cancel) {
                newExtension = ""
            }
            Button("Apply to \(selectedCount) files") {
                if !newExtension.isEmpty {
                    let ext = newExtension.hasPrefix(".") ? String(newExtension.dropFirst()) : newExtension
                    onChangeExtension?(ext)
                }
                newExtension = ""
            }
        } message: {
            Text("Change extension for all \(selectedCount) selected files")
        }
    }
}

#Preview {
    VStack {
        Spacer()
        SelectionToolbar(
            selectedFiles: [
                UnifiedFile(name: "test.jpg", path: "/test.jpg", isDirectory: false, size: 1024)
            ],
            onClearSelection: {},
            onDelete: {},
            onDownload: {},
            onRename: { _, _ in },
            onChangeExtension: nil
        )
    }
}
