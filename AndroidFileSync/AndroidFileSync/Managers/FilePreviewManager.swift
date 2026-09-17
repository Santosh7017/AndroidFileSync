//
//  FilePreviewManager.swift
//  AndroidFileSync
//
//  Tiered preview: instant thumbnails for videos/images, full pull for documents.
//  Shows in-app QuickLook-style panel instead of always opening external apps.
//

import Foundation
import AppKit
import AVFoundation
internal import Combine

// MARK: - Preview Content Types

enum PreviewContent: Equatable {
    case image(NSImage)
    case videoThumbnail(NSImage)
    case audioIcon
    case documentIcon(String) // extension
    case loading
    case error(String)
    
    static func == (lhs: PreviewContent, rhs: PreviewContent) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.audioIcon, .audioIcon):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        case (.documentIcon(let a), .documentIcon(let b)):
            return a == b
        case (.image(let a), .image(let b)):
            return a === b
        case (.videoThumbnail(let a), .videoThumbnail(let b)):
            return a === b
        default:
            return false
        }
    }
}

// MARK: - File Category

enum PreviewFileCategory: String {
    case image, video, audio, document, unknown
    
    init(extension ext: String) {
        switch ext.lowercased() {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg", "ico":
            self = .image
        case "mp4", "mov", "avi", "mkv", "m4v", "webm":
            self = .video
        case "mp3", "m4a", "wav", "flac", "aac", "ogg":
            self = .audio
        case "pdf", "txt", "rtf", "html", "htm", "md", "json", "xml", "csv",
             "doc", "docx", "xls", "xlsx", "ppt", "pptx",
             "swift", "java", "py", "js", "ts", "c", "cpp", "h", "css":
            self = .document
        default:
            self = .unknown
        }
    }
    
    /// SF Symbol name for this category
    var symbolName: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .document: return "doc.text"
        case .unknown: return "doc"
        }
    }
    
    /// Display label (uppercase)
    var label: String { rawValue.uppercased() }
}

// MARK: - Preview Manager

/// Manages file preview with a tiered strategy:
/// - Images: piped directly via `adb exec-out cat` → `NSImage`
/// - Videos: partial pull (first 4 MB) → `AVAssetImageGenerator` thumbnail
/// - Audio/Documents: show icon + metadata instantly (no pull needed)
///
/// All UI state is `@MainActor`-isolated to ensure thread-safe `@Published` updates.
@MainActor
class FilePreviewManager: ObservableObject {
    // MARK: - Published State
    
    @Published var showPreviewPanel = false
    @Published var previewContent: PreviewContent = .loading
    @Published private(set) var previewFile: UnifiedFile?
    @Published private(set) var isLoadingFullFile = false
    @Published private(set) var fullFilePullProgress: String = ""
    @Published private(set) var isLoading = false
    @Published private(set) var loadingFileName = ""
    
    /// Signals to Shell that the current operation should be killed.
    /// `nonisolated` because `Shell.runWithProgressCancellable` reads it from a background thread.
    nonisolated(unsafe) var cancellationRequested = false
    
    // MARK: - Private State
    
    private var currentTask: Task<Void, Never>?
    private var fullPullTask: Task<Void, Never>?
    
    /// Cache of already-pulled full files: devicePath → localTempURL
    private var fileCache: [String: URL] = [:]
    
    /// Cache of preview thumbnails: devicePath → NSImage
    private var thumbnailCache: [String: NSImage] = [:]
    
