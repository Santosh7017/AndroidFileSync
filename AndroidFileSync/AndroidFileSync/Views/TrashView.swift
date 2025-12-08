//
//  TrashView.swift
//  AndroidFileSync
//
//  View for managing deleted files (Trash)
//

import SwiftUI

struct TrashView: View {
    @ObservedObject var fileActionManager: FileActionManager
    @Environment(\.dismiss) private var dismiss
    @State private var showEmptyTrashConfirmation = false
    @State private var showPermanentDeleteConfirmation = false
    @State private var itemToDelete: TrashedItem? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Label("Trash", systemImage: "trash")
                    .font(.headline)
                
                Spacer()
                
                Text("\(fileActionManager.trashedItems.count) items")
                    .foregroundColor(.secondary)
                    .font(.caption)
                
                if !fileActionManager.trashedItems.isEmpty {
                    Button("Empty Trash") {
                        showEmptyTrashConfirmation = true
                    }
                    .foregroundColor(.red)
                    .font(.caption)
                }
                
                // Close button
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Trash content
            if fileActionManager.trashedItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "trash.slash")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("Trash is empty")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(fileActionManager.trashedItems) { item in
                    HStack {
                        Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                            .foregroundColor(item.isDirectory ? .blue : .gray)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)
                            Text("Deleted \(item.deletedAt, style: .relative) ago")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Restore button
                        Button {
                            Task {
                                try? await fileActionManager.restoreFile(item)
                            }
                        } label: {
                            Label("Restore", systemImage: "arrow.uturn.backward")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        
                        // Permanent delete button
                        Button {
                            itemToDelete = item
                            showPermanentDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        // Empty Trash confirmation
        .alert("Empty Trash?", isPresented: $showEmptyTrashConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Empty Trash", role: .destructive) {
                Task {
                    try? await fileActionManager.emptyTrash()
                }
            }
        } message: {
            Text("All \(fileActionManager.trashedItems.count) items will be permanently deleted. This cannot be undone.")
        }
        // Permanent delete confirmation
        .alert("Delete Permanently?", isPresented: $showPermanentDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
            Button("Delete Permanently", role: .destructive) {
                if let item = itemToDelete {
                    Task {
                        try? await fileActionManager.permanentlyDeleteFromTrash(item)
                    }
                }
                itemToDelete = nil
            }
        } message: {
            Text("\"\(itemToDelete?.name ?? "This item")\" will be permanently deleted. This cannot be undone.")
        }
    }
}

// Undo notification bar that appears after deletion
struct UndoDeleteBar: View {
    let deletedItemName: String
    let onUndo: () -> Void
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash.fill")
                .foregroundColor(.white)
            
            Text("\"\(deletedItemName)\" moved to Trash")
                .foregroundColor(.white)
                .lineLimit(1)
            
            Spacer()
            
            Button("Undo") {
                onUndo()
            }
            .buttonStyle(.bordered)
            .tint(.white)
            
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.gray.opacity(0.9))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

#Preview {
    TrashView(fileActionManager: FileActionManager())
        .frame(width: 400, height: 300)
}
