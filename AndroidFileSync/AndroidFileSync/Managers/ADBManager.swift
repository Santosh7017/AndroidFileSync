

// ADBManager.swift 

import Foundation

class ADBManager {
    // Cache the path so we don't search every time
    private static var adbPath: String?
    
    // Cache folder sizes: [folderPath: sizeInBytes]
    // Populated lazily by fetchSingleFolderSize, returned instantly on revisit.
    private static var folderSizeCache: [String: UInt64] = [:]
    
    // Track the active device serial for multi-device support
    static var activeDeviceSerial: String?
    
    // Track if we've already attempted a server restart this session
    private static var hasRestarted = false
    /// Cooldown for mDNS recovery restarts so we don't thrash ADB daemon.
    private static var lastMDNSRecoveryAt: Date?
    /// Wireless endpoints this app connected to in current session.
    private static var appManagedWirelessTargets = Set<String>()
    /// ADB mDNS can be empty while Bonjour works. Cache the fallback briefly so UI actions
    /// don't spawn multiple dns-sd browse/lookup/resolve commands per second.
    private static var bonjourServicesCache: (output: String, timestamp: Date)?
    private static var bonjourServicesTask: Task<String, Never>?
    private static var lastBonjourFallbackLogAt: Date?
    private static var restartServerTask: Task<Bool, Never>?
    private static var lastServerRestartAttemptAt: Date?
    
    /// Returns args with -s <serial> prepended if a device serial is set
    static func deviceArgs(_ args: [String]) -> [String] {
        if let serial = activeDeviceSerial {
            return ["-s", serial] + args
        }
        return args
    }

    // MARK: - Multi-device

    struct ConnectedDevice: Equatable {
        let serial: String
        var displayName: String  // "Redmi Note 8" or the raw serial as fallback
        var status: String = "device" // "device", "unauthorized", "offline"
        var hardwareSerial: String? = nil
        var isWireless: Bool { ADBManager.isWirelessSerial(serial) }
        /// IP for wireless devices (nil for mDNS serials without embedded IP)
        var ipAddress: String? {
            guard isWireless, serial.contains(":") else { return nil }
            return serial.components(separatedBy: ":").first
        }
        
        var derivedHardwareSerial: String? {
            if let hw = hardwareSerial, !hw.isEmpty { return hw }
            if isWireless {
                if serial.contains("._adb-tls-") {
                    let serviceName = serial.components(separatedBy: ".").first ?? ""
                    return ADBManager.extractHardwareSerial(from: serviceName)
                }
            } else {
                return serial
            }
            return nil
        }
    }

    /// Returns all devices currently listed as 'device', 'unauthorized', or 'offline' in `adb devices`,
    /// enriched with real model names fetched in parallel.
    static func listAllConnectedDevices() async -> [ConnectedDevice] {
        let path = getADBPath()
        guard !path.isEmpty else { return [] }
        let (_, output, _) = await Shell.runAsyncWithTimeout(path, args: ["devices"], timeoutSeconds: 5.0)
        let parsed: [(serial: String, status: String)] = output.split(separator: "\n").compactMap { line -> (String, String)? in
            let s = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.starts(with: "List"), !s.isEmpty else { return nil }
            let parts = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2 else { return nil }
            let serial = parts[0]
            let status = parts[1]
            guard status == "device" || status == "unauthorized" || status == "offline" else { return nil }
            return (serial, status)
        }
        let serials = parsed.map { $0.serial }
        
        // Fetch model names and hardware serials in parallel
        return await withTaskGroup(of: ConnectedDevice.self) { group in
            for item in parsed {
                group.addTask {
                    let displayName: String
                    let hwSerial: String?
                    if item.status == "device" {
                        displayName = await deviceDisplayName(for: item.serial, adbPath: path)
                        hwSerial = await getHardwareSerial(for: item.serial)
                    } else {
                        if item.status == "unauthorized" {
                            displayName = "\(item.serial) (Unauthorized)"
                        } else {
                            displayName = "\(item.serial) (Offline)"
                        }
                        
                        // For unauthorized/offline devices, try to extract from Bonjour serial if possible
                        if isWirelessSerial(item.serial) && item.serial.contains("._adb-tls-") {
                            let serviceName = item.serial.components(separatedBy: ".").first ?? ""
                            hwSerial = extractHardwareSerial(from: serviceName)
                        } else {
                            hwSerial = nil
                        }
                    }
                    return ConnectedDevice(
                        serial: item.serial,
                        displayName: displayName,
                        status: item.status,
                        hardwareSerial: hwSerial
                    )
                }
            }
            var result: [ConnectedDevice] = []
            for await device in group { result.append(device) }
            // Keep original order (group results arrive out of order)
            return result.sorted { serials.firstIndex(of: $0.serial) ?? 0 < serials.firstIndex(of: $1.serial) ?? 0 }
        }
    }

