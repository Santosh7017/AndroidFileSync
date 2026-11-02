//
//  ThumbnailProvider.swift
//  AndroidFileSync
//
//  Loads file thumbnails in bulk from Android's MediaStore for the file list view.
//  Uses batch queries and concurrent fetches with LRU eviction.
//

import Foundation
import AppKit
internal import Combine

/// Provides thumbnail images for files displayed in the file browser.
/// Fetches thumbnails from Android MediaStore in batches, with concurrency
/// control and LRU caching.
@MainActor
class ThumbnailProvider: ObservableObject {
    
    // MARK: - Published State
    
    /// Thumbnails keyed by device file path. SwiftUI observes changes.
    @Published var thumbnails: [String: NSImage] = [:]
    
    // MARK: - Private State
    
    /// Maximum number of thumbnails to keep in cache
    private let maxCacheSize = 200
    
    /// Maximum concurrent ADB thumbnail fetch operations
    private let maxConcurrentFetches = 6
    
    /// Track order for LRU eviction
    private var accessOrder: [String] = []
    
    /// Active loading task — cancelled when navigating away
    private var loadingTask: Task<Void, Never>?
    
    /// The directory currently being loaded — prevents duplicate loads
    private var currentLoadingPath: String?

    /// Latest request received while the current directory is still loading.
    /// Progressive directory updates can otherwise leave later files without thumbnails.
    private var pendingRequest: (files: [UnifiedFile], path: String)?
    
