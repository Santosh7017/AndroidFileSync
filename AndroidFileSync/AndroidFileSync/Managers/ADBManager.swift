

// ADBManager.swift 

import Foundation

class ADBManager {
    // Cache the path so we don't search every time
    private static var adbPath: String?
    
    // Cache folder sizes: [parentPath: [childFolderPath: sizeInBytes]]
    // Populated lazily by fetchFolderSizes, returned instantly on revisit.
    private static var folderSizeCache: [String: [String: UInt64]] = [:]
    
    // Track the active device serial for multi-device support
    static var activeDeviceSerial: String?
    
    // Track if we've already attempted a server restart this session
    private static var hasRestarted = false
    
    /// Returns args with -s <serial> prepended if a device serial is set
    static func deviceArgs(_ args: [String]) -> [String] {
        if let serial = activeDeviceSerial {
            return ["-s", serial] + args
        }
        return args
    }

    // MARK: - Multi-device

    struct ConnectedDevice {
        let serial: String
        var displayName: String  // "Redmi Note 8" or the raw serial as fallback
        var isWireless: Bool { ADBManager.isWirelessSerial(serial) }
        /// IP for wireless devices (nil for mDNS serials without embedded IP)
        var ipAddress: String? {
            guard isWireless, serial.contains(":") else { return nil }
            return serial.components(separatedBy: ":").first
        }
    }

    /// Returns all devices currently listed as 'device' in `adb devices`,
    /// enriched with real model names fetched in parallel.
    static func listAllConnectedDevices() async -> [ConnectedDevice] {
        let path = getADBPath()
        guard !path.isEmpty else { return [] }
        let (_, output, _) = await Shell.runAsyncWithTimeout(path, args: ["devices"], timeoutSeconds: 5.0)
        let serials: [String] = output.split(separator: "\n").compactMap { line -> String? in
            let s = String(line)
            guard !s.starts(with: "List"),
                  s.contains("\tdevice") || s.hasSuffix(" device") else { return nil }
            let serial = String(s.split(separator: "\t").first ?? s.split(separator: " ").first ?? Substring(s))
            return serial.isEmpty ? nil : serial
        }
        // Fetch model names in parallel
        return await withTaskGroup(of: ConnectedDevice.self) { group in
            for serial in serials {
                group.addTask {
                    let (_, raw, _) = await Shell.runAsyncWithTimeout(
                        path,
                        args: ["-s", serial, "shell", "getprop", "ro.product.model"],
                        timeoutSeconds: 3.0
                    )
                    let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return ConnectedDevice(serial: serial, displayName: name.isEmpty ? serial : name)
                }
            }
            var result: [ConnectedDevice] = []
            for await device in group { result.append(device) }
            // Keep original order (group results arrive out of order)
            return result.sorted { serials.firstIndex(of: $0.serial) ?? 0 < serials.firstIndex(of: $1.serial) ?? 0 }
        }
    }

    /// Switch the active target device. Triggers a DeviceManager re-detect to update all state.
    static func switchToDevice(serial: String) {
        activeDeviceSerial = serial
        print("📱 ADB: Switched active device to \(serial)")
    }
    
    // MARK: - ADB Server Management
    