    private static func deviceDisplayName(for serial: String, adbPath: String) async -> String {
        let properties = ["ro.product.model", "ro.product.marketname", "ro.product.name"]
        for property in properties {
            let (_, raw, _) = await Shell.runAsyncWithTimeout(
                adbPath,
                args: ["-s", serial, "shell", "getprop", property],
                timeoutSeconds: 2.5
            )
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        let (_, brandRaw, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["-s", serial, "shell", "getprop", "ro.product.brand"],
            timeoutSeconds: 2.0
        )
        let (_, modelRaw, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["-s", serial, "shell", "getprop", "ro.product.model"],
            timeoutSeconds: 2.0
        )
        let brand = brandRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = modelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        return combined.isEmpty ? serial : combined
    }

    /// Switch the active target device. Triggers a DeviceManager re-detect to update all state.
    static func switchToDevice(serial: String) {
        activeDeviceSerial = serial
        print("📱 ADB: Switched active device to \(serial)")
    }

    static func markAppManagedWirelessTarget(_ target: String) {
        guard isWirelessSerial(target) else { return }
        appManagedWirelessTargets.insert(target)
    }
    
    // MARK: - ADB Server Management
    
    /// Checks if ADB output indicates a protocol fault or stale server
    private static func isProtocolError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("protocol fault") ||
               lower.contains("couldn't read status") ||
               lower.contains("cannot connect to daemon") ||
               lower.contains("adb server didn't ack") ||
               lower.contains("adb server version") ||
               lower.contains("kill-server")
    }
    
    /// Kills and restarts the ADB server to clear stale state.
    /// Serialized and rate-limited so concurrent discovery/pair/connect failures do not
    /// fight over the same private ADB daemon.
    @discardableResult
    static func restartServer() async -> Bool {
        if let task = restartServerTask {
            print("🔄 ADB: Restart already in progress; waiting for it...")
            return await task.value
        }

        let now = Date()
        if let last = lastServerRestartAttemptAt, now.timeIntervalSince(last) < 6.0 {
            print("🔄 ADB: Restart skipped; last attempt was too recent.")
            return false
        }
        lastServerRestartAttemptAt = now

        let task = Task { () -> Bool in
            let path = getADBPath()
            guard !path.isEmpty else { return false }

            print("🔄 ADB: Restarting ADB server...")

            let (killCode, _, killError) = await Shell.runAsyncWithTimeout(
                path, args: ["kill-server"], timeoutSeconds: 4.0
            )
            print("🔄 ADB: kill-server result: code=\(killCode), error=\(killError)")

            try? await Task.sleep(nanoseconds: 1_200_000_000)

            let (startCode, startOutput, startError) = await Shell.runAsyncWithTimeout(
                path, args: ["start-server"], timeoutSeconds: 8.0
            )
            print("🔄 ADB: start-server result: code=\(startCode), output=\(startOutput), error=\(startError)")

            try? await Task.sleep(nanoseconds: 600_000_000)

            let success = startCode == 0 || startError.lowercased().contains("started successfully")
            print("🔄 ADB: Server restart \(success ? "✅ succeeded" : "❌ failed")")
            hasRestarted = true
            return success
        }

        restartServerTask = task
        let success = await task.value
        restartServerTask = nil
        return success
    }

    /// If the app's private adb server does not see USB, but the default adb
    /// server does, the default server is holding the physical USB transport.
    /// Release it and restart the private server so the app can own USB again.
    @discardableResult
    static func recoverPrivateUSBTransportIfNeeded(forceRestart: Bool = false) async -> Bool {
        let path = getADBPath()
        guard !path.isEmpty else { return false }

        func restartPrivateServer(reason: String) async -> Bool {
            print("🔄 ADB: \(reason)")

            let _ = await Shell.runAsyncWithTimeout(
                path,
                args: ["kill-server"],
                timeoutSeconds: 3.0
            )

            try? await Task.sleep(nanoseconds: 700_000_000)

            let (startCode, startOutput, startError) = await Shell.runAsyncWithTimeout(
                path,
                args: ["start-server"],
                timeoutSeconds: 6.0
            )
            let startText = (startOutput + startError).lowercased()
            let started = startCode == 0 || startText.contains("started successfully") || startText.contains("daemon started")

            if started {
                try? await Task.sleep(nanoseconds: 700_000_000)
                print("🔄 ADB: Private server restarted for USB transport recovery.")
            } else {
                print("🔄 ADB: Private server USB recovery failed: \((startOutput + startError).trimmingCharacters(in: .whitespacesAndNewlines))")
            }

            return started
        }

        let (_, privateOutput, _) = await Shell.runAsyncWithTimeout(
            path,
            args: ["devices", "-l"],
            timeoutSeconds: 3.0
        )
        if privateOutput.contains(" usb:") {
            return false
        }

        let (_, defaultOutput, _) = await Shell.runAsyncWithTimeout(
            path,
            args: ["devices", "-l"],
            timeoutSeconds: 3.0,
            environment: Shell.defaultADBEnvironment
        )
        guard defaultOutput.contains(" usb:") else {
            // Neither the private nor the default server has a USB device.
            // Do NOT restart the private server, as that will kill any active WiFi/mDNS connections.
            return false
        }

        print("🔄 ADB: Default server is holding a USB device; moving USB transport to private server.")
        let _ = await Shell.runAsyncWithTimeout(
            path,
            args: ["kill-server"],
            timeoutSeconds: 3.0,
            environment: Shell.defaultADBEnvironment
        )

        // Poll the private server to give it time to auto-detect and claim the released USB device.
        // Auto-detecting the USB interface after releasing the port-5037 server can take 1-3 seconds.
        var claimed = false
        for attempt in 1...8 {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            let (_, postKillOutput, _) = await Shell.runAsyncWithTimeout(
                path,
                args: ["devices", "-l"],
                timeoutSeconds: 2.0
            )
            if postKillOutput.contains(" usb:") {
                print("🔄 ADB: Private server automatically claimed the USB transport after \(Double(attempt) * 0.5)s.")
                claimed = true
                break
            }
        }
        
        if claimed {
            return true
        }

        // Fallback: If it didn't auto-detect, restart the private server, BUT only if there's no active wireless connection or if we are forcing it.
        if !forceRestart, let activeSerial = activeDeviceSerial, isWirelessSerial(activeSerial) {
            print("🔄 ADB: Private server did not auto-claim USB after polling, but wireless connection is active. Skipping private server restart to prevent disconnect.")
            return false
        }

        return await restartPrivateServer(reason: "Starting private server after releasing default USB owner.")
    }

