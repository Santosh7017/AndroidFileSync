//
//  ActionToolbar.swift
//  AndroidFileSync
//
//  Toolbar with file action buttons (New Folder, New File, Refresh, etc.)
//

import SwiftUI

struct ActionToolbar: View {
    let currentPath: String
    @ObservedObject var fileActionManager: FileActionManager
    let onRefresh: () async -> Void
    // Dialog states
    @State private var showNewFolderDialog = false
    @State private var showNewFileDialog = false

    // Search state - bound to parent
    @Binding var searchQuery: String
    var totalFileCount: Int = 0
    var filteredFileCount: Int = 0
    
    // Sorting - passed in from parent for sync with column headers
    var selectedSort: SortOption = .name
    var onSortChanged: ((SortOption) -> Void)?
    @FocusState private var isSearchFocused: Bool
    
    enum SortOption: String, CaseIterable {
        case name = "Name"
        case size = "Size"
        case type = "Type"
        case date = "Date"
    }
    
    var isSearchActive: Bool {
        !searchQuery.isEmpty
    }
    
    var body: some View {
        HStack(spacing: 8) {
            // New Folder button
            Button {
                if let name = TextInputDialog.show(
                    title: "New Folder",
                    message: "Enter a name for the new folder",
                    placeholder: "Folder name",
                    initialValue: "New Folder",
                    confirmLabel: "Create"
                ) {
                    Task {
                        do {
                            try await fileActionManager.createFolder(at: currentPath, name: name)
                            await onRefresh()
                        } catch {
                            print("Failed to create folder: \(error.localizedDescription)")
                        }
                    }
                }
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Create new folder (⌘⇧N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            // New File button
            Button {
                if let name = TextInputDialog.show(
                    title: "New File",
                    message: "Enter a name for the new file",
                    placeholder: "File name",
                    initialValue: "untitled.txt",
                    confirmLabel: "Create"
                ) {
                    Task {
                        do {
                            try await fileActionManager.createFile(at: currentPath, name: name)
                            await onRefresh()
                        } catch {
                            print("Failed to create file: \(error.localizedDescription)")
                        }
                    }
                }
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Create new file")
            
            Divider()
                .frame(height: 16)
            
            // Clipboard indicator or Loading indicator
            if fileActionManager.isPerformingAction {
                // Show loading indicator during action - flexible but won't grow infinitely
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text(fileActionManager.currentAction)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 200) // Max width, but can shrink
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
                .layoutPriority(-1) // Lower priority than search field
                
                Divider()
                    .frame(height: 16)
            } else if !fileActionManager.clipboard.isEmpty {
                HStack(spacing: 6) {
                    // Operation icon + count
                    Image(systemName: fileActionManager.clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text("\(fileActionManager.clipboard.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Divider()
                        .frame(height: 12)
                    
                    // Paste button (icon + text, non-wrapping)
                    Button {
                        Task {
                            do {
                                try await fileActionManager.paste(to: currentPath)
                            } catch {
                                print("❌ Paste failed: \(error.localizedDescription)")
                            }
                            await onRefresh()
                        }
                    } label: {
                        HStack(spacing: 2) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                            Text("Paste")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .buttonStyle(.borderless)
                    
                    // Clear clipboard
                    Button {
                        fileActionManager.clearClipboard()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Clear clipboard")
                }
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(6)
                
                Divider()
                    .frame(height: 16)
            }
            Spacer()
            
            // Search Field - Always visible, better styled
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(isSearchActive ? .accentColor : .secondary)
                
                TextField("Search files...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(minWidth: 120, maxWidth: 200)
                    .focused($isSearchFocused)
                
                // Clear button or result count
                if isSearchActive {
                    HStack(spacing: 4) {
                        // Show filtered count
                        Text("\(filteredFileCount)/\(totalFileCount)")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2))
                            .cornerRadius(4)
                        
                        // Clear button
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search (Esc)")
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(NSColor.textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSearchFocused ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
            )
            .layoutPriority(1) // Higher priority than action indicator
            .onTapGesture {
                isSearchFocused = true
            }
            
            // Sort menu
            Menu {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Button {
                        onSortChanged?(option)
                    } label: {
                        HStack {
                            Text(option.rawValue)
                            if selectedSort == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(selectedSort.rawValue)
                        .font(.caption)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)
            .help("Sort by")
            
            // Refresh button
            Button {
                Task { await onRefresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh (⌘R)")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        // Handle Escape key to clear search
        .onExitCommand {
            if isSearchActive {
                searchQuery = ""
            }
        }
    }
}

#Preview {
    struct PreviewWrapper: View {
        @State var search = ""
        var body: some View {
            ActionToolbar(
                currentPath: "/sdcard",
                fileActionManager: FileActionManager(),
                onRefresh: {},
                searchQuery: $search,
                totalFileCount: 50,
                filteredFileCount: 12
            )
        }
    }
    return PreviewWrapper()
}
