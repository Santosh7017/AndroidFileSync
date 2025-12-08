////
////  ADBManager.swift
////  AndroidFileSync
////
////  Handles all Android Debug Bridge (ADB) operations including
////  file transfers, device detection, and file system operations.
////
//
//import Foundation
//
//// MARK: - Thread-Safe State Actors
//
///// Actor for managing download operation state across threads
//private actor DownloadState {
//    var isComplete: Bool = false
//    var error: String?
//    
//    func markComplete(error: String? = nil) {
//        self.isComplete = true
//        self.error = error
//    }
//    
//    func checkComplete() -> (isComplete: Bool, error: String?) {
//        return (isComplete, error)
//    }
//}
//
///// Actor for managing upload operation state across threads
//private actor UploadState {
//    var isComplete: Bool = false
//    var error: String?
//    
//    func markComplete(error: String? = nil) {
//        self.isComplete = true
//        self.error = error
//    }
//    
//    func checkComplete() -> (isComplete: Bool, error: String?) {
//        return (isComplete, error)
//    }
//}
//
//// MARK: - ADB Manager
//
//class ADBManager {
//    
//    // MARK: - Properties
//    
//    private static var adbPath: String?
//    
//    // MARK: - Configuration
//    
//    private enum Config {
//        static let progressUpdateInterval: TimeInterval = 0.2 // 200ms
//        static let pollInterval: UInt64 = 100_000_000 // 100ms in nanoseconds
//        static let stableCountThreshold = 5
//        static let estimatedUploadSpeed = 40.0 // MB/s
//        
//        static let possibleADBPaths = [
//            "/opt/homebrew/bin/adb",           // Apple Silicon Homebrew
//            "/usr/local/bin/adb",              // Intel Homebrew
//            "~/Library/Android/sdk/platform-tools/adb", // Android Studio
//            "/usr/bin/adb"                     // System default
//        ]
//    }
//    
//    // MARK: - Path Discovery
//    
//    /// Locates the ADB binary on the system
//    /// - Returns: Full path to ADB executable
//    private static func getADBPath() -> String {
//        if let cached = adbPath {
//            return cached
//        }
//        
//        let fileManager = FileManager.default
//        let homeDir = fileManager.homeDirectoryForCurrentUser.path
//        
//        for path in Config.possibleADBPaths {
//            let expandedPath = path.replacingOccurrences(of: "~", with: homeDir)
//            if fileManager.fileExists(atPath: expandedPath) {
//                print("✅ ADB Manager: Found binary at \(expandedPath)")
//                adbPath = expandedPath
//                return expandedPath
//            }
//        }
//        
//        print("⚠️ ADB Manager: Binary not found in common paths, defaulting to 'adb'")
//        return "adb"
//    }
//    
//    // MARK: - Device Detection
//    
//    /// Checks if ADB is installed and executable
//    static func isADBInstalled() -> Bool {
//        let path = getADBPath()
//        return FileManager.default.isExecutableFile(atPath: path) || path == "adb"
//    }
//    
//    /// Checks if an Android device is connected via ADB
//    static func isDeviceConnected() async -> Bool {
//        let path = getADBPath()
//        let (code, output, _) = Shell.run(path, args: ["devices"])
//        
//        guard code == 0 else { return false }
//        
//        return output
//            .split(separator: "\n")
//            .map(String.init)
//            .contains { line in
//                !line.starts(with: "List") &&
//                (line.contains("\tdevice") || line.hasSuffix(" device"))
//            }
//    }
//    
//    static func getDeviceSerial() async -> String? {
//        let path = getADBPath()
//        let (code, output, _) = Shell.run(path, args: ["devices"])
//        guard code == 0 else { return nil }
//        
//        // Find the device line
//        guard let deviceLine = output
//            .split(separator: "\n")
//            .map(String.init)
//            .first(where: { line in
//                !line.starts(with: "List") &&
//                (line.contains("\tdevice") || line.hasSuffix(" device"))
//            }) else {
//            return nil
//        }
//        
//        // Extract serial from the line
//        return deviceLine
//            .components(separatedBy: .whitespacesAndNewlines)
//            .first { !$0.isEmpty }
//    }
//    
//    // MARK: - File Operations
//    
//    /// Lists files and directories at the specified path on the Android device
//    /// - Parameter path: Absolute path on the Android device
//    /// - Returns: Array of ADBFile objects
//    static func listFiles(path: String) async throws -> [ADBFile] {
//        let adbPath = getADBPath()
//        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
//        let command = "ls -la '\(escapedPath)'"
//        
//        let (code, output, error) = Shell.run(adbPath, args: ["shell", command])
//        
//        guard code == 0 else {
//            throw NSError(
//                domain: "ADBError",
//                code: Int(code),
//                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to list files" : error]
//            )
//        }
//        
//        return parseFileList(output: output, basePath: path)
//    }
//    
//    /// Parses ls -la output into ADBFile objects
//    private static func parseFileList(output: String, basePath: String) -> [ADBFile] {
//        output
//            .split(separator: "\n")
//            .map(String.init)
//            .filter { line in
//                !line.starts(with: "total") &&
//                !line.hasSuffix(" .") &&
//                !line.hasSuffix(" ..")
//            }
//            .compactMap { line -> ADBFile? in
//                let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
//                guard parts.count >= 8 else { return nil }
//                
//                let permissions = parts[0]
//                let isDirectory = permissions.first == "d"
//                let size = UInt64(parts[4]) ?? 0
//                let name = parts[7...].joined(separator: " ")
//                let fullPath = basePath.hasSuffix("/") ? basePath + name : basePath + "/" + name
//                
//                return ADBFile(
//                    name: name,
//                    path: fullPath,
//                    isDirectory: isDirectory,
//                    size: size
//                )
//            }
//    }
//    
//    // MARK: - File Transfer: Download
//    
//    /// Downloads a file from Android device to Mac with real-time progress tracking
//    /// - Parameters:
//    ///   - devicePath: Source path on Android device
//    ///   - localPath: Destination path on Mac
//    ///   - progressCallback: Closure called with (bytesTransferred, speedMBps)
//    static func pullFileWithProgress(
//        devicePath: String,
//        localPath: String,
//        progressCallback: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        let adbPath = getADBPath()
//        let state = DownloadState()
//        
//        // Start download in background
//        Task.detached(priority: .userInitiated) {
//            let (code, _, error) = Shell.run(adbPath, args: ["pull", devicePath, localPath])
//            await state.markComplete(error: code != 0 ? error : nil)
//        }
//        
//        // Monitor progress by polling file size
//        try await monitorDownloadProgress(
//            localPath: localPath,
//            state: state,
//            progressCallback: progressCallback
//        )
//    }
//    
//    /// Monitors download progress by polling destination file size
//    private static func monitorDownloadProgress(
//        localPath: String,
//        state: DownloadState,
//        progressCallback: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        let startTime = Date()
//        var lastSize: UInt64 = 0
//        var lastCheckTime = startTime
//        var stableCount = 0
//        
//        while true {
//            let (isComplete, error) = await state.checkComplete()
//            
//            // Check file size if it exists
//            if let currentSize = try? getFileSize(at: localPath), currentSize > 0 {
//                let now = Date()
//                let timeDiff = now.timeIntervalSince(lastCheckTime)
//                
//                if timeDiff > Config.progressUpdateInterval {
//                    let bytesTransferred = currentSize - lastSize
//                    
//                    if bytesTransferred > 0 {
//                        let speedMBps = calculateSpeed(bytes: bytesTransferred, timeInterval: timeDiff)
//                        
//                        await MainActor.run {
//                            progressCallback(currentSize, speedMBps)
//                        }
//                        
//                        stableCount = 0
//                    } else if isComplete {
//                        stableCount += 1
//                    }
//                    
//                    lastSize = currentSize
//                    lastCheckTime = now
//                }
//            }
//            
//            // Exit conditions
//            if isComplete && stableCount > Config.stableCountThreshold {
//                if let error = error {
//                    throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: error])
//                }
//                break
//            }
//            
//            try? await Task.sleep(nanoseconds: Config.pollInterval)
//        }
//        
//        // Send final progress update
//        await sendFinalProgressUpdate(localPath: localPath, startTime: startTime, callback: progressCallback)
//    }
//    
//    // MARK: - File Transfer: Upload
//    
//    /// Uploads a file from Mac to Android device with progress estimation
//    /// - Parameters:
//    ///   - localPath: Source path on Mac
//    ///   - devicePath: Destination path on Android device
//    ///   - progressCallback: Closure called with (bytesTransferred, speedMBps)
//    static func pushFileWithProgress(
//        localPath: String,
//        devicePath: String,
//        progressCallback: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        let adbPath = getADBPath()
//        
//        guard let fileSize = try? getFileSize(at: localPath) else {
//            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Cannot read source file"])
//        }
//        
//        let state = UploadState()
//        
//        // Start upload in background
//        Task.detached(priority: .userInitiated) {
//            let (code, _, error) = Shell.run(adbPath, args: ["push", localPath, devicePath])
//            await state.markComplete(error: code != 0 ? error : nil)
//        }
//        
//        // Simulate progress (can't monitor remote file)
//        try await simulateUploadProgress(
//            fileSize: fileSize,
//            state: state,
//            progressCallback: progressCallback
//        )
//    }
//    
//    /// Simulates upload progress based on estimated speed
//    private static func simulateUploadProgress(
//        fileSize: UInt64,
//        state: UploadState,
//        progressCallback: @escaping (UInt64, Double) -> Void
//    ) async throws {
//        let startTime = Date()
//        
//        while true {
//            let (isComplete, error) = await state.checkComplete()
//            
//            if isComplete {
//                let totalTime = Date().timeIntervalSince(startTime)
//                let actualSpeed = totalTime > 0 ? Double(fileSize) / totalTime / (1024.0 * 1024.0) : 0
//                
//                await MainActor.run {
//                    progressCallback(fileSize, actualSpeed)
//                }
//                
//                if let error = error {
//                    throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: error])
//                }
//                break
//            }
//            
//            // Estimate progress
//            let elapsed = Date().timeIntervalSince(startTime)
//            let estimatedBytes = min(
//                UInt64(elapsed * Config.estimatedUploadSpeed * 1024.0 * 1024.0),
//                fileSize
//            )
//            
//            await MainActor.run {
//                progressCallback(estimatedBytes, Config.estimatedUploadSpeed)
//            }
//            
//            try? await Task.sleep(nanoseconds: Config.pollInterval * 2) // 200ms for uploads
//        }
//    }
//    
//    // MARK: - Helper Methods
//    
//    /// Gets the size of a file
//    private static func getFileSize(at path: String) throws -> UInt64 {
//        let attributes = try FileManager.default.attributesOfItem(atPath: path)
//        return attributes[.size] as? UInt64 ?? 0
//    }
//    
//    /// Calculates transfer speed in MB/s
//    private static func calculateSpeed(bytes: UInt64, timeInterval: TimeInterval) -> Double {
//        guard timeInterval > 0 else { return 0 }
//        let bytesPerSecond = Double(bytes) / timeInterval
//        return bytesPerSecond / (1024.0 * 1024.0)
//    }
//    
//    /// Sends final progress update with complete file stats
//    private static func sendFinalProgressUpdate(
//        localPath: String,
//        startTime: Date,
//        callback: @escaping (UInt64, Double) -> Void
//    ) async {
//        guard FileManager.default.fileExists(atPath: localPath),
//              let finalSize = try? getFileSize(at: localPath) else {
//            return
//        }
//        
//        let totalTime = Date().timeIntervalSince(startTime)
//        let avgSpeed = calculateSpeed(bytes: finalSize, timeInterval: totalTime)
//        
//        await MainActor.run {
//            callback(finalSize, avgSpeed)
//        }
//    }
//}
//
//// MARK: - Models
//
///// Represents a file or directory on an Android device
//struct ADBFile: Identifiable {
//    let id = UUID()
//    let name: String
//    let path: String
//    let isDirectory: Bool
//    let size: UInt64
//}