    /// Runs `adb mdns services` with optional daemon recovery.
    /// Returns raw command tuple (exitCode, stdout, stderr).
    static func mdnsServicesWithRecovery(allowRecovery: Bool = true) async -> (Int32, String, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return (-1, "", "ADB not found") }

        func runOnce() async -> (Int32, String, String) {
            await Shell.runAsyncWithTimeout(adbPath, args: ["mdns", "services"], timeoutSeconds: 1.5)
        }

        func withBonjourFallback(_ result: (Int32, String, String)) async -> (Int32, String, String) {
            guard result.0 == 0 else { return result }
            
            // Get macOS Bonjour fallback services (highly stable)
            let bonjourOutput = await cachedBonjourADBServices()
            
            // If Bonjour is empty and ADB output is empty, return the original empty result
            if bonjourOutput.isEmpty && result.1.isEmpty {
                return result
            }
            
            // Merge lines from both adb mdns output and Bonjour output
            var mergedLines = [String]()
            var seenServiceNames = Set<String>()
            
            func addLines(_ rawOutput: String) {
                for line in rawOutput.split(separator: "\n") {
                    let str = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !str.isEmpty, !str.lowercased().hasPrefix("list of") else { continue }
                    
                    let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                    guard let serviceName = parts.first else { continue }
                    
                    // We key by serviceName if it starts with "adb-", or by the ip address if not
                    let key = serviceName.hasPrefix("adb-") ? serviceName : (parts.count >= 3 ? parts[2] : serviceName)
                    
                    if !seenServiceNames.contains(key) {
                        seenServiceNames.insert(key)
                        mergedLines.append(str)
                    }
                }
            }
            
            // Prioritize ADB's own results if they exist, then add Bonjour fallbacks
            addLines(result.1)
            addLines(bonjourOutput)
            
            let mergedOutput = "List of discovered mdns services\n" + mergedLines.joined(separator: "\n")
            
            let now = Date()
            if lastBonjourFallbackLogAt.map({ now.timeIntervalSince($0) > 10.0 }) ?? true {
                print("📶 ADB: Merged adb mdns services (\(result.1.split(separator: "\n").count - 1) lines) with macOS Bonjour fallback (\(bonjourOutput.split(separator: "\n").count) lines). Total unique: \(mergedLines.count)")
                lastBonjourFallbackLogAt = now
            }
            
            return (0, mergedOutput, result.2)
        }

        let first = await runOnce()
        let combinedLower = (first.1 + first.2).lowercased()
        let shouldRecover = allowRecovery && (first.0 != 0 || isProtocolError(combinedLower))
        if !shouldRecover {
            return await withBonjourFallback(first)
        }

        let now = Date()
        let canRecover: Bool = {
            guard let last = lastMDNSRecoveryAt else { return true }
            return now.timeIntervalSince(last) > 8.0
        }()
        guard canRecover else {
            return await withBonjourFallback(first)
        }

