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
    
    @State private var newFolderName = ""
    @State private var newFileName = ""
    
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
                newFolderName = "New Folder"
                showNewFolderDialog = true
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Create new folder (⌘⇧N)")
            .keyboardShortcut("n", modifiers: [.command, .shift])
            
            // New File button
            Button {
                newFileName = "untitled.txt"
                showNewFileDialog = true
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
                // Show loading indicator during paste
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 14, height: 14)
                    Text(fileActionManager.currentAction)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(0.15))
                .cornerRadius(6)
                
                Divider()
                    .frame(height: 16)
            } else if !fileActionManager.clipboard.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: fileActionManager.clipboardOperation == .cut ? "scissors" : "doc.on.clipboard")
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text("\(fileActionManager.clipboard.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Paste button
                    Button {
                        Task {
                            // Start paste in background
                            let pasteTask = Task {
                                try await fileActionManager.paste(to: currentPath)
                            }
                            
                            // Quick delay to let mkdir complete, then refresh early
                            try? await Task.sleep(nanoseconds: 800_000_000) // 0.8 second
                            await onRefresh() // Early refresh to show folders appearing
                            
                            // Wait for paste to complete
                            do {
                                try await pasteTask.value
                            } catch {
                                print("❌ Paste failed: \(error.localizedDescription)")
                            }
                            
                            // Final refresh to ensure everything is up to date
                            await onRefresh()
                        }
                    } label: {
                        Label("Paste", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("v", modifiers: .command)
                    
                    // Clear clipboard
                    Button {
                        fileActionManager.clearClipboard()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear clipboard")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.15))
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
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        // Handle Escape key to clear search
        .onExitCommand {
            if isSearchActive {
                searchQuery = ""
            }
        }
        // New Folder dialog
        .alert("New Folder", isPresented: $showNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {
                newFolderName = ""
            }
            Button("Create") {
                let folderName = newFolderName // Capture value before clearing
                newFolderName = ""
                if !folderName.isEmpty {
                    Task {
                        do {
                            try await fileActionManager.createFolder(at: currentPath, name: folderName)
                            await onRefresh()
                        } catch {
                            print("❌ Failed to create folder: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } message: {
            Text("Enter a name for the new folder")
        }
        // New File dialog
        .alert("New File", isPresented: $showNewFileDialog) {
            TextField("File name", text: $newFileName)
            Button("Cancel", role: .cancel) {
                newFileName = ""
            }
            Button("Create") {
                let fileName = newFileName // Capture value before clearing
                newFileName = ""
                if !fileName.isEmpty {
                    Task {
                        do {
                            try await fileActionManager.createFile(at: currentPath, name: fileName)
                            await onRefresh()
                        } catch {
                            print("❌ Failed to create file: \(error.localizedDescription)")
                        }
                    }
                }
            }
        } message: {
            Text("Enter a name for the new file")
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