    /// Temp directory for pulled preview files
    private nonisolated let tempDir: URL = {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidFileSync_Preview")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    
    // MARK: - Size Thresholds
    
    /// Images below this size are pulled fully (fast enough over USB)
    private let smallImageThreshold: UInt64 = 8 * 1024 * 1024 // 8 MB
    
    /// Bytes to pull for video thumbnail extraction
    private let videoPartialPullBytes = 4 * 1024 * 1024 // 4 MB
    
    // MARK: - Previewable Extensions (static, computed once)
    
    private static let previewableExtensions: Set<String> = [
        // Images
        "jpg", "jpeg", "png", "gif", "heic", "webp", "bmp", "tiff", "svg", "ico",
        // Videos
        "mp4", "mov", "avi", "mkv", "m4v", "webm",
        // Audio
        "mp3", "m4a", "wav", "flac", "aac", "ogg",
        // Documents
        "pdf", "txt", "rtf", "html", "htm", "md", "json", "xml", "csv",
        // Office
        "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        // Code
        "swift", "java", "py", "js", "ts", "c", "cpp", "h", "css"
    ]
    
    // MARK: - Public API
    
    /// Preview a file using the tiered strategy.
    /// Both Space bar and double-click route here → shows in-app panel.
    func previewFile(_ file: UnifiedFile) {
        guard !file.isDirectory else { return }
        
        // Toggle off if already showing this file
        if showPreviewPanel, previewFile?.path == file.path {
            dismissPreview()
            return
        }
        
        let category = PreviewFileCategory(extension: file.pathExtension)
        
        // Check thumbnail cache for instant display
        if let cachedThumb = thumbnailCache[file.path] {
            previewFile = file
            previewContent = category == .video ? .videoThumbnail(cachedThumb) : .image(cachedThumb)
            showPreviewPanel = true
            return
        }
        
        // Cancel any active task
        currentTask?.cancel()
        cancellationRequested = false
        
        // Show panel immediately with loading state
        previewFile = file
        previewContent = .loading
        showPreviewPanel = true
        isLoading = true
        loadingFileName = file.name
        
        // Route to the appropriate loader
        currentTask = Task {
            switch category {
            case .image:
                await loadImagePreview(file)
            case .video:
                await generateVideoThumbnail(file)
            case .audio:
                previewContent = .audioIcon
                isLoading = false
            case .document, .unknown:
                previewContent = .documentIcon(file.pathExtension)
                isLoading = false
            }
        }
    }
    
    /// Dismiss the preview panel
    func dismissPreview() {
        showPreviewPanel = false
        isLoading = false
        loadingFileName = ""
        currentTask?.cancel()
        currentTask = nil
    }
    
    /// Cancel all preview operations and close the panel
    func cancelPreview() {
        cancellationRequested = true
        dismissPreview()
        isLoadingFullFile = false
        fullPullTask?.cancel()
        fullPullTask = nil
    }
    
    /// Open the currently previewed file in an external app.
    /// Pulls the full file if not already cached, then opens with NSWorkspace.
    func openInExternalApp() {
        guard let file = previewFile else { return }
        
        // Check file cache — if already pulled, open immediately
        if let cached = fileCache[file.path], FileManager.default.fileExists(atPath: cached.path) {
            NSWorkspace.shared.open(cached)
            return
        }
        
        // Pull the full file in background
        isLoadingFullFile = true
        fullFilePullProgress = "Downloading..."
        
        fullPullTask = Task {
            let localURL = tempDir.appendingPathComponent(file.name)
            try? FileManager.default.removeItem(at: localURL)
            
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else {
                isLoadingFullFile = false
                return
            }
            
            let (code, _, error, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: ADBManager.deviceArgs(["pull", file.path, localURL.path]),
                progressCallback: { [weak self] text in
                    self?.parseAndUpdateProgress(text)
                },
                cancellationCheck: { [weak self] in
                    self?.cancellationRequested ?? false
                }
            )
            
            isLoadingFullFile = false
            
            guard !cancellationRequested else {
                try? FileManager.default.removeItem(at: localURL)
                return
            }
            
            if code == 0, FileManager.default.fileExists(atPath: localURL.path) {
                fileCache[file.path] = localURL
                NSWorkspace.shared.open(localURL)
            } else {
                print("❌ Preview: Failed to pull file: \(error)")
            }
        }
    }
    
    // MARK: - Tiered Preview Methods
    
    /// Load image preview by piping bytes via `adb exec-out cat`.
    /// No temp file needed — bytes convert directly to NSImage in memory.
    /// Falls back to `adb pull` for reliability if exec-out gives corrupted data.
    private func loadImagePreview(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }
        
        // Limit bytes for very large images; most phone images are < 20 MB
        let maxBytes = file.size > smallImageThreshold ? Int(smallImageThreshold) : 0
        
        // Strategy 1: Pipe via exec-out cat (fastest — no temp file)
        let (_, data, _) = await Shell.runAndCaptureData(
            adbPath,
            args: ADBManager.deviceArgs(["exec-out", "cat", file.path]),
            maxBytes: maxBytes,
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        if !data.isEmpty, let image = NSImage(data: data) {
            isLoading = false
            thumbnailCache[file.path] = image
            previewContent = .image(image)
            return
        }
        
        // Strategy 2: Fall back to adb pull (handles exec-out binary corruption)
        print("⚠️ Preview: exec-out cat failed for image, falling back to adb pull")
        let localURL = tempDir.appendingPathComponent(file.name)
        try? FileManager.default.removeItem(at: localURL)
        
        let (code, _, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: ADBManager.deviceArgs(["pull", file.path, localURL.path]),
            progressCallback: { _ in },
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        isLoading = false
        
        if code == 0, let image = NSImage(contentsOf: localURL) {
            fileCache[file.path] = localURL
            thumbnailCache[file.path] = image
            previewContent = .image(image)
        } else {
            previewContent = .error("Failed to load image")
        }
    }
    
    /// Generate video thumbnail using a multi-strategy approach:
    /// 1. MediaStore thumbnail (pre-generated by Android, ~50KB, instant)
    /// 2. Partial pull via `cat` + AVFoundation frame extraction
    /// 3. System video icon placeholder
    private func generateVideoThumbnail(_ file: UnifiedFile) async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            previewContent = .error("ADB not found")
            isLoading = false
            return
        }
        
        // ── Strategy 1: Android MediaStore thumbnail ──────────────────────
        // Query MediaStore for the video's _id, then read its pre-generated thumbnail.
        // This is the fastest path (~50KB transfer, already generated by Android).
        if let thumb = await fetchMediaStoreThumbnail(file: file, adbPath: adbPath) {
            guard !Task.isCancelled, !cancellationRequested else { return }
            isLoading = false
            thumbnailCache[file.path] = thumb
            previewContent = .videoThumbnail(thumb)
            return
        }
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        // ── Strategy 2: Partial pull + AVFoundation ──────────────────────
        // Use `cat` and kill the process after N bytes (more reliable than `head -c`
        // which may not exist on all Android devices).
        if let thumb = await fetchPartialPullThumbnail(file: file, adbPath: adbPath) {
            guard !Task.isCancelled, !cancellationRequested else { return }
            isLoading = false
            thumbnailCache[file.path] = thumb
            previewContent = .videoThumbnail(thumb)
            return
        }
        
        guard !Task.isCancelled, !cancellationRequested else { return }
        
        // ── Strategy 3: Placeholder icon ─────────────────────────────────
        isLoading = false
        previewContent = .videoThumbnail(Self.videoPlaceholderIcon)
    }
    
