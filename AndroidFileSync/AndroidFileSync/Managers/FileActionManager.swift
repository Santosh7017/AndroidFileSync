//
//  FileActionManager.swift
//  AndroidFileSync
//
//  Manages file operations (delete, rename) with state tracking and Trash support
//

import Foundation
internal import Combine

// Track deleted items for restoration
struct TrashedItem: Identifiable, Codable {
    let id: UUID
    let originalPath: String
    let trashPath: String
    let name: String
    let isDirectory: Bool
    let deletedAt: Date
    
    init(originalPath: String, trashPath: String, name: String, isDirectory: Bool) {
        self.id = UUID()
        self.originalPath = originalPath
        self.trashPath = trashPath
        self.name = name
        self.isDirectory = isDirectory
        self.deletedAt = Date()
    }
}

class FileActionManager: ObservableObject {
    // Track ongoing operations
    @Published var isPerformingAction: Bool = false
    @Published var currentAction: String = ""
    @Published var lastError: String?
    
    // Trash functionality
    @Published var trashedItems: [TrashedItem] = []
    private let trashFolderPath = "/storage/emulated/0/.AndroidFileSync_Trash"
    
    init() {
        // Load trashed items from UserDefaults
        loadTrashedItems()
    }
    
    // MARK: - Trash Management
    
    private func loadTrashedItems() {
        if let data = UserDefaults.standard.data(forKey: "trashedItems"),
           let items = try? JSONDecoder().decode([TrashedItem].self, from: data) {
            trashedItems = items.filter { 
                // Only keep items from last 30 days
                Date().timeIntervalSince($0.deletedAt) < 30 * 24 * 3600
            }
        }
    }
    
    private func saveTrashedItems() {
        if let data = try? JSONEncoder().encode(trashedItems) {
            UserDefaults.standard.set(data, forKey: "trashedItems")
        }
    }
    
    /// Ensures the trash folder exists on the device
    private func ensureTrashFolder() async throws {
        let (code, _, _) = await Shell.runAsync(
            ADBManager.getADBPath(),
            args: ["shell", "mkdir -p '\(trashFolderPath)'"]
        )
        if code != 0 {
            print("⚠️ Could not create trash folder, will delete permanently")
        }
    }
    
    // MARK: - Delete Operation (Move to Trash)
    
    /// Moves a file or folder to trash (soft delete)
    /// - Parameter file: The file to delete
    /// - Parameter permanent: If true, permanently deletes instead of moving to trash
    func deleteFile(_ file: UnifiedFile, permanent: Bool = false) async throws {
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Deleting \(file.name)..."
            lastError = nil
        }
        
        do {
            if permanent {
                // Permanent deletion
                try await ADBManager.deleteFile(devicePath: file.path)
                print("✅ File permanently deleted: \(file.name)")
            } else {
                // Move to trash
                try await ensureTrashFolder()
                
                // Create unique trash path
                let timestamp = Int(Date().timeIntervalSince1970)
                let trashName = "\(timestamp)_\(file.name)"
                let trashPath = "\(trashFolderPath)/\(trashName)"
                
                // Move file to trash
                try await ADBManager.renameFile(oldPath: file.path, newPath: trashPath)
                
                // Track the trashed item
                let trashedItem = TrashedItem(
                    originalPath: file.path,
                    trashPath: trashPath,
                    name: file.name,
                    isDirectory: file.isDirectory
                )
                
                await MainActor.run {
                    trashedItems.insert(trashedItem, at: 0)
                    saveTrashedItems()
                }
                
                print("✅ File moved to trash: \(file.name)")
            }
            
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
            }
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - Restore Operation
    
    /// Restores a file from trash
    /// - Parameter item: The trashed item to restore
    func restoreFile(_ item: TrashedItem) async throws {
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Restoring \(item.name)..."
            lastError = nil
        }
        
