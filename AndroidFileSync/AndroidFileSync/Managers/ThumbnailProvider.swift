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
        
        /// The content:// URI prefix for this media type
        var contentUri: String {
            switch self {
            case .image: return "content://media/external/images/media"
            case .video: return "content://media/external/video/media"
            }
        }
    }
    
    // MARK: - Public API
    
    /// Request thumbnails for a list of files in a directory.
    /// Cancels any in-flight loading from a previous directory.
    func requestThumbnails(for files: [UnifiedFile], currentPath: String) {
        // Skip if already loading this exact directory
        if currentLoadingPath == currentPath { return }
        
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
        }
    }
    
    /// Cancel all in-flight thumbnail loading
    func cancelLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        currentLoadingPath = nil
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
        let escapedDir = physicalDir.replacingOccurrences(of: "'", with: "'\\''")
        
        // Fetch image thumbnails
        if !imageFiles.isEmpty, !Task.isCancelled {
            await fetchMediaStoreThumbnails(
                files: imageFiles,
                mediaType: .image,
                escapedDir: escapedDir,
                adbPath: adbPath
            )
        }
        
        // Fetch video thumbnails
        if !videoFiles.isEmpty, !Task.isCancelled {
            await fetchMediaStoreThumbnails(
                files: videoFiles,
                mediaType: .video,
                escapedDir: escapedDir,
                adbPath: adbPath
            )
        }
    }
    
    /// Query MediaStore for a specific media type and fetch thumbnails.
    private func fetchMediaStoreThumbnails(
        files: [UnifiedFile],
        mediaType: MediaType,
        escapedDir: String,
        adbPath: String
    ) async {
        // Build name → file lookup
        var nameToFile: [String: UnifiedFile] = [:]
        for file in files { nameToFile[file.name] = file }
        
        // Batch query: get all _id + _display_name for this media type in directory
        let queryCmd = "content query --uri \"\(mediaType.contentUri)\" --projection _id:_display_name --where \"_data LIKE '\(escapedDir)/%' AND _data NOT LIKE '\(escapedDir)/%/%'\""
        
        let (queryCode, queryOutput, queryErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: ADBManager.deviceArgs(["shell", queryCmd]), timeoutSeconds: 10
        )
        
        guard !Task.isCancelled else { return }
        
        print("🖼️ Thumbnails [\(mediaType.rawValue)]: query code=\(queryCode), output length=\(queryOutput.count), err='\(queryErr.prefix(100))'")
        
        // Parse the batch response into (id, file) pairs
        var entries: [(id: String, file: UnifiedFile)] = []
        
        if queryCode == 0, !queryOutput.isEmpty {
            let rows = queryOutput.components(separatedBy: "\n")
            for row in rows where row.contains("_id=") {
                guard let mediaId = FilePreviewManager.parseMediaStoreId(from: row),
                      let displayName = Self.parseDisplayName(from: row),
                      let file = nameToFile[displayName] else { continue }
                entries.append((id: mediaId, file: file))
            }
        }
        
        guard !Task.isCancelled else { return }
        
        if entries.isEmpty {
            print("⚠️ Thumbnails [\(mediaType.rawValue)]: No MediaStore entries found, trying individual queries...")
            await loadThumbnailsIndividually(files: files, mediaType: mediaType, adbPath: adbPath)
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
                    let thumb = await self?.fetchSingleThumbnail(
                        mediaId: entry.id, mediaType: mediaType, adbPath: adbPath
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
                        let thumb = await self?.fetchSingleThumbnail(
                            mediaId: entry.id, mediaType: mediaType, adbPath: adbPath
                        )
                        return (entry.file.path, thumb)
                    }
                }
            }
        }
    }
    
    /// Fallback: load thumbnails one by one when batch query fails
    private func loadThumbnailsIndividually(
        files: [UnifiedFile],
        mediaType: MediaType,
        adbPath: String
    ) async {
        await withTaskGroup(of: (String, NSImage?)?.self) { group in
            var activeTasks = 0
            var fileIndex = 0
            
            while activeTasks < maxConcurrentFetches && fileIndex < files.count {
                let file = files[fileIndex]
                fileIndex += 1
                activeTasks += 1
                
                group.addTask { [weak self] in
                    guard !Task.isCancelled else { return nil }
                    let thumb = await self?.fetchThumbnailByName(
                        fileName: file.name, mediaType: mediaType, adbPath: adbPath
                    )
                    return (file.path, thumb)
                }
            }
            
            for await result in group {
                guard !Task.isCancelled else { break }
                activeTasks -= 1
                
                if let (path, image) = result, let thumb = image {
                    storeThumbnail(thumb, forPath: path)
                }
                
                if fileIndex < files.count {
                    let file = files[fileIndex]
                    fileIndex += 1
                    activeTasks += 1
                    
                    group.addTask { [weak self] in
                        guard !Task.isCancelled else { return nil }
                        let thumb = await self?.fetchThumbnailByName(
                            fileName: file.name, mediaType: mediaType, adbPath: adbPath
                        )
                        return (file.path, thumb)
                    }
                }
            }
        }
    }
    
    // MARK: - Single Thumbnail Fetch
    
    /// Fetch a thumbnail for a specific MediaStore _id using the correct URI for image/video.
    private func fetchSingleThumbnail(
        mediaId: String,
        mediaType: MediaType,
        adbPath: String
    ) async -> NSImage? {
        // Use the type-specific URI: content://media/external/images/media/<id>/thumbnail
        //                         or: content://media/external/video/media/<id>/thumbnail
        let thumbnailUri = "\(mediaType.contentUri)/\(mediaId)/thumbnail"
        
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
            print("⚠️ Thumbnails: content read returned empty for \(mediaType.rawValue) id=\(mediaId)")
        }
        
        return nil
    }
    
    /// Fetch thumbnail by querying MediaStore with display_name
    private func fetchThumbnailByName(
        fileName: String,
        mediaType: MediaType,
        adbPath: String
    ) async -> NSImage? {
        let escapedName = fileName.replacingOccurrences(of: "'", with: "'\\''")
        let queryCmd = "content query --uri \"\(mediaType.contentUri)\" --projection _id --where \"_display_name='\(escapedName)'\""
        
        let (_, output, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: ADBManager.deviceArgs(["shell", queryCmd]), timeoutSeconds: 5
        )
        
        guard let mediaId = FilePreviewManager.parseMediaStoreId(from: output) else { return nil }
        return await fetchSingleThumbnail(mediaId: mediaId, mediaType: mediaType, adbPath: adbPath)
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