        lastMDNSRecoveryAt = now
        print("🔄 ADB: mDNS output empty/stale, restarting daemon and retrying mdns services...")
        let restarted = await restartServer()
        guard restarted else { return await withBonjourFallback(first) }
        try? await Task.sleep(nanoseconds: 800_000_000)
        return await withBonjourFallback(await runOnce())
    }

    private static func containsADBMDNSService(_ output: String) -> Bool {
        output.contains("_adb-tls-connect._tcp") || output.contains("_adb-tls-pairing._tcp")
    }

    private static func cachedBonjourADBServices() async -> String {
        let now = Date()
        if let cache = bonjourServicesCache, now.timeIntervalSince(cache.timestamp) < 4.0 {
            return cache.output
        }
        if let task = bonjourServicesTask {
            return await task.value
        }

        let task = Task { await bonjourADBServicesUncached() }
        bonjourServicesTask = task
        let output = await task.value
        bonjourServicesCache = (output, Date())
        bonjourServicesTask = nil
        return output
    }

    private static func bonjourADBServicesUncached() async -> String {
        let serviceTypes = ["_adb-tls-connect._tcp", "_adb-tls-pairing._tcp"]
        
        return await withTaskGroup(of: [String].self) { group in
            for serviceType in serviceTypes {
                group.addTask {
                    var serviceLines = [String]()
                    let browseOutput = await runDNSService(["-B", serviceType, "local"], seconds: 0.7)
                    let instances = parseDNSServiceBrowseInstances(from: browseOutput, serviceType: serviceType)
                    
                    // Resolve instances in parallel using a nested task group
                    await withTaskGroup(of: String?.self) { resolveGroup in
                        for instance in instances {
                            resolveGroup.addTask {
                                let lookupOutput = await runDNSService(["-L", instance, serviceType, "local"], seconds: 0.7)
                                if let resolved = parseDNSServiceLookup(lookupOutput) {
                                    let ipAddress = await resolveBonjourHost(resolved.host) ?? resolved.host
                                    return "\(instance)\t\(serviceType)\t\(ipAddress):\(resolved.port)\t\(resolved.host)"
                                }
                                return nil
                            }
                        }
                        for await line in resolveGroup {
                            if let line = line {
                                serviceLines.append(line)
                            }
                        }
                    }
                    return serviceLines
                }
            }
            
            var allLines = [String]()
            for await lines in group {
                allLines.append(contentsOf: lines)
            }
            return allLines.joined(separator: "\n")
        }
    }

    private static func runDNSService(_ args: [String], seconds: TimeInterval) async -> String {
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }

        let command = "/usr/bin/dns-sd " + args.map(shellQuote).joined(separator: " ")
        let script = "\(command) & pid=$!; sleep \(seconds); kill $pid >/dev/null 2>&1; wait $pid 2>/dev/null; true"
        let (_, output, error) = await Shell.runAsyncWithTimeout(
            "/bin/bash",
            args: ["-lc", script],
            timeoutSeconds: seconds + 2.0
        )
        return output + error
    }

    private static func parseDNSServiceBrowseInstances(from output: String, serviceType: String) -> [String] {
        var instances = Set<String>()
        let marker = serviceType + "."

        for line in output.components(separatedBy: .newlines) where line.contains(marker) && line.contains(" Add ") {
            guard let range = line.range(of: marker) else { continue }
            let instance = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !instance.isEmpty { instances.insert(instance) }
        }

        return Array(instances).sorted()
    }

    private static func parseDNSServiceLookup(_ output: String) -> (host: String, port: String)? {
        for line in output.components(separatedBy: .newlines) where line.contains(" can be reached at ") {
            guard let range = line.range(of: " can be reached at ") else { continue }
            let remainder = String(line[range.upperBound...])
            guard let hostPort = remainder.split(separator: " ").first else { continue }
            let parts = hostPort.split(separator: ":")
            guard parts.count >= 2, let port = parts.last else { continue }
            let host = parts.dropLast().joined(separator: ":").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !host.isEmpty else { continue }
            return (host, String(port))
        }
        return nil
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        value.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
    }

    private static func resolveBonjourHostNative(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &res)
        guard status == 0, let firstAddr = res else {
            return nil
        }
        defer { freeaddrinfo(res) }
        
        var ipAddress = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let sockaddr = firstAddr.pointee.ai_addr
        let socklen = firstAddr.pointee.ai_addrlen
        
        let getnameStatus = getnameinfo(sockaddr, socklen, &ipAddress, socklen_t(ipAddress.count), nil, 0, NI_NUMERICHOST)
        guard getnameStatus == 0 else {
            return nil
        }
        return String(cString: ipAddress)
    }

    private static func resolveBonjourHost(_ host: String) async -> String? {
        if let nativeIP = resolveBonjourHostNative(host) {
            return nativeIP
        }
        let output = await runDNSService(["-G", "v4", host], seconds: 1.0)
        for line in output.components(separatedBy: .newlines) where line.contains(" Add ") {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let address = parts.last, isIPv4Address(address) else {
                continue
            }
            return address
        }
        return nil
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
            // Strip \r — Samsung/modern devices send \r\n over ADB shell
            let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !cleanLine.isEmpty else { return }
            // Format: "<size> <relative/path/to/file>"
            let parts = cleanLine.split(separator: " ", maxSplits: 1)
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

    /// Returns the size (in bytes) of a single folder.
    /// Results are cached in memory — revisiting a folder is instant.
    static func fetchSingleFolderSize(path: String) async -> UInt64? {
        // Return from cache if already computed
        if let cached = folderSizeCache[path] {
            return cached
        }

        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return nil }

        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let command = "du -sk '\(escapedPath)' 2>/dev/null"
        
        // 8 second timeout per folder. Prevents huge folders like Android/data from blocking indefinitely.
        let (_, output, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", command]),
            timeoutSeconds: 8.0
        )

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 1)
        
        guard parts.count >= 1, let kb = UInt64(parts[0].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        
        let bytes = kb * 1024
        
        // Cache for instant revisit
        folderSizeCache[path] = bytes
        return bytes
    }

    /// Invalidates cached folder sizes.
    /// - Parameter path: If provided, clears only that folder path. If nil, clears entire cache.
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
        // Redirect stderr to stdout (2>&1) so we can detect Samsung/Android 15 silent
        // permission-denied responses that return exit code 0 with no output.
        let listCommand = "ls -1a '\(path)' 2>&1"
        
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
        // Strip \r from each name — Samsung devices (Android 12+) send \r\n over ADB shell.
        // Without this, filenames become "photo.jpg\r" and stat/find can't locate them,
        // causing the folder to appear empty even when files exist.
        var fileNames: [String] = []
        output.enumerateLines { name, _ in
            let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            // Skip . and .. and empty lines
            guard !cleanName.isEmpty && cleanName != "." && cleanName != ".." else { return }
            // Skip permission-denied lines that ended up in stdout (from 2>&1)
            guard !cleanName.hasPrefix("ls:") && !cleanName.contains("Permission denied") else { return }
            fileNames.append(cleanName)
        }
        
        if fileNames.isEmpty {
            // Detect Android 12+ / Samsung One UI scoped-storage silent permission denial:
            // `ls` returns exit 0 but the output contains a permission error or is truly empty.
            // Try the content:// media provider as a fallback for DCIM paths.
            let isDCIM = path.contains("/DCIM") || path.contains("/Pictures") || path.contains("/Movies")
            if isDCIM {
                let permissionError = output.contains("Permission denied") || output.contains("Operation not permitted")
                if permissionError {
                    print("⚠️ ADB: Permission denied for \(path) — trying content:// media fallback")
                }
                let mediaFiles = await listMediaFiles(dcimPath: path, adbPath: adbPath)
                if !mediaFiles.isEmpty {
                    print("📷 ADB: content:// fallback returned \(mediaFiles.count) files for \(path)")
                    return mediaFiles
                }
            }
            return []
        }
        
        // For small directories, use ls -la to get full details
        if fileNames.count <= 100 {
            return try await listFilesWithDetails(path: path, adbPath: adbPath, exactNames: fileNames)
        }
        
        // For large directories, use stat in batches.
        // NOTE: Samsung toybox `find` does NOT support -printf, so the previous
        // `find -printf` approach silently returned empty output on Samsung devices.
        // Stat-based batching is universally supported (Android 7+ toybox & busybox).
        var files: [ADBFile] = []
        files.reserveCapacity(fileNames.count)
        
        let statFiles = await listFilesViaStat(path: path, adbPath: adbPath, exactNames: fileNames)
        if statFiles.count == fileNames.count {
            return statFiles
        }
        
        // stat missed some files — supplement with ls -la
        let lsFiles = await listFilesViaLs(path: path, adbPath: adbPath, exactNames: fileNames)
        if lsFiles.count > statFiles.count {
            let lsNames = Set(lsFiles.map { $0.name })
            var merged = lsFiles
            for f in statFiles where !lsNames.contains(f.name) { merged.append(f) }
            if merged.count == fileNames.count { return merged }
            return fillMissing(from: fileNames, existing: merged, basePath: path)
        }
        
        if !statFiles.isEmpty {
            return fillMissing(from: fileNames, existing: statFiles, basePath: path)
        }
        if !lsFiles.isEmpty {
            return fillMissing(from: fileNames, existing: lsFiles, basePath: path)
        }
        
        // Final fallback: names only (no metadata)
        return fillMissing(from: fileNames, existing: [], basePath: path)
    }
    
    // MARK: - content:// Media Provider fallback (Android 12+ / Samsung scoped storage)
    
    /// Fallback for DCIM/Camera on Android 12+ where direct `ls` may be silently
    /// blocked by scoped storage / Samsung One UI SELinux policy.
    /// Queries the Android MediaStore content provider which is always accessible over ADB.
    private static func listMediaFiles(dcimPath: String, adbPath: String) async -> [ADBFile] {
        // Determine media type from path
        let isVideo = dcimPath.lowercased().contains("video") || dcimPath.lowercased().contains("movies")
        let uri = isVideo
            ? "content://media/external/video/media"
            : "content://media/external/images/media"
        
        // Also query videos if in a generic DCIM path
        let uris: [String] = dcimPath.lowercased().contains("dcim")
            ? ["content://media/external/images/media", "content://media/external/video/media"]
            : [uri]
        
        var allFiles: [ADBFile] = []
        
        for queryUri in uris {
            let cmd = "content query --uri \(queryUri) --projection _display_name,_size,date_modified,_data 2>/dev/null"
            let (code, output, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", cmd]), timeoutSeconds: 30.0
            )
            guard code == 0, !output.isEmpty else { continue }
            
            output.enumerateLines { line, _ in
                // Each row: "Row: N _display_name=foo.jpg, _size=1234, date_modified=1700000000, _data=/storage/.../foo.jpg"
                let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard cleanLine.hasPrefix("Row:") else { return }
                
                // Filter to only files whose _data path matches dcimPath
                guard cleanLine.contains(dcimPath) else { return }
                
                // Parse _data (full device path)
                guard let dataRange = cleanLine.range(of: "_data=") else { return }
                let dataAndRest = String(cleanLine[dataRange.upperBound...])
                let dataPath = dataAndRest.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                guard !dataPath.isEmpty else { return }
                let fileName = (dataPath as NSString).lastPathComponent
                
                // Parse _size
                var fileSize: UInt64 = 0
                if let sizeRange = cleanLine.range(of: "_size=") {
                    let sizeAndRest = String(cleanLine[sizeRange.upperBound...])
                    let sizeStr = sizeAndRest.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    fileSize = UInt64(sizeStr) ?? 0
                }
                
                // Parse date_modified (Unix timestamp)
                var modDate: Date? = nil
                if let dateRange = cleanLine.range(of: "date_modified=") {
                    let dateAndRest = String(cleanLine[dateRange.upperBound...])
                    let dateStr = dateAndRest.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    if let ts = Double(dateStr) {
                        modDate = Date(timeIntervalSince1970: ts)
                    }
                }
                
                allFiles.append(ADBFile(
                    name: fileName,
                    path: dataPath,
                    isDirectory: false,
                    size: fileSize,
                    modificationDate: modDate
                ))
            }
        }
        
        return allFiles
    }
    
    // Helper for small directories — tries stat first (modern), falls back to ls -la (legacy)
    private static func listFilesWithDetails(path: String, adbPath: String, exactNames: [String]) async throws -> [ADBFile] {
        
        // ── Strategy 1: stat (modern Android 7+, toybox) ──────────────────
        // stat -c gives pipe-delimited output that's trivial to parse.
        let statFiles = await listFilesViaStat(path: path, adbPath: adbPath, exactNames: exactNames)
        if statFiles.count == exactNames.count {
            return statFiles                       // stat worked for every file
        }
        
        // ── Strategy 2: ls -la (legacy fallback for old phones) ───────────
        // Only attempt this if stat missed some/all files.
        let lsFiles = await listFilesViaLs(path: path, adbPath: adbPath, exactNames: exactNames)
        if lsFiles.count > statFiles.count {
            // ls -la recovered more files — use it, but supplement with stat
            // results for any files ls may have missed.
            let lsNames = Set(lsFiles.map { $0.name })
            var merged = lsFiles
            for f in statFiles where !lsNames.contains(f.name) {
                merged.append(f)
            }
            if merged.count == exactNames.count { return merged }
            // Still missing some — fall through to raw fallback
            return fillMissing(from: exactNames, existing: merged, basePath: path)
        }
        
        // stat was better (or both equally incomplete) — supplement stat
        if !statFiles.isEmpty {
            return fillMissing(from: exactNames, existing: statFiles, basePath: path)
        }
        if !lsFiles.isEmpty {
            return fillMissing(from: exactNames, existing: lsFiles, basePath: path)
        }
        
        // ── Strategy 3: raw names fallback (nothing else worked) ──────────
        return fillMissing(from: exactNames, existing: [], basePath: path)
    }
    
    // MARK: - stat-based listing (modern)
    private static func listFilesViaStat(path: String, adbPath: String, exactNames: [String]) async -> [ADBFile] {
        var files: [ADBFile] = []
        let batchSize = 50
        for i in stride(from: 0, to: exactNames.count, by: batchSize) {
            let end = min(i + batchSize, exactNames.count)
            let batch = Array(exactNames[i..<end])
            
            let escapedArgs = batch.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
            let command = "cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))' && stat -c '%A|%s|%Y|%n' \(escapedArgs) 2>/dev/null"
            
            let (code, output, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 30.0
            )
            guard code == 0 else { continue }
            
            output.enumerateLines { line, _ in
                // Strip \r — Samsung/Android 12+ ADB sends \r\n line endings
                let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                let parts = cleanLine.split(separator: "|", maxSplits: 3)
                guard parts.count == 4 else { return }
                let perms = String(parts[0])
                let size  = UInt64(parts[1]) ?? 0
                let ts    = Double(parts[2])
                let name  = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                let isDir = perms.hasPrefix("d")
                let modDate = ts.map { Date(timeIntervalSince1970: $0) }
                let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
            }
        }
        return files
    }
    
    // MARK: - ls -la based listing (legacy)
    private static func listFilesViaLs(path: String, adbPath: String, exactNames: [String]) async -> [ADBFile] {
        let command = "ls -la '\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
        let (code, output, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 60.0
        )
        guard code == 0 else { return [] }
        
        var files: [ADBFile] = []
        let lines = output.components(separatedBy: "\n")
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        for exactName in exactNames {
            // Find the line ending with this exact name
            guard let lineStr = lines.first(where: {
                $0.hasSuffix(" " + exactName) || $0.hasSuffix(" " + exactName + "\r")
            }) else { continue }
            
            let cleanLine = lineStr.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let parts = cleanLine.split(whereSeparator: { $0.isWhitespace })
            // Android ls -la outputs 7 or 8 columns depending on device/version
            guard parts.count >= 7 else { continue }
            
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            
            // Find the date columns (YYYY-MM-DD HH:MM) to anchor the layout
            var dateIndex: Int? = nil
            for idx in 3..<(parts.count - 1) {
                let candidate = String(parts[idx])
                if candidate.count == 10 && candidate.contains("-") {
                    let next = String(parts[idx + 1])
                    if next.count == 5 && next.contains(":") {
                        dateIndex = idx
                        break
                    }
                }
            }
            
            var size: UInt64 = 0
            var modDate: Date? = nil
            
            if let di = dateIndex {
                // Size is the column immediately before the date
                if di > 0 { size = UInt64(parts[di - 1]) ?? 0 }
                let dateStr = "\(parts[di]) \(parts[di + 1])"
                modDate = dateFormatter.date(from: dateStr)
            } else {
                // Couldn't find date — try column 4 as size (standard 8-col layout)
                if parts.count >= 8 { size = UInt64(parts[4]) ?? 0 }
            }
            
            let fullPath = path.hasSuffix("/") ? path + exactName : path + "/" + exactName
            files.append(ADBFile(name: exactName, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
        }
        return files
    }
    
    // MARK: - Raw-name fallback (guarantees no files are lost)
    private static func fillMissing(from exactNames: [String], existing: [ADBFile], basePath: String) -> [ADBFile] {
        let parsed = Set(existing.map { $0.name })
        var result = existing
        for name in exactNames where !parsed.contains(name) {
            let fullPath = basePath.hasSuffix("/") ? basePath + name : basePath + "/" + name
            let isDir = !name.contains(".")
            result.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: 0, modificationDate: nil))
        }
        return result
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
    ) -> AsyncThrowingStream<(UInt64, Double), Error> {
        return AsyncThrowingStream { continuation in
            let adbPath = getADBPath()
            
            DispatchQueue.global(qos: .userInitiated).async {
                // Create and manage the process directly for cancellation support
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = deviceArgs(["push", localPath, devicePath])
                process.environment = Shell.adbEnvironment
                process.standardOutput = stdout
                process.standardError = stderr
                
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

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""

                    if process.terminationStatus == 0 {
                        if !cancellationCheck() {
                            continuation.yield((totalBytes, 0))
                        }
                        continuation.finish()
                    } else {
                        let message = (error.isEmpty ? output : error).trimmingCharacters(in: .whitespacesAndNewlines)
                        print("❌ ADB Push exited with code \(process.terminationStatus): \(message)")
                        continuation.finish(throwing: NSError(
                            domain: "ADBPush",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Upload failed" : message]
                        ))
                    }
                    
                } catch {
                    print("❌ ADB Push Error: \(error)")
                    continuation.finish(throwing: error)
                }
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
    static func connectWireless(ip: String, port: String = "5555", hostname: String? = nil) async -> (Bool, String, String?) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else {
            return (false, "ADB not found", nil)
        }

        // Build an ordered list of connect targets.
        // Wireless debugging ports rotate frequently. After pairing, the connect
        // service can take a few seconds to appear, so we poll mdns services
        // briefly before falling back to the caller-provided port.
        func buildTargets() async -> [String] {
            var targets: [String] = []
            var seen = Set<String>()

            func appendTarget(_ value: String?) {
                guard let value, !value.isEmpty else { return }
                if !seen.contains(value) {
                    seen.insert(value)
                    targets.append(value)
                }
            }

            // 1) Most stable on ADB 37+ is hostname + port.
            if let host = hostname, !host.isEmpty {
                appendTarget("\(host):\(port)")
            }

            // 2) Direct IP + provided port.
            appendTarget("\(ip):\(port)")

            // 3) Ask adb mdns services for fresh connect endpoints for this device.
            // Poll briefly because _adb-tls-connect often appears a bit later than pairing.
            var foundDynamicTarget = false
            for attempt in 1...8 {
                let (mdnsCode, mdnsOutput, _) = await mdnsServicesWithRecovery(allowRecovery: false)
                if mdnsCode == 0 {
                    let lines = mdnsOutput.split(separator: "\n").map(String.init)
                    for line in lines where line.contains("_adb-tls-connect._tcp") {
                        let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)

                        let lineServiceName: String? = parts.first.flatMap { $0.hasPrefix("adb-") ? $0 : nil }
                        let lineIPPort: String? = parts.first(where: { item in
                            let comps = item.split(separator: ":")
                            return comps.count >= 2 && UInt16(comps.last ?? "") != nil
                        })
                        let lineHost: String? = parts.last.flatMap { $0.hasSuffix(".local") ? $0 : nil }

                        let serviceMatch = (hostname != nil && lineHost == hostname) || (lineServiceName != nil && lineHost == hostname)
                        let ipMatch = lineIPPort?.hasPrefix(ip + ":") == true
                        guard serviceMatch || ipMatch else { continue }

                        foundDynamicTarget = true
                        if let host = lineHost, let portPart = lineIPPort?.split(separator: ":").last {
                            appendTarget("\(host):\(portPart)")
                        }
                        appendTarget(lineIPPort)
                    }
                }
                if foundDynamicTarget { break }
                if attempt < 8 {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                }
            }

            // 4) Last resort legacy port. Only use this for manual IP flows; mDNS hostnames
            // already gave us the current Android 11+ wireless debugging port.
            if hostname == nil && port != "5555" {
                appendTarget("\(ip):5555")
            }
            return targets
        }

        // Helper: attempt a single adb connect and return whether it succeeded
        func attempt(target: String) async -> (Bool, String) {
            print("📶 ADB: Connecting to \(target)...")
            var (exitCode, output, error) = await Shell.runAsyncWithTimeout(
                adbPath, args: ["connect", target], timeoutSeconds: 10.0
            )
            var combined = output + error
            print("📶 ADB Connect result: code=\(exitCode), output=\(combined)")

            // Auto-recover from stale protocol state.
            if isProtocolError(combined) {
                print("🔄 ADB: Protocol fault during connect, restarting server and retrying...")
                let restarted = await restartServer()
                if restarted {
                    (exitCode, output, error) = await Shell.runAsyncWithTimeout(
                        adbPath, args: ["connect", target], timeoutSeconds: 10.0
                    )
                    combined = output + error
                    print("📶 ADB Connect retry result: code=\(exitCode), output=\(combined)")
                }
            }

            let lower = combined.lowercased()
            if lower.contains("connected to") || lower.contains("already connected") {
                return (true, combined)
            }
            if lower.contains("cannot connect") || lower.contains("failed") {
                return (false, combined)
            }
            return (exitCode == 0, combined)
        }

        let targets = await buildTargets()
        for target in targets {
            let (success, _) = await attempt(target: target)
            if success {
                return (true, "Connected to \(target)", target)
            }
        }
        return (false, "Cannot connect to \(ip). Make sure Wireless Debugging is enabled and re-open 'Pair device with pairing code'.", nil)
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
        
        // 1. Explicitly disconnect each wireless device in the active devices list.
        // Some adb versions fail to clean up Bonjour/mDNS serials on a bare "disconnect" command.
        let connectedDevices = await listAllConnectedDevices()
        var explicitDisconnectResults = [String]()
        for dev in connectedDevices {
            if dev.isWireless {
                print("📱 ADB: Explicitly disconnecting wireless serial: \(dev.serial)")
                let (_, out, err) = await Shell.runAsyncWithTimeout(
                    adbPath,
                    args: ["disconnect", dev.serial],
                    timeoutSeconds: 3.0
                )
                explicitDisconnectResults.append(out + err)
            }
        }
        
        // 2. Perform the general sweep disconnect
        let (exitCode, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["disconnect"],
            timeoutSeconds: 5.0
        )
        
        let combinedOutput = output + error + "\n" + explicitDisconnectResults.joined(separator: "\n")
        let result = (exitCode == 0, combinedOutput)
        
        // Clear the active serial if it was a wireless device
        if let serial = activeDeviceSerial, isWirelessSerial(serial) {
            activeDeviceSerial = nil
        }
        return result
    }

    /// Disconnect only app-managed wireless sessions so we don't disturb other ADB clients.
    static func disconnectAppManagedWireless() async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }

        var targets = appManagedWirelessTargets
        if let active = activeDeviceSerial, isWirelessSerial(active) {
            targets.insert(active)
        }

        for target in targets {
            _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect", target], timeoutSeconds: 3.0)
        }
        appManagedWirelessTargets.removeAll()
    }

    /// Synchronous variant for app termination, so disconnect finishes before process exits.
    static func disconnectAppManagedWirelessSync() {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }

        var targets = appManagedWirelessTargets
        if let active = activeDeviceSerial, isWirelessSerial(active) {
            targets.insert(active)
        }

        for target in targets {
            _ = Shell.run(adbPath, args: ["disconnect", target])
        }
        appManagedWirelessTargets.removeAll()
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

    /// Extract hardware serial from an ADB 37+ mDNS service name (e.g. "adb-ZF622373WS-K6agbq" -> "ZF622373WS")
    static func extractHardwareSerial(from serviceName: String) -> String? {
        guard serviceName.hasPrefix("adb-") else { return nil }
        let components = serviceName.split(separator: "-")
        guard components.count >= 3 else { return nil }
        // Drop the first ("adb") and last (random suffix) parts
        let serialComponents = components.dropFirst().dropLast()
        let serial = serialComponents.joined(separator: "-")
        return serial.isEmpty ? nil : serial
    }

    /// Query the unique hardware serial of a connected device (USB or wireless)
    static func getHardwareSerial(for target: String) async -> String? {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return nil }
        let (_, out, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["-s", target, "get-serialno"],
            timeoutSeconds: 2.0
        )
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased().contains("error") || trimmed.lowercased().contains("unknown") {
            let (_, getpropOut, _) = await Shell.runAsyncWithTimeout(
                adbPath,
                args: ["-s", target, "shell", "getprop", "ro.serialno"],
                timeoutSeconds: 2.0
            )
            let getpropTrimmed = getpropOut.trimmingCharacters(in: .whitespacesAndNewlines)
            if !getpropTrimmed.isEmpty && !getpropTrimmed.lowercased().contains("error") && !getpropTrimmed.lowercased().contains("unknown") {
                return getpropTrimmed
            }
            return nil
        }
        return trimmed
    }

    /// Returns the IP of the wirelessly connected device, or nil.
    static func getWirelessIP() async -> String? {
        guard let active = activeDeviceSerial, isWirelessSerial(active) else { return nil }
        // Traditional serial: extract IP before the colon. ADB 37 Bonjour
        // targets can look like Android.local:45545, so only accept numeric IPv4 here.
        if active.contains(":"), let first = active.components(separatedBy: ":").first,
           isIPv4Address(first) {
            return first
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
