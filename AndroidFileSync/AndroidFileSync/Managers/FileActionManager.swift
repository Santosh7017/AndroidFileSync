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

struct LiveDeletion: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let filePath: String
    let isPermanent: Bool
    var isRunning: Bool = false
    var isComplete: Bool = false
    var isCancelled: Bool = false
    var error: String? = nil
}

class FileActionManager: ObservableObject {
    // Track ongoing operations
    @Published var isPerformingAction: Bool = false
    @Published var currentAction: String = ""
    @Published var lastError: String?
    
    // Deletion tracking
    @Published var activeDeletions: [LiveDeletion] = []
    
    var isDeleting: Bool {
        !activeDeletions.filter { !$0.isComplete }.isEmpty
    }
    
    var deletingActionText: String {
        let active = activeDeletions.filter { !$0.isComplete }
        if active.isEmpty { return "" }
        if active.count == 1 {
            let del = active[0]
            return (del.isPermanent ? "Deleting " : "Trashing ") + del.fileName
        } else {
            return "Deleting \(active.count) items..."
        }
    }
    
    @MainActor
    func cancelDeletion(id: UUID) {
        if let idx = activeDeletions.firstIndex(where: { $0.id == id }) {
            activeDeletions[idx].isCancelled = true
            if !activeDeletions[idx].isRunning {
                activeDeletions[idx].isComplete = true
            }
        }
        updatePerformingActionState()
        NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
    }
    
    @MainActor
    func cancelAllDeletions() {
        for idx in activeDeletions.indices {
            if !activeDeletions[idx].isComplete {
                activeDeletions[idx].isCancelled = true
                if !activeDeletions[idx].isRunning {
                    activeDeletions[idx].isComplete = true
                }
            }
        }
        updatePerformingActionState()
        NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
    }
    
    @MainActor
    func updatePerformingActionState() {
        let activeDel = activeDeletions.filter { !$0.isComplete }
        if !activeDel.isEmpty {
            isPerformingAction = true
            currentAction = deletingActionText
        } else {
            if currentAction.starts(with: "Deleting") || currentAction.starts(with: "Trashing") || currentAction.starts(with: "Moving") {
                isPerformingAction = false
                currentAction = ""
            }
            if !activeDeletions.isEmpty {
                activeDeletions.removeAll()
            }
        }
    }
    
    // Cancellation support
    @Published var cancellationRequested: Bool = false
    
    /// Request cancellation of the current operation
    func requestCancellation() {
        cancellationRequested = true
        cancelAllDeletions()
    }
    
