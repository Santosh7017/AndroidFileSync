//
//  SidebarManager.swift
//  AndroidFileSync
//
//  Manages sidebar Quick Access items — built-in + user-defined custom items.
//  Custom items and hidden built-ins are persisted to UserDefaults.
//

import Foundation
internal import Combine

class SidebarManager: ObservableObject {

    // MARK: - Published State

    /// Custom items added by the user
    @Published var customItems: [QuickAccessItem] = []

    /// Paths of built-in items the user has hidden
    @Published var hiddenBuiltInPaths: Set<String> = []

    /// Paths confirmed to exist on the connected device
    @Published var existingPaths: Set<String> = []

    /// Paths that have been checked at least once (so we can distinguish "unchecked" from "missing")
    @Published var checkedPaths: Set<String> = []

    /// Dynamically injected SD card item (nil when no card detected)
    @Published var sdCardItem: QuickAccessItem? = nil
    @Published private(set) var internalStoragePath = "/storage/emulated/0"

    // MARK: - Computed

    /// All currently visible sidebar items (built-in - hidden + SD card if present + custom)
    var visibleItems: [QuickAccessItem] {
        var builtIn = QuickAccessItem.commonFolders.filter { !hiddenBuiltInPaths.contains($0.path) }.map { item in
            QuickAccessItem(name: item.name, icon: item.icon,
                path: internalStoragePath + item.path.dropFirst("/storage/emulated/0".count),
                color: item.color, isBuiltIn: true)
        }
        // Insert SD card right after Internal Storage if detected
        if let sd = sdCardItem {
            let insertIndex = builtIn.firstIndex(where: { $0.name == "Internal Storage" }).map { $0 + 1 } ?? 1
            builtIn.insert(sd, at: min(insertIndex, builtIn.count))
        }
        return builtIn + customItems
    }

    /// True when at least one built-in item is hidden (so user can restore)
    var hasHiddenBuiltIns: Bool { !hiddenBuiltInPaths.isEmpty }

    // MARK: - Init

    init() { load() }

    // MARK: - Existence Checking

    /// Checks which sidebar paths actually exist on the connected device via ADB.
    /// Updates `existingPaths` and `checkedPaths` on the main actor.
    func checkExistence() async {
        let paths = visibleItems.map(\.path)
        let storageSnapshot = internalStoragePath
        guard !paths.isEmpty, let serial = ADBManager.activeDeviceSerial else { return }

        // Build a single compound ADB shell command to check all paths at once:
        // For each path: "[ -d '/path' ] && echo 1 || echo 0"
        // We run them in sequence separated by ; so we get one line of output per path.
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }

        var newExisting: Set<String> = []
        var newChecked: Set<String> = []

        // Check in parallel with a task group
        await withTaskGroup(of: (String, Bool).self) { group in
            for path in paths {
                group.addTask {
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    let (_, output, _) = await Shell.runAsync(
                        adbPath,
                        args: ["-s", serial, "shell", "[ -d '\(escaped)' ] && echo 1 || echo 0"]
                    )
                    let exists = output.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
                    return (path, exists)
                }
            }

            for await (path, exists) in group {
                newChecked.insert(path)
                if exists { newExisting.insert(path) }
            }
        }

        await MainActor.run {
            guard ADBManager.activeDeviceSerial == serial, self.internalStoragePath == storageSnapshot else { return }
            // Keep the storage entry navigable even when Android denies access.
            newExisting.insert(storageSnapshot)
            self.existingPaths = newExisting
            self.checkedPaths = newChecked
        }
    }

    // MARK: - SD Card

    /// Call this whenever DeviceManager.sdCardPath changes.
    /// Pass nil to remove the SD card entry (device disconnected or no card).
    func updateSDCard(path: String?) {
        guard let path else {
            if let oldPath = sdCardItem?.path {
                existingPaths.remove(oldPath)
                checkedPaths.remove(oldPath)
            }
            sdCardItem = nil
            return
        }
        sdCardItem = QuickAccessItem(
            name: "SD Card",
            icon: "sdcard.fill",
            path: path,
            color: "orange",
            isBuiltIn: false
        )
        // Mark it as existing immediately since DeviceManager already confirmed it
        existingPaths.insert(path)
        checkedPaths.insert(path)
    }

    // MARK: - Mutations

    func updateInternalStorage(path: String) {
        internalStoragePath = path
        existingPaths.removeAll()
        checkedPaths.removeAll()
        Task { await checkExistence() }
    }

    /// Add the given Android path as a custom sidebar item.
    /// Silently ignores duplicates. Then re-checks existence.
    func addItem(name: String, path: String, icon: String = "folder.fill", color: String = "blue") {
        guard !visibleItems.contains(where: { $0.path == path }) else { return }
        let item = QuickAccessItem(name: name, icon: icon, path: path, color: color, isBuiltIn: false)
        customItems.append(item)
        save()
        // Immediately check existence of the newly added item
        Task { await checkExistence() }
    }

    /// Remove a sidebar item. Built-ins are hidden (restorable); custom items are deleted.
    func removeItem(_ item: QuickAccessItem) {
        if item.isBuiltIn {
            hiddenBuiltInPaths.insert("/storage/emulated/0" + item.path.dropFirst(internalStoragePath.count))
        } else {
            customItems.removeAll { $0.id == item.id }
            existingPaths.remove(item.path)
            checkedPaths.remove(item.path)
        }
        save()
    }

    /// Restore all hidden built-in items
    func restoreBuiltIns() {
        hiddenBuiltInPaths.removeAll()
        save()
        Task { await checkExistence() }
    }

    // MARK: - Persistence

    private let customKey  = "sidebar_customItems_v2"
    private let hiddenKey  = "sidebar_hiddenPaths_v2"

    private func save() {
        if let data = try? JSONEncoder().encode(customItems) {
            UserDefaults.standard.set(data, forKey: customKey)
        }
        UserDefaults.standard.set(Array(hiddenBuiltInPaths), forKey: hiddenKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: customKey),
           let items = try? JSONDecoder().decode([QuickAccessItem].self, from: data) {
            customItems = items
        }
        let hidden = UserDefaults.standard.stringArray(forKey: hiddenKey) ?? []
        hiddenBuiltInPaths = Set(hidden)
    }
}