        do {
            // Move file back to original location
            try await ADBManager.renameFile(oldPath: item.trashPath, newPath: item.originalPath)
            
            // Remove from trashed items
            await MainActor.run {
                trashedItems.removeAll { $0.id == item.id }
                saveTrashedItems()
                isPerformingAction = false
                currentAction = ""
            }
            
            print("✅ File restored: \(item.name)")
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = "Failed to restore: \(error.localizedDescription)"
            }
            throw error
        }
    }
    
    /// Permanently deletes an item from trash
    func permanentlyDeleteFromTrash(_ item: TrashedItem) async throws {
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Permanently deleting \(item.name)..."
        }
        
        do {
            try await ADBManager.deleteFile(devicePath: item.trashPath)
            
            await MainActor.run {
                trashedItems.removeAll { $0.id == item.id }
                saveTrashedItems()
                isPerformingAction = false
                currentAction = ""
            }
            
            print("✅ Permanently deleted from trash: \(item.name)")
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
            }
            throw error
        }
    }
    
    /// Empties the trash
    func emptyTrash() async throws {
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Emptying trash..."
        }
        
        // Delete the entire trash folder
        let (code, _, error) = await Shell.runAsync(
            ADBManager.getADBPath(),
            args: ["shell", "rm -rf '\(trashFolderPath)'"]
        )
        
        await MainActor.run {
            if code == 0 {
                trashedItems.removeAll()
                saveTrashedItems()
            } else {
                lastError = "Failed to empty trash: \(error)"
            }
            isPerformingAction = false
            currentAction = ""
        }
    }
    
    // MARK: - Rename Operation
    
    /// Renames a file or folder on the Android device
    /// - Parameters:
    ///   - file: The file to rename
    ///   - newName: The new name for the file
    func renameFile(_ file: UnifiedFile, to newName: String) async throws {
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Renaming \(file.name)..."
            lastError = nil
        }
        
        do {
            // Construct the new path by replacing the filename
            let parentPath = (file.path as NSString).deletingLastPathComponent
            let newPath = parentPath + "/" + newName
            
            try await ADBManager.renameFile(oldPath: file.path, newPath: newPath)
            
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
            }
            
            print("✅ File renamed successfully: \(file.name) → \(newName)")
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - Create Folder
    
    /// Creates a new folder on the Android device
    func createFolder(at path: String, name: String) async throws {
        let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
        
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Creating folder \(name)..."
            lastError = nil
        }
        
        do {
            try await ADBManager.createFolder(at: fullPath)
            
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
            }
            
            print("✅ Folder created: \(name)")
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - Create File
    
    /// Creates a new file on the Android device
    func createFile(at path: String, name: String, content: String = "") async throws {
        let fullPath = path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
        
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Creating file \(name)..."
            lastError = nil
        }
        
        do {
            try await ADBManager.createFile(at: fullPath, content: content)
            
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
            }
            
            print("✅ File created: \(name)")
        } catch {
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - Clipboard (Copy/Paste)
    
    @Published var clipboard: [UnifiedFile] = []
    @Published var clipboardOperation: ClipboardOperation = .none
    
    enum ClipboardOperation {
        case none
        case copy
        case cut
    }
    
    /// Copies files to clipboard
    func copyToClipboard(_ files: [UnifiedFile]) {
        clipboard = files
        clipboardOperation = .copy
        print("📋 Copied \(files.count) items to clipboard")
    }
    
    /// Cuts files to clipboard
    func cutToClipboard(_ files: [UnifiedFile]) {
        clipboard = files
        clipboardOperation = .cut
        print("✂️ Cut \(files.count) items to clipboard")
    }
    
    /// Pastes files from clipboard to destination
    func paste(to destinationPath: String) async throws {
        guard !clipboard.isEmpty else { return }
        
        let itemCount = clipboard.count
        let operation = clipboardOperation
        let itemsToPaste = clipboard // Capture before any modifications
        
        await MainActor.run {
            isPerformingAction = true
            currentAction = "Pasting \(itemCount) items..."
            lastError = nil
        }
        
        var successCount = 0
        var failedItems: [(name: String, error: String)] = []
        
        for file in itemsToPaste {
            let destinationFile = destinationPath.hasSuffix("/") 
                ? "\(destinationPath)\(file.name)" 
                : "\(destinationPath)/\(file.name)"
            
            // Check if trying to paste into itself (for directories)
            if file.isDirectory && destinationFile.hasPrefix(file.path) {
                failedItems.append((file.name, "Cannot copy folder into itself"))
                continue
            }
            
            // Check if source and destination are the same
            if file.path == destinationFile {
                failedItems.append((file.name, "Source and destination are the same"))
                continue
            }
            
            do {
                if operation == .cut {
                    // Move operation
                    print("📦 Moving: \(file.path) → \(destinationFile)")
                    try await ADBManager.renameFile(oldPath: file.path, newPath: destinationFile)
                } else {
                    // Copy operation - pass isDirectory flag
                    print("📋 Copying: \(file.path) → \(destinationFile) (isDir: \(file.isDirectory))")
                    try await ADBManager.copyFile(from: file.path, to: destinationFile, isDirectory: file.isDirectory)
                }
                successCount += 1
            } catch {
                print("❌ Failed to paste \(file.name): \(error.localizedDescription)")
                failedItems.append((file.name, error.localizedDescription))
            }
        }
        
        await MainActor.run {
            isPerformingAction = false
            currentAction = ""
            
            // Clear clipboard if it was a cut operation
            if operation == .cut && successCount > 0 {
                clipboard.removeAll()
                clipboardOperation = .none
            }
            
            if !failedItems.isEmpty {
                let failureMessages = failedItems.map { "\($0.name): \($0.error)" }
                lastError = "Failed to paste:\n" + failureMessages.joined(separator: "\n")
            }
        }
        
        print("✅ Pasted \(successCount)/\(itemCount) items")
    }
    
    /// Clears the clipboard
    func clearClipboard() {
        clipboard.removeAll()
        clipboardOperation = .none
    }
    
    // MARK: - Error Handling
    
    /// Clears the last error
    func clearError() {
        lastError = nil
    }
}