    /// Reset cancellation flag (called at the start of each new operation)
    private func resetCancellation() {
        cancellationRequested = false
    }
    
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
        let (code, _, error) = await Shell.runAsync(
            ADBManager.getADBPath(),
            args: ADBManager.deviceArgs(["shell", "mkdir -p '\(trashFolderPath)'"])
        )
        if code != 0 {
            throw NSError(
                domain: "FileAction",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: "Could not create trash folder: \(error.isEmpty ? "Unknown error" : error)"]
            )
        }
    }
    
    // MARK: - Delete Operation (Move to Trash)
    
    /// Moves a file or folder to trash (soft delete)
    /// - Parameter file: The file to delete
    /// - Parameter permanent: If true, permanently deletes instead of moving to trash
    func deleteFile(_ file: UnifiedFile, permanent: Bool = false) async throws {
        try await deleteFiles([file], permanent: permanent)
    }

    func deleteFiles(_ files: [UnifiedFile], permanent: Bool = false) async throws {
        guard !files.isEmpty else { return }
        
        let newDeletions = files.map { file in
            LiveDeletion(
                id: UUID(),
                fileName: file.name,
                filePath: file.path,
                isPermanent: permanent
            )
        }
        
        await MainActor.run {
            self.activeDeletions.append(contentsOf: newDeletions)
            self.updatePerformingActionState()
        }
        
        if permanent {
            // Process permanent deletes in batch (chunks of 20) via single rm -rf commands to prevent ADB command flooding
            let pathsToDelete = files.map { $0.path }
            
            // Build a mapping from file path to LiveDeletion ID
            var pathMap: [String: UUID] = [:]
            for deletion in newDeletions {
                pathMap[deletion.filePath] = deletion.id
            }
            
            do {
                try await ADBManager.batchDeleteFiles(
                    devicePaths: pathsToDelete,
                    onChunkCompleted: { completedPaths in
                        Task { @MainActor in
                            for path in completedPaths {
                                if let id = pathMap[path],
                                   let idx = self.activeDeletions.firstIndex(where: { $0.id == id }) {
                                    self.activeDeletions[idx].isComplete = true
                                    self.activeDeletions[idx].isRunning = false
                                }
                            }
                            self.updatePerformingActionState()
                            NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
                        }
                    },
                    cancellationCheck: { [weak self] in
                        self?.cancellationRequested ?? false
                    }
                )
            } catch {
                await MainActor.run {
                    for deletion in newDeletions {
                        if let idx = self.activeDeletions.firstIndex(where: { $0.id == deletion.id && !$0.isComplete }) {
                            if (error as NSError).code == -999 || self.activeDeletions[idx].isCancelled {
                                self.activeDeletions[idx].isCancelled = true
                            } else {
                                self.activeDeletions[idx].error = error.localizedDescription
                            }
                            self.activeDeletions[idx].isComplete = true
                            self.activeDeletions[idx].isRunning = false
                        }
                    }
                    self.updatePerformingActionState()
                    NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
                }
            }
            
            // Trigger a single lightweight post-batch media scan for all deleted files
            Task.detached(priority: .background) {
                await ADBManager.triggerMediaScanForFiles(pathsToDelete)
            }
        } else {
            // Process trash deletions (move to trash) in batch chunks of 20 to prevent ADB command flooding
            do {
                try await ensureTrashFolder()
            } catch {
                await MainActor.run {
                    for deletion in newDeletions {
                        if let idx = self.activeDeletions.firstIndex(where: { $0.id == deletion.id && !$0.isComplete }) {
                            self.activeDeletions[idx].error = error.localizedDescription
                            self.activeDeletions[idx].isComplete = true
                            self.activeDeletions[idx].isRunning = false
                        }
                    }
                    self.updatePerformingActionState()
                    NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
                }
                return
            }
            
            let timestamp = Int(Date().timeIntervalSince1970)
            var movesToMake: [(src: String, dst: String)] = []
            var trashItemsToInsert: [TrashedItem] = []
            var pathMap: [String: UUID] = [:]
            
            for (idx, file) in files.enumerated() {
                let deletion = newDeletions[idx]
                pathMap[file.path] = deletion.id
                
                let trashName = "\(timestamp)_\(UUID().uuidString)_\(file.name)"
                let trashPath = "\(trashFolderPath)/\(trashName)"
                
                movesToMake.append((src: file.path, dst: trashPath))
                
                let item = TrashedItem(
                    originalPath: file.path,
                    trashPath: trashPath,
                    name: file.name,
                    isDirectory: file.isDirectory
                )
                trashItemsToInsert.append(item)
            }
            
            do {
                try await ADBManager.batchMoveFiles(
                    moves: movesToMake,
                    onChunkCompleted: { completedChunk in
                        Task { @MainActor in
                            for move in completedChunk {
                                if let id = pathMap[move.src],
                                   let idx = self.activeDeletions.firstIndex(where: { $0.id == id }) {
                                    self.activeDeletions[idx].isComplete = true
                                    self.activeDeletions[idx].isRunning = false
                                }
                            }
                            self.updatePerformingActionState()
                            NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
                        }
                    },
                    cancellationCheck: { [weak self] in
                        self?.cancellationRequested ?? false
                    }
                )
                
                await MainActor.run {
                    self.trashedItems.insert(contentsOf: trashItemsToInsert, at: 0)
                    self.saveTrashedItems()
                }
            } catch {
                await MainActor.run {
                    for deletion in newDeletions {
                        if let idx = self.activeDeletions.firstIndex(where: { $0.id == deletion.id && !$0.isComplete }) {
                            if (error as NSError).code == -999 || self.activeDeletions[idx].isCancelled {
                                self.activeDeletions[idx].isCancelled = true
                            } else {
                                self.activeDeletions[idx].error = error.localizedDescription
                            }
                            self.activeDeletions[idx].isComplete = true
                            self.activeDeletions[idx].isRunning = false
                        }
                    }
                    self.updatePerformingActionState()
                    NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
                }
            }
            
            // Trigger a single lightweight post-batch media scan for all moved files
            let pathsToScan = files.map { $0.path }
            Task.detached(priority: .background) {
                await ADBManager.triggerMediaScanForFiles(pathsToScan)
            }
        }
    }
    
    private func processDeletion(_ deletion: LiveDeletion) async {
        await MainActor.run {
            if let idx = activeDeletions.firstIndex(where: { $0.id == deletion.id }) {
                if activeDeletions[idx].isCancelled { return }
                activeDeletions[idx].isRunning = true
            }
            updatePerformingActionState()
        }
        
        do {
            let cancelCheck = { [weak self] in
                guard let self = self else { return true }
                return self.activeDeletions.first(where: { $0.id == deletion.id })?.isCancelled ?? false
            }
            
            if cancelCheck() {
                throw NSError(domain: "FileAction", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
            try await performDelete(
                path: deletion.filePath,
                name: deletion.fileName,
                isDirectory: false,
                permanent: deletion.isPermanent,
                cancellationCheck: cancelCheck
            )
            
            await MainActor.run {
                if let idx = activeDeletions.firstIndex(where: { $0.id == deletion.id }) {
                    activeDeletions[idx].isComplete = true
                    activeDeletions[idx].isRunning = false
                }
                updatePerformingActionState()
                NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
            }
        } catch {
            await MainActor.run {
                if let idx = activeDeletions.firstIndex(where: { $0.id == deletion.id }) {
                    if (error as NSError).code == -999 || activeDeletions[idx].isCancelled {
                        activeDeletions[idx].isCancelled = true
                    } else {
                        activeDeletions[idx].error = error.localizedDescription
                    }
                    activeDeletions[idx].isComplete = true
                    activeDeletions[idx].isRunning = false
                }
                updatePerformingActionState()
                NotificationCenter.default.post(name: .afsDeletionsChanged, object: nil)
            }
        }
    }

    private func performDelete(path: String, name: String, isDirectory: Bool, permanent: Bool, cancellationCheck: @escaping () -> Bool) async throws {
        if cancellationCheck() {
            throw NSError(domain: "FileAction", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        if permanent {
            try await ADBManager.deleteFile(devicePath: path, cancellationCheck: cancellationCheck)
            await ADBManager.triggerMediaScan(path: path)
            return
        }

        try await ensureTrashFolder()
        
        if cancellationCheck() {
            throw NSError(domain: "FileAction", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let trashName = "\(timestamp)_\(UUID().uuidString)_\(name)"
        let trashPath = "\(trashFolderPath)/\(trashName)"

        do {
            try await ADBManager.renameFile(oldPath: path, newPath: trashPath)
            await ADBManager.triggerMediaScan(path: path)
            
            let adbPath = ADBManager.getADBPath()
            let escPath = trashPath.replacingOccurrences(of: "'", with: "'\\''")
            let (_, testOut, _) = await Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "[ -d '\(escPath)' ] && echo 1 || echo 0"]))
            let isDir = testOut.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            
            let trashedItem = TrashedItem(
                originalPath: path,
                trashPath: trashPath,
                name: name,
                isDirectory: isDir
            )

            await MainActor.run {
                trashedItems.insert(trashedItem, at: 0)
                saveTrashedItems()
            }
        } catch {
            print("❌ Move to trash failed for '\(name)': \(error.localizedDescription)")
            throw NSError(
                domain: "FileAction",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: "Cannot move '\(name)' to trash: \(error.localizedDescription)"]
            )
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
            // Ensure parent destination directory exists
            let parentDir = (item.originalPath as NSString).deletingLastPathComponent
            try? await ADBManager.createFolder(at: parentDir)
            
            // Move file back to original location
            try await ADBManager.renameFile(oldPath: item.trashPath, newPath: item.originalPath)
            await ADBManager.triggerMediaScan(path: item.originalPath)
            
            // Remove from trashed items
            await MainActor.run {
                trashedItems.removeAll { $0.id == item.id }
                saveTrashedItems()
                isPerformingAction = false
                currentAction = ""
            }
            
        } catch {
            let formattedError = NSError(
                domain: "FileAction",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: "Cannot restore '\(item.name)': \(error.localizedDescription)"]
            )
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = formattedError.localizedDescription
            }
            throw formattedError
        }
    }

    /// Restores all items currently in trash.
    /// Continues on per-item failures and reports a combined error at the end.
    func restoreAllFromTrash() async throws {
        let items = await MainActor.run { trashedItems }
        guard !items.isEmpty else { return }

        await MainActor.run {
            isPerformingAction = true
            currentAction = "Restoring \(items.count) item(s)..."
            lastError = nil
        }

        let moves = items.map { (src: $0.trashPath, dst: $0.originalPath) }
        var failedMessage: String?

        do {
            try await ADBManager.batchMoveFiles(
                moves: moves,
                onChunkCompleted: { completedChunk in
                    let completedSrcs = Set(completedChunk.map { $0.src })
                    Task { @MainActor in
                        let restoredItems = items.filter { completedSrcs.contains($0.trashPath) }
                        let restoredIDs = Set(restoredItems.map { $0.id })
                        self.trashedItems.removeAll { restoredIDs.contains($0.id) }
                        self.saveTrashedItems()
                    }
                }
            )
        } catch {
            failedMessage = error.localizedDescription
        }

        // Trigger a single lightweight post-batch media scan for all restored files
        let restoredPaths = items.map { $0.originalPath }
        Task.detached(priority: .background) {
            await ADBManager.triggerMediaScanForFiles(restoredPaths)
        }

        await MainActor.run {
            isPerformingAction = false
            currentAction = ""
            if let err = failedMessage {
                lastError = "Failed to restore items: \(err)"
            }
        }
    }
    
    /// Permanently deletes an item from trash
    func permanentlyDeleteFromTrash(_ item: TrashedItem) async throws {
        try await permanentlyDeleteFromTrash([item])
    }
    
    /// Permanently deletes multiple items from trash using batched rm -rf commands
    func permanentlyDeleteFromTrash(_ items: [TrashedItem]) async throws {
        guard !items.isEmpty else { return }
        
        await MainActor.run {
            isPerformingAction = true
            currentAction = items.count == 1 ? "Permanently deleting \(items[0].name)..." : "Permanently deleting \(items.count) item(s)..."
        }
        
        let paths = items.map { $0.trashPath }
        let idsToRemove = Set(items.map { $0.id })
        
        do {
            try await ADBManager.batchDeleteFiles(
                devicePaths: paths,
                onChunkCompleted: { completedChunkPaths in
                    let completedSet = Set(completedChunkPaths)
                    Task { @MainActor in
                        let deletedItems = items.filter { completedSet.contains($0.trashPath) }
                        let deletedIDs = Set(deletedItems.map { $0.id })
                        self.trashedItems.removeAll { deletedIDs.contains($0.id) }
                        self.saveTrashedItems()
                    }
                },
                cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
            )
            
            await MainActor.run {
                self.trashedItems.removeAll { idsToRemove.contains($0.id) }
                self.saveTrashedItems()
                self.isPerformingAction = false
                self.currentAction = ""
            }
        } catch {
            await MainActor.run {
                self.isPerformingAction = false
                self.currentAction = ""
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
            let formattedError = NSError(
                domain: "Rename",
                code: (error as NSError).code,
                userInfo: [NSLocalizedDescriptionKey: "Cannot rename '\(file.name)': \(error.localizedDescription)"]
            )
            await MainActor.run {
                isPerformingAction = false
                currentAction = ""
                lastError = formattedError.localizedDescription
            }
            throw formattedError
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
            resetCancellation()
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

        if operation == .cut {
            // ── BATCH MOVE: combine all mv commands into a single ADB shell call ──
            // This avoids N separate ADB round trips over WiFi.
            var moveCommands: [String] = []
            for (file, destFile) in items {
                let escapedSrc = file.path.replacingOccurrences(of: "'", with: "'\\''")
                let escapedDst = destFile.replacingOccurrences(of: "'", with: "'\\''")
                moveCommands.append("mv '\(escapedSrc)' '\(escapedDst)'")
                print("\u{1F4CB} Paste: move '\(file.path)' \u{2192} '\(destFile)'")
            }
            
            let batchCommand = moveCommands.joined(separator: " && ")
            let (code, _, error) = await Shell.runAsyncWithTimeout(
                ADBManager.getADBPath(),
                args: ADBManager.deviceArgs(["shell", batchCommand]),
                timeoutSeconds: 30.0
            )
            
            if code == 0 {
                successCount = items.count
                successPaths = items.map { $0.dest }
            } else {
                // Batch failed — fall back to individual moves to identify which ones failed
                print("⚠️ Batch move failed (code \(code)): \(error) — retrying individually")
                for (file, destFile) in items {
                    do {
                        try await ADBManager.renameFile(oldPath: file.path, newPath: destFile)
                        successPaths.append(destFile)
                        successCount += 1
                    } catch {
                        print("\u{274C} Failed to paste \(file.name): \(error.localizedDescription)")
                        failedItems.append((file.name, error.localizedDescription))
                    }
                }
            }
        } else {
            // ── COPY: run individually (cp -r needs per-item error handling) ──
            for (file, destFile) in items {
                // Check for cancellation
                if await MainActor.run(body: { cancellationRequested }) {
                    await MainActor.run {
                        isPerformingAction = false
                        currentAction = ""
                        lastError = "Cancelled after \(successCount) of \(n) items"
                        if successCount > 0 { clipboard.removeAll(); clipboardOperation = .none }
                    }
                    return
                }
                print("\u{1F4CB} Paste: copy '\(file.path)' \u{2192} '\(destFile)'")
                do {
                    try await ADBManager.copyFile(
                        from: file.path,
                        to: destFile,
                        isDirectory: file.isDirectory,
                        cancellationCheck: { [weak self] in self?.cancellationRequested ?? false }
                    )
                    successPaths.append(destFile)
                    successCount += 1
                } catch {
                    if (error as NSError).code == -999 || (self.cancellationRequested) {
                        print("🛑 Paste loop: cancellation detected, breaking early.")
                        await MainActor.run {
                            isPerformingAction = false
                            currentAction = ""
                            lastError = "Cancelled after \(successCount) of \(n) items"
                            if successCount > 0 { clipboard.removeAll(); clipboardOperation = .none }
                        }
                        return
                    }
                    print("\u{274C} Failed to paste \(file.name): \(error.localizedDescription)")
                    failedItems.append((file.name, error.localizedDescription))
                }
            }
        }

        // Trigger media scan for all pasted files (batch, non-blocking)
        if !successPaths.isEmpty {
            Task.detached(priority: .background) {
                for path in successPaths {
                    await ADBManager.triggerMediaScan(path: path)
                }
            }
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
