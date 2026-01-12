

// ADBManager.swift 

import Foundation

class ADBManager {
    // Cache the path so we don't search every time
    private static var adbPath: String?

    static func getADBPath() -> String {
        if let cached = adbPath { return cached }
        let fileManager = FileManager.default
        
        // First, try bundled ADB in app Resources
        if let bundledPath = Bundle.main.path(forResource: "adb", ofType: nil) {
            if fileManager.fileExists(atPath: bundledPath) {
                adbPath = bundledPath
                return bundledPath
            }
        }
        
        // Fallback to system-installed ADB
        let possiblePaths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            "\(fileManager.homeDirectoryForCurrentUser.path)/Library/Android/sdk/platform-tools/adb",
            "/usr/bin/adb"
        ]
        for path in possiblePaths {
            if fileManager.fileExists(atPath: path) {
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
        
        // Use find to get file types and modification times efficiently in a single command
        // Format: type timestamp size filename (timestamp is Unix epoch)
        let findCommand = "find '\(path)' -maxdepth 1 -mindepth 1 \\( -type d -printf 'd %T@ %f\\n' -o -type f -printf 'f %T@ %s %f\\n' -o -printf '? %T@ %f\\n' \\) 2>/dev/null"
        
        let (findCode, findOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["shell", findCommand],
            timeoutSeconds: 60.0
        )
        
        if findCode == 0 && !findOutput.isEmpty {
            // Parse find output: "d timestamp dirname" or "f timestamp size filename"
            findOutput.enumerateLines { line, _ in
                guard line.count >= 3 else { return }
                
                let typeChar = line.first
                let rest = String(line.dropFirst(2))
                
                if typeChar == "d" {
                    // Directory: "d timestamp name"
                    let parts = rest.split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        let timestamp = Double(parts[0])
                        let modDate = timestamp.map { Date(timeIntervalSince1970: $0) }
                        let name = String(parts[1])
                        guard !name.isEmpty && name != "." && name != ".." else { return }
                        let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                        files.append(ADBFile(name: name, path: fullPath, isDirectory: true, size: 0, modificationDate: modDate))
                    }
                } else if typeChar == "f" {
                    // File: "f timestamp size name"
                    let parts = rest.split(separator: " ", maxSplits: 2)
                    if parts.count >= 3 {
                        let timestamp = Double(parts[0])
                        let modDate = timestamp.map { Date(timeIntervalSince1970: $0) }
                        let size = UInt64(parts[1]) ?? 0
                        let name = String(parts[2])
                        guard !name.isEmpty else { return }
                        let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                        files.append(ADBFile(name: name, path: fullPath, isDirectory: false, size: size, modificationDate: modDate))
                    }
                } else {
                    // Unknown type, treat as file
                    let parts = rest.split(separator: " ", maxSplits: 1)
                    if parts.count >= 2 {
                        let timestamp = Double(parts[0])
                        let modDate = timestamp.map { Date(timeIntervalSince1970: $0) }
                        let name = String(parts[1])
                        guard !name.isEmpty && name != "." && name != ".." else { return }
                        let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                        files.append(ADBFile(name: name, path: fullPath, isDirectory: false, size: 0, modificationDate: modDate))
                    }
                }
            }
            return files
        }
        
        // Final fallback: just use file names without sizes
        for name in fileNames {
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            // Guess directory by common patterns or lack of extension
            let isDir = !name.contains(".")
            files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: 0, modificationDate: nil))
        }
        
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
        
        // Date formatter for Android ls -la output (format: YYYY-MM-DD HH:MM)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        for lineStr in lines {
            if lineStr.isEmpty || lineStr.hasPrefix("total") { continue }
            
            let parts = lineStr.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 8 else { continue }
            
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            let size = UInt64(parts[4]) ?? 0
            
            // Parse date - Android ls -la typically shows: YYYY-MM-DD HH:MM
            // parts[5] = date (2025-01-05), parts[6] = time (14:30)
            var modDate: Date? = nil
            if parts.count >= 8 {
                let dateStr = "\(parts[5]) \(parts[6])"
                modDate = dateFormatter.date(from: dateStr)
            }
            
            // Name starts at parts[7]
            let name = parts[7...].joined(separator: " ")
            
            guard !name.isEmpty && name != "." && name != ".." else { continue }
            
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
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
                                        
                                        continuation.yield((currentSize, speed))
                                        
                                        lastSize = currentSize
                                        lastCheck = now
                                    }
                                }
                            }
                            
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
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
        totalBytes: UInt64,
        cancellationCheck: @escaping () -> Bool = { false }
    ) -> AsyncStream<(UInt64, Double)> {
        return AsyncStream { continuation in
            let adbPath = getADBPath()
            
            DispatchQueue.global(qos: .userInitiated).async {
                // Create and manage the process directly for cancellation support
                let process = Process()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = ["push", localPath, devicePath]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                
                do {
                    try process.run()
                    let pid = process.processIdentifier
                    
                    // Start cancellation monitor AFTER process is running
                    DispatchQueue.global(qos: .userInitiated).async {
                        while process.isRunning {
                            if cancellationCheck() {
                                print("🛑 Upload: Cancellation detected! Killing PID \(pid)...")
                                kill(pid, SIGKILL)
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.1) // 100ms
                        }
                    }
                    
                    // Start progress polling AFTER process is running
                    DispatchQueue.global(qos: .userInitiated).async {
                        var lastSize: UInt64 = 0
                        var lastCheck = Date()
                        
                        // Wait a moment for transfer to start
                        Thread.sleep(forTimeInterval: 0.5)
                        
                        while process.isRunning && !cancellationCheck() {
                            // Get remote file size using stat (synchronous for simplicity)
                            let (statCode, statOutput, _) = Shell.run(
                                adbPath,
                                args: ["shell", "stat", "-c%s", devicePath]
                            )
                            
                            if statCode == 0, let currentSize = UInt64(statOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                let now = Date()
                                let timeDiff = now.timeIntervalSince(lastCheck)
                                
                                if currentSize > lastSize && timeDiff >= 0.1 {
                                    let bytesDiff = currentSize - lastSize
                                    let speed = Double(bytesDiff) / timeDiff / (1024 * 1024) // MB/s
                                    
                                    continuation.yield((currentSize, speed))
                                    
                                    lastSize = currentSize
                                    lastCheck = now
                                }
                            }
                            
                            // Poll every 1 second
                            Thread.sleep(forTimeInterval: 1.0)
                        }
                    }
                    
                    // Wait for process to complete
                    process.waitUntilExit()
                    
                    if process.terminationStatus == 0 {
                    } else {
                        print("❌ ADB Push exited with code \(process.terminationStatus)")
                    }
                    
                } catch {
                    print("❌ ADB Push Error: \(error)")
                }
                
                // Send final update only if not cancelled
                if !cancellationCheck() {
                    continuation.yield((totalBytes, 0))
                }
                continuation.finish()
            }
        }
    }
    
    // Legacy version for backward compatibility
    static func pushFileWithProgress(
        localPath: String,
        devicePath: String,
        progressCallback: @escaping (UInt64, Double) -> Void,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws {
        try await transferFileWithProgress(
            command: "push",
            source: localPath,
            dest: devicePath,
            callback: progressCallback,
            cancellationCheck: cancellationCheck
        )
    }

    private static func transferFileWithProgress(
        command: String,
        source: String,
        dest: String,
        callback: @escaping (UInt64, Double) -> Void,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws {
        let adbPath = getADBPath()

        var lastUpdate = Date()
        var lastPercent: Double = 0.0
        var buffer = ""
        let startTime = Date()

        let (code, _, error, process) = await Shell.runWithProgressCancellable(
            adbPath,
            args: [command, source, dest],
            progressCallback: { outputChunk in
                // Check for cancellation
                if cancellationCheck() {
                    return
                }
                

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
            },
            cancellationCheck: cancellationCheck
        )
        
        // If cancelled, terminate process if still running
        if cancellationCheck() && process.isRunning {
            process.terminate()
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Transfer cancelled"])
        }
        
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
            let (mkdirCode, _, mkdirError) = await Shell.runAsync(adbPath, args: ["shell", mkdirCmd])
            
            if mkdirCode != 0 {
                throw NSError(domain: "ADB", code: Int(mkdirCode), userInfo: [NSLocalizedDescriptionKey: mkdirError.isEmpty ? "Failed to create folder" : mkdirError])
            }
            
            // Step 2: Copy contents if any exist (separate call, only if needed)
            let cpCmd = "cp -r '\(escapedSource)/.' '\(escapedDest)/' 2>/dev/null || true"
            let (_, _, _) = await Shell.runAsync(adbPath, args: ["shell", cpCmd])
            // Ignore result - empty folder will fail but that's OK
            
        } else {
            // Regular file copy
            let command = "cp '\(escapedSource)' '\(escapedDest)'"
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

