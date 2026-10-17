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
    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff"
    ]
    
    /// Extensions we attempt to fetch video thumbnails for
    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "avi", "mkv", "m4v", "webm"
    ]
    
    /// All thumbnailable extensions
    private static let thumbnailableExtensions: Set<String> =
        imageExtensions.union(videoExtensions)
    
    // MARK: - Media Type
    
    private enum MediaType: String {
        case image
        case video
        
        /// Type-specific MediaStore collections, newest volume name first after
        /// the broadly compatible legacy alias.
        var contentUris: [String] {
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

        var querySources: [(queryUri: String, thumbnailUri: String)] {
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
        
        loadingTask = Task {
            // Priority: load first 20 files immediately (visible viewport),
            // then load the rest in the background
            let priorityCount = min(20, uncachedFiles.count)
            let priorityFiles = Array(uncachedFiles.prefix(priorityCount))
            let remainingFiles = Array(uncachedFiles.dropFirst(priorityCount))
            
            await loadThumbnailsBatch(files: priorityFiles, currentPath: currentPath)
            
            if !remainingFiles.isEmpty, !Task.isCancelled {
                await loadThumbnailsBatch(files: remainingFiles, currentPath: currentPath)
            }

            guard !Task.isCancelled, currentLoadingPath == currentPath else { return }
            loadingTask = nil
            currentLoadingPath = nil

            if let pending = pendingRequest, pending.path == currentPath {
                pendingRequest = nil
                requestThumbnails(for: pending.files, currentPath: pending.path)
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
    
    // MARK: - Batch Loading
    
    /// Load thumbnails by querying images and videos separately from MediaStore.
    private func loadThumbnailsBatch(files: [UnifiedFile], currentPath: String) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }
        
        // Split files by media type
        let imageFiles = files.filter { Self.imageExtensions.contains($0.pathExtension) }
        let videoFiles = files.filter { Self.videoExtensions.contains($0.pathExtension) }
        
        // Normalize the directory path for MediaStore
        let physicalDir = FilePreviewManager.resolveToPhysicalPath(currentPath)
        // Fetch image thumbnails
        if !imageFiles.isEmpty, !Task.isCancelled {
            await fetchMediaStoreThumbnails(
                files: imageFiles,
                mediaType: .image,
                physicalDir: physicalDir,
                adbPath: adbPath
            )
        }
        
        // Fetch video thumbnails
        if !videoFiles.isEmpty, !Task.isCancelled {
            await fetchMediaStoreThumbnails(
                files: videoFiles,
                mediaType: .video,
                physicalDir: physicalDir,
                adbPath: adbPath
            )
        }
    }
    
    /// Query MediaStore for a specific media type and fetch thumbnails.
    private func fetchMediaStoreThumbnails(
        files: [UnifiedFile],
        mediaType: MediaType,
        physicalDir: String,
        adbPath: String,
        allowMediaScanRetry: Bool = true
    ) async {
        // Build name → file lookup
        var nameToFile: [String: UnifiedFile] = [:]
        for file in files {
            nameToFile[file.name] = file
            nameToFile[file.name.lowercased()] = file
        }

        let escapedDir = physicalDir.replacingOccurrences(of: "'", with: "'\\''")
        var selections = ["_data LIKE '\(escapedDir)/%' AND _data NOT LIKE '\(escapedDir)/%/%'"]
        if let relativeDir = Self.mediaStoreRelativeDirectory(for: physicalDir) {
            let escapedRelativeDir = relativeDir.replacingOccurrences(of: "'", with: "'\\''")
            selections.append("relative_path='\(escapedRelativeDir)'")
        }
        let escapedNames = files.prefix(100).map {
            "'\($0.name.replacingOccurrences(of: "'", with: "'\\''"))'"
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
                    args: ADBManager.deviceArgs(["shell", queryCmd]),
                    timeoutSeconds: 4
                )

                guard !Task.isCancelled else { return }

                print("🖼️ Thumbnails [\(mediaType.rawValue)] \(source.queryUri): code=\(queryCode), output=\(queryOutput.count), err='\(queryErr.prefix(100))'")

                guard queryCode == 0, !queryOutput.isEmpty else { continue }
                for row in queryOutput.components(separatedBy: "\n") where row.contains("_id=") {
                    guard let mediaId = FilePreviewManager.parseMediaStoreId(from: row),
                          let displayName = Self.parseDisplayName(from: row),
                          let file = nameToFile[displayName] ?? nameToFile[displayName.lowercased()],
                          matchedPaths.insert(file.path).inserted else { continue }
                    entries.append((id: mediaId, file: file, thumbnailUri: source.thumbnailUri))
                }

                if matchedPaths.count == files.count {
                    break queryLoop
                }
            }
        }
        
        guard !Task.isCancelled else { return }
        
        if entries.isEmpty {
            if allowMediaScanRetry {
                print("⚠️ Thumbnails [\(mediaType.rawValue)]: No MediaStore entries; requesting an on-device media scan...")
                await ADBManager.triggerMediaScanForFiles(files.map(\.path))
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await fetchMediaStoreThumbnails(
                    files: files,
                    mediaType: mediaType,
                    physicalDir: physicalDir,
                    adbPath: adbPath,
                    allowMediaScanRetry: false
                )
            } else {
                print("⚠️ Thumbnails [\(mediaType.rawValue)]: MediaStore unavailable after scan; using file icons.")
            }
            return
        }
        
        print("🖼️ Thumbnails [\(mediaType.rawValue)]: Found \(entries.count) entries, fetching thumbnails...")
        
        // Fetch thumbnails concurrently with max concurrency
        await withTaskGroup(of: (String, NSImage?)?.self) { group in
            var activeTasks = 0
            var entryIndex = 0
            
            // Seed initial batch
            while activeTasks < maxConcurrentFetches && entryIndex < entries.count {
                let entry = entries[entryIndex]
                entryIndex += 1
                activeTasks += 1
                
                group.addTask { [weak self] in
                    guard !Task.isCancelled else { return nil }
                    guard let self else { return nil }
                    let thumb = await self.fetchSingleThumbnail(
                        mediaId: entry.id,
                        contentUri: entry.thumbnailUri,
                        adbPath: adbPath
                    )
                    return (entry.file.path, thumb)
                }
            }
            
            // Process results and enqueue more
            for await result in group {
                guard !Task.isCancelled else { break }
                activeTasks -= 1
                
                if let (path, image) = result, let thumb = image {
                    storeThumbnail(thumb, forPath: path)
                }
                
                // Enqueue next
                if entryIndex < entries.count {
                    let entry = entries[entryIndex]
                    entryIndex += 1
                    activeTasks += 1
                    
                    group.addTask { [weak self] in
                        guard !Task.isCancelled else { return nil }
                        guard let self else { return nil }
                        let thumb = await self.fetchSingleThumbnail(
                            mediaId: entry.id,
                            contentUri: entry.thumbnailUri,
                            adbPath: adbPath
                        )
                        return (entry.file.path, thumb)
                    }
                }
            }
        }
    }
    
    // MARK: - Single Thumbnail Fetch
    
    /// Fetch a thumbnail for a specific MediaStore _id using the correct URI for image/video.
    private func fetchSingleThumbnail(
        mediaId: String,
        contentUri: String,
        adbPath: String
    ) async -> NSImage? {
        let thumbnailUri = "\(contentUri)/\(mediaId)/thumbnail"
        
        let readArgs = ADBManager.deviceArgs([
            "exec-out", "content", "read",
            "--uri", thumbnailUri
        ])
        
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
    private static func parseDisplayName(from row: String) -> String? {
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