    /// Extensions we attempt to fetch image thumbnails for
    private nonisolated(unsafe) static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff"
    ]
    
    /// Extensions we attempt to fetch video thumbnails for
    private nonisolated(unsafe) static let videoExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "m4v", "webm"
    ]
    
    /// All thumbnailable extensions
    private nonisolated(unsafe) static let thumbnailableExtensions: Set<String> =
        imageExtensions.union(videoExtensions)
    
    // MARK: - Media Type
    
    private enum MediaType: String {
        case image
        case video
        
        /// Type-specific MediaStore collections, newest volume name first after
        /// the broadly compatible legacy alias.
        nonisolated var contentUris: [String] {
            switch self {
            case .image:
                return [
                    "content://media/external/images/media",
                    "content://media/external_primary/images/media"
                ]
            case .video:
                return [
                    "content://media/external/video/media",
                    "content://media/external_primary/video/media"
                ]
            }
        }

        nonisolated var querySources: [(queryUri: String, thumbnailUri: String)] {
            [
                (contentUris[0], contentUris[0]),
                (contentUris[1], contentUris[1]),
                ("content://media/external/file", contentUris[0]),
                ("content://media/external_primary/file", contentUris[1])
            ]
        }
    }
    
    // MARK: - Public API
    
    /// Request thumbnails for a list of files in a directory.
    /// Cancels any in-flight loading from a previous directory.
    func requestThumbnails(for files: [UnifiedFile], currentPath: String) {
        if currentLoadingPath == currentPath, loadingTask != nil {
            pendingRequest = (files, currentPath)
            return
        }
        
        // Cancel previous loading
        cancelLoading()
        currentLoadingPath = currentPath
        
        // Filter to only thumbnailable media files
        let mediaFiles = files.filter { file in
            !file.isDirectory && Self.thumbnailableExtensions.contains(file.pathExtension)
        }
        
        guard !mediaFiles.isEmpty else { return }
        
        // Remove files that are already cached
        let uncachedFiles = mediaFiles.filter { thumbnails[$0.path] == nil }
        guard !uncachedFiles.isEmpty else { return }
        
        // Mark cached entries as recently accessed
        for file in mediaFiles where thumbnails[file.path] != nil {
            touchLRU(file.path)
        }
        
        // Capture everything we need before going off-main
        let priorityCount = min(20, uncachedFiles.count)
        let priorityFiles = Array(uncachedFiles.prefix(priorityCount))
        let remainingFiles = Array(uncachedFiles.dropFirst(priorityCount))
        let adbPath = ADBManager.getADBPath()
        let physicalDir = FilePreviewManager.resolveToPhysicalPath(currentPath)
        let maxConcurrent = maxConcurrentFetches
        // Snapshot device args prefix once on main actor so the detached task doesn't need to hop back
        let deviceArgsPrefix = ADBManager.activeDeviceSerial.map {
            ["-P", String(Shell.serverPortBySerial[$0] ?? (Shell.useDefaultServer ? 5037 : Shell.appADBServerPort)), "-s", $0]
        } ?? [String]()
        
        guard !adbPath.isEmpty else { return }

        // Use Task.detached so the ENTIRE fetch pipeline runs off the main thread.
        // The parent Task wrapper handles cancellation propagation + main-actor bookkeeping.
        loadingTask = Task {
            // Priority batch — run completely off main thread
            let priorityResults = await Task.detached {
                await Self.loadBatchOffMain(
                    files: priorityFiles,
                    physicalDir: physicalDir,
                    adbPath: adbPath,
                    maxConcurrent: maxConcurrent,
                    deviceArgsPrefix: deviceArgsPrefix
                )
            }.value

            guard !Task.isCancelled else { return }
            self.batchStoreThumbnails(priorityResults)

            // Remaining batch
            if !remainingFiles.isEmpty, !Task.isCancelled {
                let remainingResults = await Task.detached {
                    await Self.loadBatchOffMain(
                        files: remainingFiles,
                        physicalDir: physicalDir,
                        adbPath: adbPath,
                        maxConcurrent: maxConcurrent,
                        deviceArgsPrefix: deviceArgsPrefix
                    )
                }.value

                guard !Task.isCancelled else { return }
                self.batchStoreThumbnails(remainingResults)
            }

            guard !Task.isCancelled, self.currentLoadingPath == currentPath else { return }
            self.loadingTask = nil
            self.currentLoadingPath = nil

            if let pending = self.pendingRequest, pending.path == currentPath {
                self.pendingRequest = nil
                self.requestThumbnails(for: pending.files, currentPath: pending.path)
            }
        }
    }
    
    /// Cancel all in-flight thumbnail loading
    func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        currentLoadingPath = nil
        pendingRequest = nil
    }
    
    /// Clear the entire cache (e.g. on device disconnect)
    func clearCache() {
        thumbnails.removeAll()
        accessOrder.removeAll()
    }
    
    // MARK: - Batch Loading (runs entirely off the main thread)
    
    /// Load thumbnails for a batch of files completely off the main thread.
    /// Returns results for the caller to store on MainActor.
    private nonisolated static func loadBatchOffMain(
        files: [UnifiedFile],
        physicalDir: String,
        adbPath: String,
        maxConcurrent: Int,
        deviceArgsPrefix: [String]
    ) async -> [(String, NSImage)] {
        // Split files by media type
        let imageFiles = files.filter { imageExtensions.contains($0.pathExtension) }
        let videoFiles = files.filter { videoExtensions.contains($0.pathExtension) }
        
        var allResults: [(String, NSImage)] = []

        // Fetch image thumbnails
        if !imageFiles.isEmpty, !Task.isCancelled {
            let results = await fetchThumbnailsFromDevice(
                files: imageFiles,
                mediaType: .image,
                physicalDir: physicalDir,
                adbPath: adbPath,
                maxConcurrent: maxConcurrent,
                deviceArgsPrefix: deviceArgsPrefix
            )
            allResults.append(contentsOf: results)
        }
        
        // Fetch video thumbnails
        if !videoFiles.isEmpty, !Task.isCancelled {
            let results = await fetchThumbnailsFromDevice(
                files: videoFiles,
                mediaType: .video,
                physicalDir: physicalDir,
                adbPath: adbPath,
                maxConcurrent: maxConcurrent,
                deviceArgsPrefix: deviceArgsPrefix
            )
            allResults.append(contentsOf: results)
        }
        
        return allResults
    }

    /// Batch-store all thumbnails in a single update to minimize SwiftUI re-renders.
    private func batchStoreThumbnails(_ results: [(String, NSImage)]) {
        guard !results.isEmpty else { return }
        for (path, image) in results {
            thumbnails[path] = image
            touchLRU(path)
        }
        // Evict oldest entries if over limit
        while accessOrder.count > maxCacheSize {
            let oldest = accessOrder.removeFirst()
            thumbnails.removeValue(forKey: oldest)
        }
    }

    /// Query MediaStore and fetch thumbnails entirely off the main thread.
    /// Returns an array of (filePath, thumbnail) pairs for the caller to store on MainActor.
    private nonisolated static func fetchThumbnailsFromDevice(
        files: [UnifiedFile],
        mediaType: MediaType,
        physicalDir: String,
        adbPath: String,
        maxConcurrent: Int,
        deviceArgsPrefix: [String],
        allowMediaScanRetry: Bool = true
    ) async -> [(String, NSImage)] {
        // Build name → file lookup
        var nameToFile: [String: UnifiedFile] = [:]
        for file in files {
            nameToFile[file.name] = file
            nameToFile[file.name.lowercased()] = file
        }

        let escapedDir = physicalDir.replacingOccurrences(of: "'", with: "'\\''"  )
        var selections = ["_data LIKE '\(escapedDir)/%' AND _data NOT LIKE '\(escapedDir)/%/%'"]
        if let relativeDir = mediaStoreRelativeDirectory(for: physicalDir) {
            let escapedRelativeDir = relativeDir.replacingOccurrences(of: "'", with: "'\\''"  )
            selections.append("relative_path='\(escapedRelativeDir)'")
        }
        let escapedNames = files.prefix(100).map {
            "'\($0.name.replacingOccurrences(of: "'", with: "'\\''"  ))'"
        }
        if !escapedNames.isEmpty {
            selections.append("_display_name IN (\(escapedNames.joined(separator: ",")))")
        }
        
        // Parse the batch response into (id, file) pairs
        var entries: [(id: String, file: UnifiedFile, thumbnailUri: String)] = []
        var matchedPaths = Set<String>()

        queryLoop: for source in mediaType.querySources {
            for selection in selections {
                let queryCmd = "content query --uri \"\(source.queryUri)\" --projection _id:_display_name --where \"\(selection)\""
                let (queryCode, queryOutput, queryErr) = await Shell.runAsyncWithTimeout(
                    adbPath,
                    args: deviceArgsPrefix + ["shell", queryCmd],
                    timeoutSeconds: 4
                )

                guard !Task.isCancelled else { return [] }

                print("🖼️ Thumbnails [\(mediaType.rawValue)] \(source.queryUri): code=\(queryCode), output=\(queryOutput.count), err='\(queryErr.prefix(100))'")

                guard queryCode == 0, !queryOutput.isEmpty else { continue }
                for row in queryOutput.components(separatedBy: "\n") where row.contains("_id=") {
                    guard let mediaId = FilePreviewManager.parseMediaStoreId(from: row),
                          let displayName = parseDisplayName(from: row),
                          let file = nameToFile[displayName] ?? nameToFile[displayName.lowercased()],
                          matchedPaths.insert(file.path).inserted else { continue }
                    entries.append((id: mediaId, file: file, thumbnailUri: source.thumbnailUri))
                }

                if matchedPaths.count == files.count {
                    break queryLoop
                }
            }
        }
        
        guard !Task.isCancelled else { return [] }
        
        if entries.isEmpty {
            if allowMediaScanRetry {
                print("⚠️ Thumbnails [\(mediaType.rawValue)]: No MediaStore entries; requesting an on-device media scan...")
                // Trigger media scan directly via ADB to avoid hopping to MainActor
                let scanPaths = files.map(\.path).joined(separator: " ")
                let scanCmd = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d file://\(scanPaths.components(separatedBy: " ").first ?? "")"
                _ = await Shell.runAsync(adbPath, args: deviceArgsPrefix + ["shell", scanCmd])
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return [] }
                return await fetchThumbnailsFromDevice(
                    files: files,
                    mediaType: mediaType,
                    physicalDir: physicalDir,
                    adbPath: adbPath,
                    maxConcurrent: maxConcurrent,
                    deviceArgsPrefix: deviceArgsPrefix,
                    allowMediaScanRetry: false
                )
            } else {
                print("⚠️ Thumbnails [\(mediaType.rawValue)]: MediaStore unavailable after scan; using file icons.")
            }
            return []
        }
        
        print("🖼️ Thumbnails [\(mediaType.rawValue)]: Found \(entries.count) entries, fetching thumbnails...")
        
        // Fetch thumbnails concurrently — runs off the main thread since this is a static method
        var results: [(String, NSImage)] = []
        
        await withTaskGroup(of: (String, NSImage?)?.self) { group in
            var activeTasks = 0
            var entryIndex = 0
            
            // Seed initial batch
            while activeTasks < maxConcurrent && entryIndex < entries.count {
                let entry = entries[entryIndex]
                entryIndex += 1
                activeTasks += 1
                
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    let thumb = await Self.fetchSingleThumbnail(
                        mediaId: entry.id,
                        contentUri: entry.thumbnailUri,
                        adbPath: adbPath,
                        deviceArgsPrefix: deviceArgsPrefix
                    )
                    return (entry.file.path, thumb)
                }
            }
            
            // Process results and enqueue more
            for await result in group {
                guard !Task.isCancelled else { break }
                activeTasks -= 1
                
                if let (path, image) = result, let thumb = image {
                    results.append((path, thumb))
                }
                
                // Enqueue next
                if entryIndex < entries.count {
                    let entry = entries[entryIndex]
                    entryIndex += 1
                    activeTasks += 1
                    
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        let thumb = await Self.fetchSingleThumbnail(
                            mediaId: entry.id,
                            contentUri: entry.thumbnailUri,
                            adbPath: adbPath,
                            deviceArgsPrefix: deviceArgsPrefix
                        )
                        return (entry.file.path, thumb)
                    }
                }
            }
        }
        
        return results
    }
    
    // MARK: - Single Thumbnail Fetch
    
    /// Fetch a thumbnail for a specific MediaStore _id.
    /// nonisolated static so it runs off the main thread (not bound to @MainActor).
    private nonisolated static func fetchSingleThumbnail(
        mediaId: String,
        contentUri: String,
        adbPath: String,
        deviceArgsPrefix: [String]
    ) async -> NSImage? {
        let thumbnailUri = "\(contentUri)/\(mediaId)/thumbnail"
        
        let readArgs = deviceArgsPrefix + [
            "exec-out", "content", "read",
            "--uri", thumbnailUri
        ]
        
        let (_, data, _) = await Shell.runAndCaptureData(
            adbPath,
            args: readArgs,
            maxBytes: 256 * 1024, // Thumbnails are small (~10-50KB)
            cancellationCheck: { Task.isCancelled }
        )
        
        if !data.isEmpty, let image = NSImage(data: data) {
            return image
        }
        
        // Log failure for debugging (only first few)
        if data.isEmpty {
            print("⚠️ Thumbnails: content read returned empty for \(thumbnailUri)")
        }
        
        return nil
    }
    
    // MARK: - Cache Management
    
    /// Store a thumbnail and manage LRU eviction
    private func storeThumbnail(_ image: NSImage, forPath path: String) {
        thumbnails[path] = image
        touchLRU(path)
        
        // Evict oldest entries if over limit
        while accessOrder.count > maxCacheSize {
            let oldest = accessOrder.removeFirst()
            thumbnails.removeValue(forKey: oldest)
        }
    }
    
    /// Move a path to the end of the LRU list (most recently used)
    private func touchLRU(_ path: String) {
        accessOrder.removeAll { $0 == path }
        accessOrder.append(path)
    }
    
    // MARK: - Parsing

    private nonisolated static func mediaStoreRelativeDirectory(for physicalDirectory: String) -> String? {
        let prefixes = [
            "/storage/emulated/0/",
            "/storage/self/primary/",
            "/mnt/user/0/primary/"
        ]
        guard let prefix = prefixes.first(where: { physicalDirectory.hasPrefix($0) }) else {
            return nil
        }
        let relative = String(physicalDirectory.dropFirst(prefix.count))
        return relative.isEmpty ? nil : relative + (relative.hasSuffix("/") ? "" : "/")
    }

    /// Parse `_display_name` from a content query row.
    /// Handles formats like:
    ///   "Row: 0 _id=12345, _display_name=IMG_20260801.jpg"
    ///   "Row: 0 _display_name=IMG_20260801.jpg, _id=12345"
    /// Also handles names with spaces by reading until the next comma-space or end of line.
    private nonisolated static func parseDisplayName(from row: String) -> String? {
        guard let startRange = row.range(of: "_display_name=") else { return nil }
        let afterKey = row[startRange.upperBound...]
        
        // Find the end: either ", " (next column) or end of string
        let endIndex: String.Index
        if let commaRange = afterKey.range(of: ", ") {
            endIndex = commaRange.lowerBound
        } else {
            endIndex = afterKey.endIndex
        }
        
        let value = String(afterKey[afterKey.startIndex..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