//
//  ADBManager.swift
//  (DEFINITIVE NON-BLOCKING FIX)
//
//
//  ADBManager.swift
//
//
//  ADBManager.swift
//

// ADBManager.swift (restore this)

import Foundation

class ADBManager {
    // Cache the path so we don't search every time
    private static var adbPath: String?

    static func getADBPath() -> String {
        if let cached = adbPath { return cached }
        let fileManager = FileManager.default
        let possiblePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(fileManager.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]
        for path in possiblePaths {
            if fileManager.fileExists(atPath: path) {
                print("✅ ADB Manager: Found binary at \(path)")
                adbPath = path
                return path
            }
        }
        print("⚠️ ADB Manager: Defaulting to 'adb'")
        return "adb"
    }

    static func isDeviceConnected() async -> Bool {
        let path = getADBPath()
        let (code, output, _) = Shell.run(path, args: ["devices"])
        if code != 0 { return false }
        let lines = output.split(separator: "\n")
        for line in lines {
            let s = String(line)
            if !s.starts(with: "List") &&
               (s.contains("\tdevice") || s.hasSuffix(" device")) {
                return true
            }
        }
        return false
    }

    static func listFiles(path: String) async throws -> [ADBFile] {
        let adbPath = getADBPath()
        
        print("📂 ADB: Listing files in \(path)")
        let startTime = Date()
        
        // FAST APPROACH: Use ls -1 for names only (very fast even for 1000+ files)
        // Then use a single stat command to get file types
        let listCommand = "ls -1a '\(path)'"
        
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["shell", listCommand],
            timeoutSeconds: 30.0
        )
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("📂 ADB: ls -1 completed in \(String(format: "%.1f", elapsed))s, code=\(code), output=\(output.count) chars")
        
