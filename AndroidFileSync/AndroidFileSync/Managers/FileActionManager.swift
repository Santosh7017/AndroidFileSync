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
    
    // MARK: - Paste Conflict Resolution
    
    enum ConflictResolution {
        case replace    // overwrite existing
        case keepBoth   // rename to _copy
        case skip       // skip the conflicting file
    }
    
    struct PasteConflict: Identifiable {
        let id = UUID()
        let file: UnifiedFile         // item being pasted
        let destinationPath: String   // full dest path that already exists
    }
    
    /// Non-empty when paste found existing files — UI should present a confirmation
    @Published var pasteConflicts: [PasteConflict] = []
    /// Pending items that were conflict-free (stored while waiting for user's resolution)
    private var pendingPasteItems: [(file: UnifiedFile, dest: String)] = []
    private var pendingDestinationPath: String = ""
    private var pendingOperation: ClipboardOperation = .none
    
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
            args: ADBManager.deviceArgs(["shell", "mkdir -p '\(trashFolderPath)'"])
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
            args: ADBManager.deviceArgs(["shell", "rm -rf '\(trashFolderPath)'"])
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
        // ── Guard: empty name ──────────────────────────────────────────────
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Rename", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Name cannot be empty."])
        }

        // ── Guard: same name (no-op) ───────────────────────────────────────
        guard trimmed != file.name else { return }

        // ── Construct new path ─────────────────────────────────────────────
        let parentPath = (file.path as NSString).deletingLastPathComponent
        let newPath    = parentPath + "/" + trimmed

        // ── Pre-flight: check if the new name already exists on device ─────
        let escaped = newPath.replacingOccurrences(of: "'", with: "'\\''")
        let (_, testOut, _) = await Shell.runAsync(
            ADBManager.getADBPath(),
            args: ADBManager.deviceArgs(["shell", "[ -e '\(escaped)' ] && echo 1 || echo 0"])
        )
        if testOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
            throw NSError(
                domain: "Rename", code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "\"\(trimmed)\" already exists in this folder. Choose a different name."]
            )
        }

        await MainActor.run {
            isPerformingAction = true
            currentAction = "Renaming \(file.name)…"
            lastError = nil
        }

        do {
            try await ADBManager.renameFile(oldPath: file.path, newPath: newPath)
            await MainActor.run { isPerformingAction = false; currentAction = "" }
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
    }
    
    /// Cuts files to clipboard
    func cutToClipboard(_ files: [UnifiedFile]) {
        clipboard = files
        clipboardOperation = .cut
    }
    
    /// Phase 1: ensure destination exists, build candidate paths, check for conflicts.
    /// If conflicts are found they are published to `pasteConflicts` and this method returns
    /// without copying anything. The UI should then call `resumePaste(resolution:)`.
    func paste(to destinationPath: String) async throws {
        guard !clipboard.isEmpty else { return }

        let operation    = clipboardOperation
        let itemsToPaste = clipboard

        await MainActor.run {
            isPerformingAction = true
            currentAction      = "Checking destination…"
            lastError          = nil
            pasteConflicts     = []
        }

        // Auto-create destination (handles Quick Access folders that don't exist yet)
        let escapedDest = destinationPath.replacingOccurrences(of: "'", with: "'\\''")
        let mkdirResult = await Shell.runAsync(
            ADBManager.getADBPath(),
            args: ADBManager.deviceArgs(["shell", "mkdir -p '\(escapedDest)'"])
        )
        if mkdirResult.0 != 0 {
            await MainActor.run {
                isPerformingAction = false
                currentAction      = ""
                lastError          = "Cannot create destination: \(destinationPath)\n\(mkdirResult.2)"
            }
            return
        }

        var readyItems:    [(file: UnifiedFile, dest: String)] = []
        var conflictItems: [(file: UnifiedFile, dest: String)] = []

        for file in itemsToPaste {
            let baseDest = destinationPath.hasSuffix("/")
                ? "\(destinationPath)\(file.name)"
                : "\(destinationPath)/\(file.name)"

            // Prevent copying folder into itself
            if file.isDirectory && baseDest.hasPrefix(file.path) { continue }

            // Same folder: always rename to _copy (no confirm needed)
            if file.path == baseDest {
                let copyPath = await uniqueCopyPath(original: file.path, inDirectory: destinationPath, isDirectory: file.isDirectory)
                readyItems.append((file, copyPath))
                continue
            }

            // Check if destination already exists on device
            let escBase = baseDest.replacingOccurrences(of: "'", with: "'\\''")
            let (_, testOut, _) = await Shell.runAsync(
                ADBManager.getADBPath(),
                args: ADBManager.deviceArgs(["shell", "[ -e '\(escBase)' ] && echo 1 || echo 0"])
            )
            if testOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1" {
                conflictItems.append((file, baseDest))
            } else {
                readyItems.append((file, baseDest))
            }
        }

        await MainActor.run { isPerformingAction = false }

        if conflictItems.isEmpty {
            try await executePaste(items: readyItems, operation: operation)
        } else {
            // Surface conflicts to UI
            pendingPasteItems      = readyItems
            pendingDestinationPath = destinationPath
            pendingOperation       = operation
            await MainActor.run {
                pasteConflicts = conflictItems.map { PasteConflict(file: $0.file, destinationPath: $0.dest) }
            }
        }
    }

    /// Phase 2: called by the UI after the user picks how to resolve conflicts.
    func resumePaste(resolution: ConflictResolution) async throws {
        let conflicts = pasteConflicts
        let ready     = pendingPasteItems
        let dest      = pendingDestinationPath
        let operation = pendingOperation

        await MainActor.run { pasteConflicts = [] }

        var allItems = ready
        for conflict in conflicts {
            switch resolution {
            case .replace:
                allItems.append((conflict.file, conflict.destinationPath))
            case .keepBoth:
                // Probe the device to find a truly free name (async, loop)
                let safePath = await uniqueCopyPath(
                    original: conflict.destinationPath,
                    inDirectory: dest,
                    isDirectory: conflict.file.isDirectory
                )
                allItems.append((conflict.file, safePath))
            case .skip:
                break
            }
        }

        try await executePaste(items: allItems, operation: operation)
    }

    /// Execute a resolved list of paste items.
    private func executePaste(items: [(file: UnifiedFile, dest: String)],
                              operation: ClipboardOperation) async throws {
        guard !items.isEmpty else {
            await MainActor.run { clipboard.removeAll(); clipboardOperation = .none }
            return
        }

        let n = items.count
        await MainActor.run {
            isPerformingAction = true
            currentAction      = "Pasting \(n) item\(n > 1 ? "s" : "")…"
        }

        var successCount = 0
        var failedItems: [(name: String, error: String)] = []
        var successPaths: [String] = []

        for (file, destFile) in items {
            print("\u{1F4CB} Paste: \(operation == .cut ? "move" : "copy") '\(file.path)' \u{2192} '\(destFile)'")
            do {
                if operation == .cut {
                    try await ADBManager.renameFile(oldPath: file.path, newPath: destFile)
                } else {
                    try await ADBManager.copyFile(from: file.path, to: destFile, isDirectory: file.isDirectory)
                }
                successPaths.append(destFile)
                successCount += 1
            } catch {
                print("\u{274C} Failed to paste \(file.name): \(error.localizedDescription)")
                failedItems.append((file.name, error.localizedDescription))
            }
        }

        // Trigger media scan for all pasted files (runs after paste is done, doesn't block UI)
        for path in successPaths {
            await ADBManager.triggerMediaScan(path: path)
        }

        await MainActor.run {
            isPerformingAction = false
            currentAction      = ""
            if successCount > 0 { clipboard.removeAll(); clipboardOperation = .none }
            if !failedItems.isEmpty {
                lastError = "Failed to paste \(failedItems.count) item(s):\n"
                    + failedItems.map { "\($0.name): \($0.error)" }.joined(separator: "\n")
            }
        }
    }
    
    /// Generates a guaranteed-unique destination path for "Keep Both".
    /// Probes the device via ADB: photo.jpg → photo_copy.jpg → photo_copy_2.jpg → …
    /// Caps at 99 iterations as a safety net.
    private func uniqueCopyPath(original: String, inDirectory dir: String, isDirectory: Bool) async -> String {
        let nsPath    = original as NSString
        let ext       = isDirectory ? "" : nsPath.pathExtension
        let nameNoExt = isDirectory
            ? nsPath.lastPathComponent
            : (nsPath.lastPathComponent as NSString).deletingPathExtension

        let base   = dir.hasSuffix("/") ? dir : dir + "/"
        let adb    = ADBManager.getADBPath()

        func candidate(_ suffix: String) -> String {
            ext.isEmpty ? base + nameNoExt + suffix : base + nameNoExt + suffix + "." + ext
        }

        // First try: name_copy[.ext]
        let first = candidate("_copy")
        let esc1  = first.replacingOccurrences(of: "'", with: "'\''") 
        let (_, out1, _) = await Shell.runAsync(adb, args: ADBManager.deviceArgs(["shell", "[ -e '\(esc1)' ] && echo 1 || echo 0"]))
        if out1.trimmingCharacters(in: .whitespacesAndNewlines) != "1" { return first }

        // Subsequent tries: name_copy_2[.ext], name_copy_3[.ext], …
        for n in 2...99 {
            let path = candidate("_copy_\(n)")
            let esc  = path.replacingOccurrences(of: "'", with: "'\''") 
            let (_, out, _) = await Shell.runAsync(adb, args: ADBManager.deviceArgs(["shell", "[ -e '\(esc)' ] && echo 1 || echo 0"]))
            if out.trimmingCharacters(in: .whitespacesAndNewlines) != "1" { return path }
        }

        // Fallback: timestamp-based name (practically impossible to collide)
        return candidate("_copy_\(Int(Date().timeIntervalSince1970))")
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