    /// Checks if ADB output indicates a protocol fault or stale server
    private static func isProtocolError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("protocol fault") ||
               lower.contains("couldn't read status") ||
               lower.contains("connection reset") ||
               lower.contains("connection refused") ||
               lower.contains("cannot connect to daemon") ||
               lower.contains("adb server didn't ack") ||
               lower.contains("adb server version") ||
               lower.contains("kill-server")
    }
    
    /// Kills and restarts the ADB server to clear stale state
    /// Returns true if server restarted successfully
    @discardableResult
    static func restartServer() async -> Bool {
        let path = getADBPath()
        guard !path.isEmpty else { return false }
        
        print("🔄 ADB: Restarting ADB server...")
        
        // Kill the server
        let (killCode, _, killError) = await Shell.runAsyncWithTimeout(
            path, args: ["kill-server"], timeoutSeconds: 5.0
        )
        print("🔄 ADB: kill-server result: code=\(killCode), error=\(killError)")
        
        // Wait for the server to fully shut down
        try? await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s
        
        // Start the server
        let (startCode, startOutput, startError) = await Shell.runAsyncWithTimeout(
            path, args: ["start-server"], timeoutSeconds: 10.0
        )
        print("🔄 ADB: start-server result: code=\(startCode), output=\(startOutput), error=\(startError)")
        
        // Wait a moment for the server to be fully ready
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1s
        
        let success = startCode == 0 || startError.lowercased().contains("started successfully")
        print("🔄 ADB: Server restart \(success ? "✅ succeeded" : "❌ failed")")
        
        hasRestarted = true
        return success
    }

    static func getADBPath() -> String {
        if let cached = adbPath { return cached }
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser.path
        
        // Try bundled ADB — check multiple locations since Bundle.main path varies
        // between debug (Xcode DerivedData) and release (app bundle) builds.
        let execDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? ""
        let bundledCandidates = [
            Bundle.main.path(forResource: "adb", ofType: nil),                 // Release bundle
            Bundle.main.resourcePath.map { "\($0)/adb" },                       // Resources dir
            execDir.isEmpty ? nil : "\(execDir)/../Resources/adb",              // Debug run
            execDir.isEmpty ? nil : "\(execDir)/adb",                           // Flat layout
        ].compactMap { $0 }

        for candidate in bundledCandidates {
            if fileManager.fileExists(atPath: candidate) {
                let resolved = (candidate as NSString).standardizingPath
                print("📱 ADB: Using bundled ADB at: \(resolved)")
                adbPath = resolved
                return resolved
            }
        }
        
        // If bundled adb is completely missing, fallback to generic 'adb' in PATH
        // We explicitly do not scan system directories like Homebrew or Android SDK anymore.
        print("⚠️ ADB: Bundled ADB not found! Falling back to generic PATH 'adb'")
        adbPath = "adb"
        return "adb"
    }

    static func isDeviceConnected() async -> Bool {
        let path = getADBPath()
        
        // Check if ADB path is empty (not found on system)
        if path.isEmpty {
            print("❌ ADB: No ADB executable found on this system")
            return false
        }
        
        // Verify ADB executable actually exists at the path
        if !FileManager.default.fileExists(atPath: path) {
            print("❌ ADB: File does not exist at path: \(path)")
            return false
        }
        
        print("📱 ADB: Checking for devices using: \(path)")
        
        // Use async with timeout to prevent hanging if ADB is slow to respond
        let (code, output, error) = await Shell.runAsyncWithTimeout(path, args: ["devices"], timeoutSeconds: 5.0)
        
        if code != 0 {
            print("⚠️ ADB devices command failed with code: \(code), error: \(error)")
            return false
        }
        
        print("📱 ADB devices output: \(output)")
        
        let lines = output.split(separator: "\n")
        var foundSerials: [String] = []
        
        for line in lines {
            let s = String(line)
            if !s.starts(with: "List") &&
               (s.contains("\tdevice") || s.hasSuffix(" device")) {
                let serial = String(s.split(separator: "\t").first ?? s.split(separator: " ").first ?? Substring(s))
                if !serial.isEmpty {
                    foundSerials.append(serial)
                }
            }
        }
        
        guard !foundSerials.isEmpty else {
            print("📱 No device found in ADB output")
            return false
        }

        // Prefer USB; fall back to wireless. ADB 37+ mDNS serials look like
        // "adb-XXXX._adb-tls-connect._tcp" (no colon), so check for that too.
        if let current = activeDeviceSerial, foundSerials.contains(current) {
            print("📱 Keeping active device: \(current)")
        } else if let usbSerial = foundSerials.first(where: { !Self.isWirelessSerial($0) }) {
            activeDeviceSerial = usbSerial
            print("📱 Using USB device: \(usbSerial)")
        } else if let wirelessSerial = foundSerials.first(where: { Self.isWirelessSerial($0) }) {
            activeDeviceSerial = wirelessSerial
            print("📱 Using wireless device: \(wirelessSerial)")
        } else {
            activeDeviceSerial = foundSerials.first
            print("📱 Using device: \(foundSerials.first ?? "unknown")")
        }
        
        return true
    }

    // MARK: - Recursive file listing for folder download
    
    /// Returns every file under `path` with its size and path relative to `path`.
    /// Uses a single `find` shell call so it is fast even on large trees.
    /// - Returns: Array of (devicePath, relativePath, size) tuples.
    static func listAllFilesRecursively(
        path: String,
        progressCallback: ((Int) -> Void)? = nil
    ) async throws -> [(devicePath: String, relativePath: String, size: UInt64)] {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            throw NSError(domain: "ADBError", code: -1, userInfo: [NSLocalizedDescriptionKey: "ADB not found"])
        }
        
        // Single `find` call: print size and relative path for every file
        let cmd = "find '\(path)' -type f -printf '%s %P\\n' 2>/dev/null"
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", cmd]),
            timeoutSeconds: 120.0
        )
        
        guard code == 0 else {
            throw NSError(domain: "ADBError", code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "find command failed" : error])
        }
        
        var results: [(devicePath: String, relativePath: String, size: UInt64)] = []
        let basePath = path.hasSuffix("/") ? path : path + "/"
        
        output.enumerateLines { line, _ in
            guard !line.isEmpty else { return }
            // Format: "<size> <relative/path/to/file>"
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return }
            let size = UInt64(parts[0]) ?? 0
            let relativePath = String(parts[1])
            guard !relativePath.isEmpty else { return }
            let devicePath = basePath + relativePath
            results.append((devicePath: devicePath, relativePath: relativePath, size: size))
        }
        
        progressCallback?(results.count)
        print("📂 Recursive scan of '\(path)': found \(results.count) files")
        return results
    }

    // MARK: - Folder Sizes

    /// Returns the size (in bytes) of each immediate child folder under `path`.
    /// Results are cached in memory — revisiting a folder is instant.
    static func fetchFolderSizes(forParent path: String) async -> [String: UInt64] {
        // Return from cache if already computed
        if let cached = folderSizeCache[path] {
            return cached
        }

        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return [:] }

        // Single simple command — no pipes, no find, no xargs.
        // du -sk path/*/ lists all immediate subdirectories with sizes in KB.
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "du -sk '\(escapedPath)'/*/ 2>/dev/null"
        let (_, output, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", command]),
            timeoutSeconds: 15.0
        )

        var sizes: [String: UInt64] = [:]
        output.enumerateLines { line, _ in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // du output: "<KB>\t<path>/"
            let parts = trimmed.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { return }
            let kb = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
            var folderPath = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Remove trailing slash that du adds for directories
            if folderPath.hasSuffix("/") { folderPath = String(folderPath.dropLast()) }
            guard !folderPath.isEmpty else { return }
            sizes[folderPath] = kb * 1024
        }

        // Cache for instant revisit
        folderSizeCache[path] = sizes
        return sizes
    }

    /// Invalidates cached folder sizes.
    /// - Parameter path: If provided, clears only that parent path. If nil, clears entire cache.
    static func invalidateFolderSizeCache(for path: String? = nil) {
        if let path = path {
            folderSizeCache.removeValue(forKey: path)
        } else {
            folderSizeCache.removeAll()
        }
    }

    static func listFiles(path: String) async throws -> [ADBFile] {
        let adbPath = getADBPath()
        
        let startTime = Date()
        
        // FAST APPROACH: Use ls -1 for names only (very fast even for 1000+ files)
        // Then use a single stat command to get file types
        let listCommand = "ls -1a '\(path)'"
        
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", listCommand]),
            timeoutSeconds: 30.0
        )
        
        let elapsed = Date().timeIntervalSince(startTime)
        
        // Handle errors
        if code != 0 {
            // Suppress "No such file or directory" error for optional paths like Documents
            if !error.contains("No such file or directory") {
                print("❌ ADB Error: \(error)")
            }
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
            return try await listFilesWithDetails(path: path, adbPath: adbPath, exactNames: fileNames)
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
            args: deviceArgs(["shell", findCommand]),
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
    private static func listFilesWithDetails(path: String, adbPath: String, exactNames: [String]) async throws -> [ADBFile] {
        let command = "ls -la '\(path)'"
        
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", command]),
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
        
        for exactName in exactNames {
            // Find the line that ends with this exact name
            // (Note: ls -la might have a space or symlink arrow before the name, but checking suffix is safer)
            guard let lineStr = lines.first(where: { $0.hasSuffix(" " + exactName) || $0.hasSuffix(" " + exactName + "\r") }) else {
                continue
            }
            
            let cleanLine = lineStr.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let parts = cleanLine.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 8 else { continue }
            
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            let size = UInt64(parts[4]) ?? 0
            
            // Parse date - Android ls -la typically shows: YYYY-MM-DD HH:MM
            var modDate: Date? = nil
            if parts.count >= 7 {
                // Find where the date looks like YYYY-MM-DD
                for i in 4..<(parts.count - 1) {
                    let dateCandidate = String(parts[i])
                    if dateCandidate.contains("-") && dateCandidate.count == 10 {
                        let timeCandidate = String(parts[i+1])
                        let dateStr = "\(dateCandidate) \(timeCandidate)"
                        modDate = dateFormatter.date(from: dateStr)
                        break
                    }
                }
            }
            
            let fullPath = path.hasSuffix("/") ? path + exactName : path + "/" + exactName
            files.append(ADBFile(name: exactName, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
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
                        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["pull", devicePath, localPath]))
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
                process.arguments = deviceArgs(["push", localPath, devicePath])
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
                                args: deviceArgs(["shell", "stat", "-c%s", devicePath])
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
                            
                            Thread.sleep(forTimeInterval: 2)
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
            args: deviceArgs([command, source, dest]),
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
        
        // Strategy 1: Use rm -rf with single-quoted path (handles most cases)
        let command = "rm -rf '\(escapedPath)'"
        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
        // rm -rf with -f flag can return 0 even on failure, so verify the file is gone
        let (_, checkOut, _) = await Shell.runAsync(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"])
        )
        let stillExists = checkOut.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS"
        
        if !stillExists {
            // Successfully deleted
            return
        }
        
        // Strategy 2: Pass rm and path as separate arguments (avoids shell re-parsing)
        // This handles filenames with spaces, dots, and special characters better
        print("⚠️ Delete: File still exists after rm -rf, retrying with separate args...")
        let (code2, _, error2) = await Shell.runAsync(
            adbPath,
            args: deviceArgs(["shell", "rm", "-rf", devicePath])
        )
        
        // Verify again
        let (_, checkOut2, _) = await Shell.runAsync(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"])
        )
        let stillExists2 = checkOut2.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS"
        
        if !stillExists2 {
            return
        }
        
        // Strategy 3: Try verbose rm without -f to capture the EXACT error message from Android
        print("⚠️ Delete: Still exists, trying rm -rv without -f to capture error...")
        let (code3, out3, err3) = await Shell.runAsync(
            adbPath,
            args: deviceArgs(["shell", "rm -rv '\(escapedPath)'"])
        )
        
        // Final verification
        let (_, checkOut3, _) = await Shell.runAsync(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"])
        )
        let stillExists3 = checkOut3.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS"
        
        if stillExists3 {
            // It failed. We now have the real error from rm -rv in err3 or out3.
            let combinedOutput = "\(out3) \(err3)".trimmingCharacters(in: .whitespacesAndNewlines)
            let finalErrorMsg = combinedOutput.isEmpty ? "Failed to delete: Unknown error or locked file" : "Failed to delete: \(combinedOutput)"
            
            throw NSError(
                domain: "ADB",
                code: Int(code3 != 0 ? code3 : -1),
                userInfo: [NSLocalizedDescriptionKey: finalErrorMsg]
            )
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
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
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
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
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
    
    /// Creates multiple folders on the Android device in batched ADB calls.
    /// Batches up to 50 paths per shell call to avoid argument length limits.
    static func batchCreateFolders(paths: [String]) async {
        guard !paths.isEmpty else { return }
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        // Deduplicate and sort (shorter paths first so parents are created before children)
        let uniquePaths = Array(Set(paths)).sorted()
        
        // Batch into chunks of 50
        let chunkSize = 50
        for start in stride(from: 0, to: uniquePaths.count, by: chunkSize) {
            let end = min(start + chunkSize, uniquePaths.count)
            let chunk = uniquePaths[start..<end]
            
            // Build a single mkdir -p command with all paths
            let escapedPaths = chunk.map { path in
                let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                return "'\(escaped)'"
            }
            let command = "mkdir -p \(escapedPaths.joined(separator: " "))"
            
            let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
            if code != 0 {
                print("⚠️ Batch mkdir failed for chunk: \(error)")
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
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
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
            let (mkdirCode, _, mkdirError) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", mkdirCmd]))
            
            if mkdirCode != 0 {
                throw NSError(domain: "ADB", code: Int(mkdirCode), userInfo: [NSLocalizedDescriptionKey: mkdirError.isEmpty ? "Failed to create folder" : mkdirError])
            }
            
            // Step 2: Copy contents if any exist (separate call, only if needed)
            let cpCmd = "cp -r '\(escapedSource)/.' '\(escapedDest)/' 2>/dev/null || true"
            let (_, _, _) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", cpCmd]))
            // Ignore result - empty folder will fail but that's OK
            
        } else {
            // Regular file copy
            let command = "cp '\(escapedSource)' '\(escapedDest)'"
            let (code, output, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
            
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
    

    // MARK: - Wireless ADB (Android 11+)
    
    /// Pairs with an Android 11+ device using wireless debugging
    /// - Parameters:
    ///   - ip: Device IP address
    ///   - port: Pairing port (shown on device's wireless debugging screen)
    ///   - code: 6-digit pairing code (shown on device)
    /// - Returns: Tuple of (success, message)
    static func pairDevice(ip: String, port: String, code: String) async -> (Bool, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            return (false, "ADB not found")
        }
        
        let target = "\(ip):\(port)"
        print("📶 ADB: Pairing with \(target)...")
        
        // adb pair <ip>:<port> <code>
        var (exitCode, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["pair", target, code],
            timeoutSeconds: 15.0
        )
        
        var combined = output + error
        print("📶 ADB Pair result: code=\(exitCode), output=\(combined)")
        
        // Auto-recover from protocol faults by restarting ADB server and retrying
        if isProtocolError(combined) {
            print("🔄 ADB: Protocol fault during pairing, restarting server and retrying...")
            let restarted = await restartServer()
            if restarted {
                // Retry the pairing
                (exitCode, output, error) = await Shell.runAsyncWithTimeout(
                    adbPath,
                    args: ["pair", target, code],
                    timeoutSeconds: 15.0
                )
                combined = output + error
                print("📶 ADB Pair retry result: code=\(exitCode), output=\(combined)")
            }
        }
        
        if exitCode == 0 && (combined.lowercased().contains("successfully paired") || combined.lowercased().contains("paired")) {
            hasRestarted = false // Reset for next session
            return (true, "Successfully paired with device")
        } else if combined.lowercased().contains("failed") {
            return (false, "Pairing failed. Check the pairing code and try again.")
        } else if exitCode != 0 {
            return (false, error.isEmpty ? "Pairing failed (code \(exitCode))" : error)
        }
        
        return (true, combined)
    }
    
    /// Connects to a device over WiFi after pairing.
    /// ADB 37+ supports stable mDNS hostnames (e.g. `adb-XXXX.local`) that remain valid
    /// even when the phone's IP changes. When `hostname` is provided, this method tries
    /// connecting via the hostname first and falls back to the raw IP automatically.
    /// - Parameters:
    ///   - ip: Device IP address (used as fallback)
    ///   - port: Connection port (shown in wireless debugging settings)
    ///   - hostname: Optional mDNS hostname, e.g. "adb-XXXX.local" (ADB 37+)
    /// - Returns: Tuple of (success, message)
    static func connectWireless(ip: String, port: String = "5555", hostname: String? = nil) async -> (Bool, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            return (false, "ADB not found")
        }

        // Helper: attempt a single adb connect and return whether it succeeded
        func attempt(target: String) async -> (Bool, String) {
            print("📶 ADB: Connecting to \(target)...")
            let (exitCode, output, error) = await Shell.runAsyncWithTimeout(
                adbPath, args: ["connect", target], timeoutSeconds: 10.0
            )
            let combined = output + error
            print("📶 ADB Connect result: code=\(exitCode), output=\(combined)")
            let lower = combined.lowercased()
            if lower.contains("connected to") || lower.contains("already connected") {
                return (true, combined)
            }
            if lower.contains("cannot connect") || lower.contains("failed") {
                return (false, combined)
            }
            return (exitCode == 0, combined)
        }

        // 1. Try the stable .local hostname first (ADB 37+)
        if let host = hostname, !host.isEmpty {
            let hostnameTarget = "\(host):\(port)"
            let (success, msg) = await attempt(target: hostnameTarget)
            if success {
                return (true, "Connected to \(hostnameTarget)")
            }
            print("📶 ADB: hostname connect failed (\(msg)), falling back to IP...")
        }

        // 2. Fall back to raw IP:port
        let ipTarget = "\(ip):\(port)"
        let (success, msg) = await attempt(target: ipTarget)
        if success {
            return (true, "Connected to \(ipTarget)")
        }
        return (false, "Cannot connect to \(ipTarget). Make sure Wireless Debugging is enabled.")
    }
    
    /// Disconnects from a wireless device
    static func disconnectWireless(ip: String, port: String = "5555") async -> (Bool, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            return (false, "ADB not found")
        }
        
        let target = "\(ip):\(port)"
        let (exitCode, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["disconnect", target],
            timeoutSeconds: 5.0
        )
        
        let combined = output + error
        return (exitCode == 0, combined)
    }
    
    /// Disconnects all wireless devices
    static func disconnectAllWireless() async -> (Bool, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            return (false, "ADB not found")
        }
        
        let (exitCode, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["disconnect"],
            timeoutSeconds: 5.0
        )
        
        let result = (exitCode == 0, output + error)
        // Clear the active serial if it was a wireless device
        if let serial = activeDeviceSerial, isWirelessSerial(serial) {
            activeDeviceSerial = nil
        }
        return result
    }
    
    /// Checks if the currently active device is via wireless (IP:port format)
    static func isWirelessConnection() async -> Bool {
        guard let active = activeDeviceSerial else { return false }
        return isWirelessSerial(active)
    }

    /// Checks if a serial represents a wireless device.
    /// Handles both traditional IP:port and ADB 37+ mDNS serials.
    static func isWirelessSerial(_ serial: String) -> Bool {
        // Traditional: "192.168.1.69:38101"
        if serial.contains(":") && serial.contains(".") { return true }
        // ADB 37+: "adb-XXXX._adb-tls-connect._tcp"
        if serial.contains("._adb-tls-") { return true }
        return false
    }

    /// Returns the IP of the wirelessly connected device, or nil.
    static func getWirelessIP() async -> String? {
        guard let active = activeDeviceSerial, isWirelessSerial(active) else { return nil }
        // Traditional serial: extract IP before the colon
        if active.contains(":") && active.contains(".") {
            return active.components(separatedBy: ":").first
        }
        // ADB 37+ mDNS serial: resolve IP via `ip addr show wlan0`
        // This is more reliable than `ip route` which may pick USB/VPN interfaces
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return nil }
        let (_, output, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "ip", "-f", "inet", "addr", "show", "wlan0"]), timeoutSeconds: 5.0
        )
        // Parse "inet 192.168.1.67/24" from output
        if let range = output.range(of: "inet ") {
            let afterInet = output[range.upperBound...]
            if let ip = afterInet.split(separator: "/").first.map(String.init) {
                return ip.trimmingCharacters(in: .whitespaces)
            }
        }
        // Fallback: try ip route (less reliable but better than nothing)
        let (_, routeOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "ip", "route"]), timeoutSeconds: 5.0
        )
        // Look for wlan route first, then any route
        for line in routeOutput.split(separator: "\n") {
            let s = String(line)
            if s.contains("wlan"), let r = s.range(of: "src ") {
                return String(s[r.upperBound...].split(separator: " ").first ?? "")
            }
        }
        if let range = routeOutput.range(of: "src ") {
            return String(routeOutput[range.upperBound...].split(separator: " ").first ?? "")
        }
        return nil
    }

    // MARK: - Media Scanner
    
    /// Triggers the Android media scanner for a specific file path so it appears in the Gallery immediately.
    /// Uses a lightweight broadcast intent that only indexes the single file, not the entire storage.
    static func triggerMediaScan(path: String) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        
        // Two strategies combined — both target ONLY this specific file, never the whole device:
        //
        // 1. Modern (Android 11+): "cmd media.scanner scan" indexes just this one file
        // 2. Legacy (Android ≤10): broadcast intent for single-file scan
        //
        // Whichever matches the device's Android version will work; the other silently no-ops.
        let command = "cmd media.scanner scan '\(escapedPath)' >/dev/null 2>&1; am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedPath)' >/dev/null 2>&1"
        
        _ = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
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
        
        let (code, output, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
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