        // Handle errors
        if code != 0 {
            print("❌ ADB Error: \(error)")
            throw NSError(
                domain: "ADBError",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to list files" : error]
            )
        }
        
        // Parse file names
        var fileNames: [String] = []
        output.enumerateLines { name, _ in
            // Skip . and .. and empty lines
            guard !name.isEmpty && name != "." && name != ".." else { return }
            fileNames.append(name)
        }
        
        print("📂 ADB: Found \(fileNames.count) entries")
        
        if fileNames.isEmpty {
            return []
        }
        
        // For small directories, use ls -la to get full details
        if fileNames.count <= 100 {
            return try await listFilesWithDetails(path: path, adbPath: adbPath)
        }
        
        // For large directories, get file types using stat command
        // Build a command that checks each file's type
        var files: [ADBFile] = []
        files.reserveCapacity(fileNames.count)
        
        // Use find to get file types efficiently in a single command
        let findCommand = "find '\(path)' -maxdepth 1 -mindepth 1 \\( -type d -printf 'd %f\\n' -o -type f -printf 'f %s %f\\n' -o -printf '? %f\\n' \\) 2>/dev/null"
        
        let (findCode, findOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["shell", findCommand],
            timeoutSeconds: 60.0
        )
        
        if findCode == 0 && !findOutput.isEmpty {
            // Parse find output: "d dirname" or "f size filename"
            findOutput.enumerateLines { line, _ in
                guard line.count >= 3 else { return }
                
                let typeChar = line.first
                let rest = String(line.dropFirst(2))
                
                if typeChar == "d" {
                    // Directory: "d name"
                    let name = rest
                    guard !name.isEmpty && name != "." && name != ".." else { return }
                    let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    files.append(ADBFile(name: name, path: fullPath, isDirectory: true, size: 0))
                } else if typeChar == "f" {
                    // File: "f size name"
                    let parts = rest.split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        let size = UInt64(parts[0]) ?? 0
                        let name = String(parts[1])
                        guard !name.isEmpty else { return }
                        let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                        files.append(ADBFile(name: name, path: fullPath, isDirectory: false, size: size))
                    }
                } else {
                    // Unknown type, treat as file
                    let name = rest
                    guard !name.isEmpty && name != "." && name != ".." else { return }
                    let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    files.append(ADBFile(name: name, path: fullPath, isDirectory: false, size: 0))
                }
            }
            print("📂 ADB: Parsed \(files.count) files via find")
            return files
        }
        
        // Final fallback: just use file names without sizes
        print("📂 ADB: Using name-only fallback for \(fileNames.count) files")
        for name in fileNames {
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            // Guess directory by common patterns or lack of extension
            let isDir = !name.contains(".")
            files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: 0))
        }
        
        print("📂 ADB: Returned \(files.count) files")
        return files
    }
    
    // Helper for small directories - uses ls -la for full details
    private static func listFilesWithDetails(path: String, adbPath: String) async throws -> [ADBFile] {
        let command = "ls -la '\(path)'"
        
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["shell", command],
            timeoutSeconds: 60.0
        )
        
        if code != 0 {
            throw NSError(
                domain: "ADBError",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to list files" : error]
            )
        }
        
        var files: [ADBFile] = []
        let lines = output.components(separatedBy: "\n")
        
        for lineStr in lines {
            if lineStr.isEmpty || lineStr.hasPrefix("total") { continue }
            
            let parts = lineStr.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 8 else { continue }
            
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            let size = UInt64(parts[4]) ?? 0
            let name = parts[7...].joined(separator: " ")
            
            guard !name.isEmpty && name != "." && name != ".." else { continue }
            
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size))
        }
        
        return files
    }

    static func pullFileWithProgress(
        devicePath: String,
        localPath: String
    ) -> AsyncStream<(UInt64, Double)> {
        return AsyncStream { continuation in
            let adbPath = getADBPath()
            
            Task {
                await withTaskGroup(of: Void.self) { group in
                    // Task 1: Run the download
                    group.addTask {
                        let (code, _, error) = await Shell.runAsync(adbPath, args: ["pull", devicePath, localPath])
                        if code != 0 {
                            print("❌ ADB Pull Error: \(error)")
                        } else {
                            print("✅ ADB Pull completed successfully")
                        }
                    }
                    
                    // Task 2: Poll for progress
                    group.addTask {
                        var lastSize: UInt64 = 0
                        var lastCheck = Date()
                        
                        while !Task.isCancelled {
                            if FileManager.default.fileExists(atPath: localPath) {
                                if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                                   let currentSize = attrs[.size] as? UInt64 {
                                    
                                    let now = Date()
                                    let timeDiff = now.timeIntervalSince(lastCheck)
                                    
                                    if currentSize > lastSize && timeDiff >= 0.1 {
                                        let bytesDiff = currentSize - lastSize
                                        let speed = Double(bytesDiff) / timeDiff / (1024 * 1024) // MB/s
                                        
                                        print("📊 Progress: \(currentSize) bytes, \(String(format: "%.1f", speed)) MB/s")
                                        continuation.yield((currentSize, speed))
                                        
                                        lastSize = currentSize
                                        lastCheck = now
                                    }
                                }
                            }
                            
                            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms - reduce ADB contention
                        }
                    }
                    
                    // Wait for download to complete
                    await group.next()
                    
                    // Cancel the polling task
                    group.cancelAll()
                }
                
                // Send final update
                if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                   let finalSize = attrs[.size] as? UInt64 {
                    continuation.yield((finalSize, 0))
                }
                
                continuation.finish()
            }
        }
    }

    static func pushFileWithProgress(
        localPath: String,
        devicePath: String,
        progressCallback: @escaping (UInt64, Double) -> Void
    ) async throws {
        // For uploads, we still rely on ADB output parsing as we can't easily poll remote file size
        try await transferFileWithProgress(
            command: "push",
            source: localPath,
            dest: devicePath,
            callback: progressCallback
        )
    }

    private static func transferFileWithProgress(
        command: String,
        source: String,
        dest: String,
        callback: @escaping (UInt64, Double) -> Void
    ) async throws {
        let adbPath = getADBPath()

        var lastUpdate = Date()
        var lastPercent: Double = 0.0
        var buffer = ""
        let startTime = Date()

        let (code, _, error) = await Shell.runWithProgress(
            adbPath,
            args: [command, source, dest],
            progressCallback: { outputChunk in
                buffer += outputChunk
                if buffer.count > 300 {
                    buffer = String(buffer.suffix(300))
                }

                // Match any number followed by % (e.g., "12%", "[12%]", "(12%)")
                if let range = buffer.range(of: "(\\d+)%", options: .regularExpression) {
                    let match = String(buffer[range])
                    let digits = match.components(
                        separatedBy: CharacterSet.decimalDigits.inverted
                    ).joined()
                    
                    if let percent = Double(digits) {
                        if percent > lastPercent || Date().timeIntervalSince(lastUpdate) > 0.1 {
                             let now = Date()
                             let dt = now.timeIntervalSince(lastUpdate)
                             var estimatedSpeed: Double = 0.0
                             
                             if dt > 0.1 { 
                                 let dp = percent - lastPercent
                                 estimatedSpeed = dp / dt 
                             }
                             
                             lastUpdate = now
                             lastPercent = percent
                             
                             callback(UInt64(percent), estimatedSpeed)
                        }
                    }
                }
            }
        )
        
        if code == 0 {
            let totalTime = Date().timeIntervalSince(startTime)
            let avgSpeed = totalTime > 0 ? 100.0 / totalTime : 0
            callback(100, avgSpeed)
        }

        if code != 0 {
            if error.contains("read-only") || error.contains("permission denied") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Permission denied. Try a different folder."]
                )
            }
            throw NSError(
                domain: "ADB",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error]
            )
        }
    }
    
    // MARK: - File Management Operations
    
    /// Deletes a file or folder from the Android device
    /// - Parameter devicePath: Path to the file or folder on the device
    static func deleteFile(devicePath: String) async throws {
        let adbPath = getADBPath()
        
        // Escape single quotes in the path
        let escapedPath = devicePath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Use rm -rf to delete files and folders recursively
        let command = "rm -rf '\(escapedPath)'"
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: ["shell", command])
        
        if code != 0 {
            // Check for specific error types
            if error.contains("Read-only file system") || error.contains("read-only") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Cannot delete: File system is read-only"]
                )
            } else if error.contains("Permission denied") || error.contains("permission denied") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Cannot delete: Permission denied"]
                )
            } else if error.contains("No such file") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "File not found"]
                )
            } else {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to delete file" : error]
                )
            }
        }
        
        print("✅ Deleted: \(devicePath)")
    }
    
    /// Renames or moves a file/folder on the Android device
    /// - Parameters:
    ///   - oldPath: Current path of the file/folder
    ///   - newPath: New path for the file/folder
    static func renameFile(oldPath: String, newPath: String) async throws {
        let adbPath = getADBPath()
        
        // Escape single quotes in both paths
        let escapedOldPath = oldPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedNewPath = newPath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Use mv command to rename/move
        let command = "mv '\(escapedOldPath)' '\(escapedNewPath)'"
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: ["shell", command])
        
        if code != 0 {
            // Check for specific error types
            if error.contains("Read-only file system") || error.contains("read-only") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Cannot rename: File system is read-only"]
                )
            } else if error.contains("Permission denied") || error.contains("permission denied") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Cannot rename: Permission denied"]
                )
            } else if error.contains("No such file") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "File not found"]
                )
            } else if error.contains("File exists") || error.contains("already exists") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "A file with that name already exists"]
                )
            } else {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to rename file" : error]
                )
            }
        }
        
        print("✅ Renamed: \(oldPath) → \(newPath)")
    }
    
    // MARK: - Create Folder
    
    /// Creates a new folder on the Android device
    /// - Parameter path: Full path for the new folder
    static func createFolder(at path: String) async throws {
        let adbPath = getADBPath()
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "mkdir -p '\(escapedPath)'"
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: ["shell", command])
        
        if code != 0 {
            if error.contains("Read-only") {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot create folder: File system is read-only"])
            } else if error.contains("Permission denied") {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot create folder: Permission denied"])
            } else {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to create folder" : error])
            }
        }
        
        print("✅ Created folder: \(path)")
    }
    
    // MARK: - Create File
    
    /// Creates an empty file on the Android device
    /// - Parameter path: Full path for the new file
    static func createFile(at path: String, content: String = "") async throws {
        let adbPath = getADBPath()
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        
        // Use touch for empty file, or echo for content
        let command: String
        if content.isEmpty {
            command = "touch '\(escapedPath)'"
        } else {
            let escapedContent = content.replacingOccurrences(of: "'", with: "'\\''")
            command = "echo '\(escapedContent)' > '\(escapedPath)'"
        }
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: ["shell", command])
        
        if code != 0 {
            if error.contains("Read-only") {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot create file: File system is read-only"])
            } else if error.contains("Permission denied") {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot create file: Permission denied"])
            } else {
                throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to create file" : error])
            }
        }
        
        print("✅ Created file: \(path)")
    }
    
    // MARK: - Copy File
    
    /// Copies a file or folder on the Android device
    /// - Parameters:
    ///   - sourcePath: Source path
    ///   - destinationPath: Destination path
    ///   - isDirectory: Whether source is a directory
    static func copyFile(from sourcePath: String, to destinationPath: String, isDirectory: Bool = false) async throws {
        let adbPath = getADBPath()
        let escapedSource = sourcePath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDest = destinationPath.replacingOccurrences(of: "'", with: "'\\''")
        
        if isDirectory {
            // Step 1: Create the directory (fast)
            let mkdirCmd = "mkdir -p '\(escapedDest)'"
            print("📁 Creating folder: \(destinationPath)")
            let (mkdirCode, _, mkdirError) = await Shell.runAsync(adbPath, args: ["shell", mkdirCmd])
            
            if mkdirCode != 0 {
                throw NSError(domain: "ADB", code: Int(mkdirCode), userInfo: [NSLocalizedDescriptionKey: mkdirError.isEmpty ? "Failed to create folder" : mkdirError])
            }
            
            // Step 2: Copy contents if any exist (separate call, only if needed)
            let cpCmd = "cp -r '\(escapedSource)/.' '\(escapedDest)/' 2>/dev/null || true"
            let (_, _, _) = await Shell.runAsync(adbPath, args: ["shell", cpCmd])
            // Ignore result - empty folder will fail but that's OK
            
            print("✅ Copied folder: \(sourcePath) → \(destinationPath)")
        } else {
            // Regular file copy
            let command = "cp '\(escapedSource)' '\(escapedDest)'"
            print("📋 Executing: adb shell \(command)")
            let (code, output, error) = await Shell.runAsync(adbPath, args: ["shell", command])
            
            if code != 0 {
                print("❌ Copy failed: code=\(code), error=\(error), output=\(output)")
                if error.contains("Read-only") {
                    throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot copy: File system is read-only"])
                } else if error.contains("Permission denied") {
                    throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Cannot copy: Permission denied"])
                } else if error.contains("No such file") {
                    throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Source file not found"])
                } else {
                    throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to copy" : error])
                }
            }
            
            print("✅ Copied: \(sourcePath) → \(destinationPath)")
        }
    }
    
    // MARK: - Get File Info
    
    /// Gets detailed information about a file
    /// - Parameter path: Path to the file
    /// - Returns: Dictionary with file properties
    static func getFileInfo(path: String) async throws -> [String: String] {
        let adbPath = getADBPath()
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        
        // Get file stats using stat command
        let command = "stat -c '%s|%Y|%a|%U|%G|%F' '\(escapedPath)' 2>/dev/null || ls -ld '\(escapedPath)'"
        
        let (code, output, error) = await Shell.runAsync(adbPath, args: ["shell", command])
        
        if code != 0 || output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(domain: "ADB", code: Int(code), userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to get file info" : error])
        }
        
        var info: [String: String] = [:]
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Parse stat output: size|modtime|permissions|owner|group|type
        let parts = trimmed.split(separator: "|")
        if parts.count >= 6 {
            info["size"] = String(parts[0])
            if let timestamp = Double(parts[1]) {
                let date = Date(timeIntervalSince1970: timestamp)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                info["modified"] = formatter.string(from: date)
            }
            info["permissions"] = String(parts[2])
            info["owner"] = String(parts[3])
            info["group"] = String(parts[4])
            info["type"] = String(parts[5])
        }
        
        info["path"] = path
        return info
    }
}

// Your existing ADBFile model
//struct ADBFile: Identifiable {
//    var id = UUID()
//    let name: String
//    let path: String
//    let isDirectory: Bool
//    let size: UInt64
//}
//
