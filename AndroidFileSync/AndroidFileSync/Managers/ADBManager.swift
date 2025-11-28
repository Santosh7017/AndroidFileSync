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

    private static func getADBPath() -> String {
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
        let command = "ls -la '\(path)'"
        let (code, output, error) = Shell.run(adbPath, args: ["shell", command])
        guard code == 0 else {
            throw NSError(
                domain: "ADBError",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to list files" : error]
            )
        }

        var files: [ADBFile] = []
        let lines = output.split(separator: "\n")
        for line in lines {
            let lineStr = String(line)
            if lineStr.starts(with: "total") ||
               lineStr.hasSuffix(" .") ||
               lineStr.hasSuffix(" ..") {
                continue
            }
            let parts = lineStr
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
            guard parts.count >= 8 else { continue }

            let perms = parts[0]
            let isDir = perms.first == "d"
            let size = UInt64(parts[4]) ?? 0

            let nameStartIndex = 7
            if parts.count > nameStartIndex {
                let name = parts[nameStartIndex...].joined(separator: " ")
                let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                files.append(ADBFile(
                    name: name,
                    path: fullPath,
                    isDirectory: isDir,
                    size: size
                ))
            }
        }
        return files
    }

    static func pullFileWithProgress(
        devicePath: String,
        localPath: String,
        progressCallback: @escaping (UInt64, Double) -> Void
    ) async throws {
        try await transferFileWithProgress(
            command: "pull",
            source: devicePath,
            dest: localPath,
            callback: progressCallback
        )
    }

    static func pushFileWithProgress(
        localPath: String,
        devicePath: String,
        progressCallback: @escaping (UInt64, Double) -> Void
    ) async throws {
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

        let (code, _, error) = await Shell.runWithProgress(
            adbPath,
            args: [command, source, dest],
            progressCallback: { outputChunk in
                buffer += outputChunk
                if buffer.count > 200 {
                    buffer = String(buffer.suffix(200))
                }

                if let range = buffer.range(of: "\\[\\s*(\\d+)%\\]", options: .regularExpression) {
                    let match = String(buffer[range])
                    let digits = match.components(
                        separatedBy: CharacterSet.decimalDigits.inverted
                    ).joined()
                    if let percent = Double(digits) {
                        let now = Date()
                        let dt = now.timeIntervalSince(lastUpdate)
                        var estimatedSpeed: Double = 0.0
                        if dt >= 0.5 {
                            let dp = percent - lastPercent
                            estimatedSpeed = dp / dt
                            lastUpdate = now
                            lastPercent = percent
                        }
                        callback(UInt64(percent), estimatedSpeed)
                    }
                }
            }
        )

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