    // MARK: - Video Thumbnail Strategies
    
    /// Strategy 1: Fetch pre-generated thumbnail from Android MediaStore.
    /// Queries `content://media/external/video/media` for the file's `_id`,
    /// then reads the thumbnail bytes via `content read`.
    private func fetchMediaStoreThumbnail(file: UnifiedFile, adbPath: String) async -> NSImage? {
        // Step 1: Query MediaStore for the video's _id
        let escapedPath = file.path.replacingOccurrences(of: "'", with: "'\\''")
        let queryArgs = ADBManager.deviceArgs([
            "shell", "content", "query",
            "--uri", "content://media/external/video/media",
            "--projection", "_id",
            "--where", "_data='\(escapedPath)'"
        ])
        
        let (queryCode, queryOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: queryArgs, timeoutSeconds: 5
        )
        
        guard queryCode == 0, !queryOutput.isEmpty else {
            print("⚠️ Preview: MediaStore query returned no results for \(file.name)")
            return nil
        }
        
        // Parse _id from output like "Row: 0 _id=12345, ..."
        guard let mediaId = Self.parseMediaStoreId(from: queryOutput) else {
            print("⚠️ Preview: Could not parse MediaStore _id from: \(queryOutput.prefix(100))")
            return nil
        }
        
        // Step 2: Read thumbnail bytes via content read
        let readArgs = ADBManager.deviceArgs([
            "exec-out", "content", "read",
            "--uri", "content://media/external/video/media/\(mediaId)/thumbnail"
        ])
        
        let (_, thumbData, _) = await Shell.runAndCaptureData(
            adbPath,
            args: readArgs,
            maxBytes: 512 * 1024, // Thumbnails are typically < 100KB
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !thumbData.isEmpty, let image = NSImage(data: thumbData) else {
            print("⚠️ Preview: MediaStore thumbnail read failed (bytes=\(thumbData.count))")
            return nil
        }
        
        print("✅ Preview: Got MediaStore thumbnail for \(file.name) (\(thumbData.count) bytes)")
        return image
    }
    
    /// Parse MediaStore _id from content query output.
    /// Format: "Row: 0 _id=12345" or "Row: 0 _id=12345, other_col=value"
    private nonisolated static func parseMediaStoreId(from output: String) -> String? {
        // Look for _id=<number>
        guard let range = output.range(of: #"_id=(\d+)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(output[range])
        return match.replacingOccurrences(of: "_id=", with: "")
    }
    
    /// Strategy 2: Partial pull + AVFoundation frame extraction.
    /// Uses `adb exec-out cat` and kills the process after enough bytes,
    /// then tries to extract a frame with AVAssetImageGenerator.
    private func fetchPartialPullThumbnail(file: UnifiedFile, adbPath: String) async -> NSImage? {
        // Use cat + maxBytes kill (more reliable than `head -c` which may not exist)
        let (_, data, _) = await Shell.runAndCaptureData(
            adbPath,
            args: ADBManager.deviceArgs(["exec-out", "cat", file.path]),
            maxBytes: videoPartialPullBytes,
            cancellationCheck: { [weak self] in
                self?.cancellationRequested ?? false
            }
        )
        
        guard !data.isEmpty else { return nil }
        
        // Write to temp file for AVFoundation
        let partialURL = tempDir.appendingPathComponent("_thumb_\(file.name)")
        defer { try? FileManager.default.removeItem(at: partialURL) }
        
        do {
            try data.write(to: partialURL)
        } catch {
            return nil
        }
        
        return await Self.extractVideoFrame(from: partialURL)
    }
    
    /// Extract a single frame from a (potentially partial) video file.
    /// Runs off the main actor since AVFoundation work is CPU-bound.
    private nonisolated static func extractVideoFrame(from url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false
        ])
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        
        // Try frame at 1 second first (avoids black frames), then fallback to 0
        for time in [CMTime(seconds: 1, preferredTimescale: 600), .zero] {
            if let cgImage = try? generator.copyCGImage(at: time, actualTime: nil) {
                return NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                )
            }
        }
        return nil
    }
    
    /// Cached system video icon — created once, reused for all fallbacks.
    nonisolated static let videoPlaceholderIcon: NSImage = {
        let icon = NSWorkspace.shared.icon(for: .movie)
        icon.size = NSSize(width: 128, height: 128)
        return icon
    }()
    
    // MARK: - Helpers
    
    private nonisolated func parseAndUpdateProgress(_ text: String) {
        // ADB progress format: "[ 45%] /sdcard/video.mp4"
        guard let match = text.range(of: #"\[\s*(\d+)%\]"#, options: .regularExpression) else { return }
        let percentStr = text[match]
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let percent = Int(percentStr) else { return }
        Task { @MainActor [weak self] in
            self?.fullFilePullProgress = "Downloading… \(percent)%"
        }
    }
    
    /// Check if a file type is previewable
    nonisolated static func isPreviewable(_ file: UnifiedFile) -> Bool {
        guard !file.isDirectory else { return false }
        return previewableExtensions.contains(file.pathExtension)
    }
    
    // MARK: - Cleanup
    
    func clearCache() {
        fileCache.removeAll()
        thumbnailCache.removeAll()
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }
    
    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }
}

// MARK: - UnifiedFile Path Extension Helper

extension UnifiedFile {
    /// Lowercase file extension, computed once per access
    var pathExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}
