

// ADBManager.swift 

import Foundation

class ADBManager {
    // Cache the path so we don't search every time
    private static var adbPath: String?
    private static var hardwareSerialCache: [String: String] = [:]
    private static var wirelessConnectTasks: [String: Task<(success: Bool, output: String), Never>] = [:]

    private static let rememberedSerialsKey = "wirelessRememberedHardwareSerials"
    /// Endpoint details live only in this process; automatic recovery persists identities.
    private static var currentWirelessEndpoints: [String: RememberedWirelessDevice] = [:]

    static var rememberedWirelessSerials: [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: rememberedSerialsKey) { return saved }
        // Migrate the genuine identities, not the accumulated IP:port history.
        let legacyRecords = UserDefaults.standard.data(forKey: "wirelessDeviceIdentities")
            .flatMap { try? JSONDecoder().decode([RememberedWirelessDevice].self, from: $0) } ?? []
        let legacySerials = UserDefaults.standard.stringArray(forKey: "connectedWirelessSerials") ?? []
        let identities = legacySerials.compactMap { serial -> String? in
            if serial.contains("._adb-tls-") { return extractHardwareSerial(from: serial) }
            return !serial.isEmpty && !isWirelessSerial(serial) && !serial.hasSuffix(".local") ? serial : nil
        }
        let saved = Array(Set(legacyRecords.map(\.hardwareSerial) + identities)).sorted()
        UserDefaults.standard.set(saved, forKey: rememberedSerialsKey)
        for key in ["wirelessDeviceIdentities", "connectedWirelessSerials", "connectedWirelessDevices",
                    "wirelessLastKnownTargetByIP", "wirelessLastKnownPortByIP"] {
            UserDefaults.standard.set(nil, forKey: key)
        }
        return saved
    }

    static var rememberedWirelessDevices: [RememberedWirelessDevice] {
        rememberedWirelessSerials.map {
            currentWirelessEndpoints[$0] ?? RememberedWirelessDevice(hardwareSerial: $0, target: "", hostname: nil)
        }
    }

    static func rememberWirelessDevice(target: String, hardwareSerial: String, hostname: String? = nil) {
        guard isWirelessSerial(target), !hardwareSerial.isEmpty, !isWirelessSerial(hardwareSerial) else { return }
        let serials = Array(Set(rememberedWirelessSerials + [hardwareSerial])).sorted()
        UserDefaults.standard.set(serials, forKey: rememberedSerialsKey)
        currentWirelessEndpoints[hardwareSerial] = RememberedWirelessDevice(hardwareSerial: hardwareSerial,
            target: target, hostname: hostname ?? currentWirelessEndpoints[hardwareSerial]?.hostname)
    }

    static func forgetWirelessDevice(hardwareSerial: String) {
        let serials = rememberedWirelessSerials.filter { $0 != hardwareSerial }
        UserDefaults.standard.set(serials, forKey: rememberedSerialsKey)
        currentWirelessEndpoints.removeValue(forKey: hardwareSerial)
        hardwareSerialCache = hardwareSerialCache.filter { $0.value != hardwareSerial }
    }

    // Cache folder sizes: [folderPath: sizeInBytes]
    // Populated lazily by fetchSingleFolderSize, returned instantly on revisit.
    private static var folderSizeCache: [String: UInt64] = [:]
    
    // Track the active device serial for multi-device support
    static var activeDeviceSerial: String?
    
    /// Set to true while `pairDevice()` is running.
    /// `restartServer()` checks this flag and skips the restart to avoid
    /// killing the ADB TLS stack mid-handshake, which produces:
    ///   "protocol fault (couldn't read status message): Undefined error: 0"
    static var isPairingInProgress = false
    
    // Track if we've already attempted a server restart this session
    private static var hasRestarted = false
    /// Cooldown for mDNS recovery restarts so we don't thrash ADB daemon.
    private static var lastMDNSRecoveryAt: Date?
    /// Wireless endpoints this app connected to in current session.
    private static var appManagedWirelessTargets = Set<String>()
    /// ADB mDNS can be empty while Bonjour works. Cache the fallback briefly so UI actions
    /// don't spawn multiple dns-sd browse/lookup/resolve commands per second.
    private static var bonjourServicesCache: (output: String, timestamp: Date)?
    private static var pairingProbeCache: (serviceName: String, output: String, timestamp: Date)?
    private static var bonjourServicesTask: Task<String, Never>?
    private static var lastBonjourFallbackLogAt: Date?
    private static var restartServerTask: Task<Bool, Never>?
    private static var lastServerRestartAttemptAt: Date?
    
    /// Returns args with -s <serial> prepended if a device serial is set
    static func deviceArgs(_ args: [String]) -> [String] {
        if let serial = activeDeviceSerial {
            return ["-P", String(Shell.serverPortBySerial[serial] ?? (Shell.useDefaultServer ? 5037 : Shell.appADBServerPort)), "-s", serial] + args
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
            guard isWireless else { return nil }
            return WirelessEndpoint.address(from: serial)?.host
        }
        
        var derivedHardwareSerial: String? {
            // Metadata can finish after this snapshot was read. Consult the
            // verified identity cache before treating a live IP transport as missing.
            if let hw = hardwareSerial ?? ADBManager.hardwareSerialCache[serial], !hw.isEmpty { return hw }
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

    /// Read both server snapshots concurrently. Device metadata must not delay the first UI update.
    /// Remember the owning server per serial so listing a second server cannot reroute a transfer.
    static func listAllConnectedDevices(
        onUpdate: (@MainActor ([ConnectedDevice], Set<Int>) async -> Void)? = nil
    ) async -> [ConnectedDevice] {
        let path = getADBPath()
        guard !path.isEmpty, !Task.isCancelled else { return [] }
        let sharedServerRunning = Shell.isDefaultServerRunning()
        let ports = sharedServerRunning
            ? (Shell.isADBServerRunning(port: Shell.appADBServerPort) ? [Shell.appADBServerPort, 5037] : [5037])
            : [Shell.appADBServerPort]
        return await withTaskGroup(of: (Int, String).self) { group in
            for port in ports {
                group.addTask {
                    let (code, output, _) = await Shell.runAsyncWithTimeout(path,
                        args: ["devices", "-l"], timeoutSeconds: 2,
                        environment: Shell.serverEnvironment(port: port))
                    return (port, code == 0 ? output : "")
                }
            }
            var snapshots: [(Int, String)] = []
            var devices: [ConnectedDevice] = []
            let previousOwners = Shell.serverPortBySerial
            for await snapshot in group {
                guard !Task.isCancelled else { group.cancelAll(); return [] }
                snapshots.append(snapshot)
                devices = mergeDeviceSnapshots(snapshots, previousOwners: previousOwners)
                // Publish a usable transport without waiting for an unrelated daemon.
                if devices.contains(where: { $0.status == "device" }) {
                    await onUpdate?(devices, Set(snapshots.map(\.0)))
                }
            }
            return devices
        }
    }

    private static func mergeDeviceSnapshots(_ snapshots: [(Int, String)], previousOwners: [String: Int]) -> [ConnectedDevice] {
        var devices: [ConnectedDevice] = []
        let names = UserDefaults.standard.dictionary(forKey: "wirelessDisplayNameBySerial") as? [String: String] ?? [:]
        for (port, output) in snapshots.sorted(by: { $0.0 == Shell.appADBServerPort && $1.0 != Shell.appADBServerPort }) {
            for line in output.split(separator: "\n") {
                let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.count >= 2, ["device", "offline", "unauthorized"].contains(parts[1]) else { continue }
                let serial = parts[0]
                if let existing = devices.firstIndex(where: { $0.serial == serial }) {
                    let oldReady = devices[existing].status == "device"
                    let newReady = parts[1] == "device"
                    // A stale previous owner must never replace a ready transport.
                    if oldReady && !newReady { continue }
                    if oldReady == newReady && previousOwners[serial] != port { continue }
                    devices.remove(at: existing)
                }
                Shell.serverPortBySerial[serial] = port
                let hw = hardwareSerialCache[serial] ?? (isWirelessSerial(serial) ? extractHardwareSerial(from: serial) : serial)
                let model = parts.first(where: { $0.hasPrefix("model:") }).map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
                let name = hw.flatMap { names[$0] } ?? model ?? serial
                devices.append(ConnectedDevice(serial: serial, displayName: name, status: parts[1], hardwareSerial: hw))
            }
        }
        if let active = activeDeviceSerial, let port = Shell.serverPortBySerial[active] {
            Shell.useDefaultServer = port == 5037
        } else if let first = devices.first(where: { $0.status == "device" }) ?? devices.first {
            Shell.useDefaultServer = Shell.serverPortBySerial[first.serial] == 5037
        }
        return devices
    }

    /// Switch the active target device. Triggers a DeviceManager re-detect to update all state.
    static func switchToDevice(serial: String) {
        activeDeviceSerial = serial
        if let port = Shell.serverPortBySerial[serial] { Shell.useDefaultServer = port == 5037 }
        print("📱 ADB: Switched active device to \(serial)")
    }

    static func markAppManagedWirelessTarget(_ target: String) {
        guard isWirelessSerial(target) else { return }
        appManagedWirelessTargets.insert(target)
    }
    
    // MARK: - ADB Server Management
    
    /// Checks if ADB output indicates a protocol fault or stale server.
    /// Used by both `pairDevice()` and `QRPairingService` to detect transient
    /// ADB daemon failures that can be recovered with a server restart + retry.
    static func isProtocolError(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("protocol fault") ||
               lower.contains("couldn't read status") ||
               lower.contains("cannot connect to daemon") ||
               lower.contains("adb server didn't ack") ||
               lower.contains("adb server version") ||
               lower.contains("kill-server")
    }

    /// Returns true only when ADB explicitly reports that the saved TLS identity is
    /// no longer authorized. Network failures such as "No route to host", timeouts,
    /// or a sleeping phone are transient and must not erase a remembered pairing.
    static func wirelessConnectionRequiresRepair(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("failed to authenticate") ||
               lower.contains("authentication failed") ||
               lower.contains("device unauthorized") ||
               lower.contains("unauthorized device")
    }

    /// Only definitive endpoint/identity failures quarantine an advertisement.
    /// A timeout can mean the phone's TLS or shell service is still waking up.
    static func shouldRejectWirelessEndpoint(_ output: String) -> Bool {
        let lower = output.lowercased()
        return lower.contains("refused") || lower.contains("host is down") || lower.contains("no route") ||
            wirelessConnectionRequiresRepair(output) || lower.contains("identity did not match")
    }

    /// Connects to one wireless ADB endpoint and verifies that it can execute a
    /// command. `adb connect` can return exit code 0 (and can even say "already
    /// connected") for a stale transport, so its response alone is not proof that
    /// the device is usable.
    static func connectAndVerifyWirelessTarget(
        _ target: String, connectTimeout: Double = 5.0, verificationAttempts: Int = 3,
        expectedHardwareSerial: String? = nil, refreshStaleTransport: Bool = true
    ) async -> (success: Bool, output: String) {
        guard !Task.isCancelled, !isPairingInProgress else { return (false, "Connection cancelled or pairing in progress") }
        let port = Shell.serverPortBySerial[target] ?? (Shell.useDefaultServer ? 5037 : Shell.appADBServerPort)
        Shell.serverPortBySerial[target] = port
        let key = "\(port)/\(target)/\(expectedHardwareSerial ?? "")"
        if let task = wirelessConnectTasks[key] { return await task.value }
        let task = Task {
            await performWirelessConnect(target, serverPort: port, connectTimeout: connectTimeout,
                verificationAttempts: verificationAttempts, expectedHardwareSerial: expectedHardwareSerial,
                refreshStaleTransport: refreshStaleTransport)
        }
        wirelessConnectTasks[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        wirelessConnectTasks.removeValue(forKey: key)
        guard !Task.isCancelled else { return (false, "Connection cancelled") }
        if result.success {
            WirelessDiscovery.shared.verified(target: target)
            if let address = WirelessEndpoint.address(from: target) {
                ADBPairingBrowser.needsRepairing.remove(address.host)
            }
        } else {
            if shouldRejectWirelessEndpoint(result.output) {
                WirelessDiscovery.shared.invalidate(target: target)
            }
            // Keep the current native advertisement after a timeout. A continuous
            // Bonjour resolver need not emit the unchanged address a second time.
            bonjourServicesCache = nil
        }
        return result
    }

    private static func performWirelessConnect(
        _ target: String, serverPort: Int, connectTimeout: Double, verificationAttempts: Int,
        expectedHardwareSerial: String?, refreshStaleTransport: Bool
    ) async -> (success: Bool, output: String) {
        let path = getADBPath()
        guard !path.isEmpty else { return (false, "ADB not found") }
        let environment = Shell.serverEnvironment(port: serverPort)
        var messages: [String] = []
        for attempt in 1...(refreshStaleTransport ? 2 : 1) {
            guard !Task.isCancelled, !isPairingInProgress else { return (false, "Connection cancelled or pairing in progress") }
            let (code, out, err) = await Shell.runAsyncWithTimeout(path, args: ["connect", target],
                timeoutSeconds: connectTimeout, environment: environment)
            let text = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
            messages.append(text)
            guard !Task.isCancelled else { return (false, "Connection cancelled") }
            let lower = text.lowercased()
            guard code == 0, lower.contains("connected to") || lower.contains("already connected") else {
                return (false, messages.joined(separator: "\n"))
            }
            for verification in 1...max(1, verificationAttempts) {
                guard !Task.isCancelled else { return (false, "Connection cancelled") }
                let (verifyCode, verifyOut, verifyErr) = await Shell.runAsyncWithTimeout(path,
                    args: ["-s", target, "shell", "echo afs-connected; getprop ro.serialno; getprop ro.boot.serialno"],
                    timeoutSeconds: min(3, max(1, connectTimeout)), environment: environment)
                guard !Task.isCancelled else { return (false, "Connection cancelled") }
                let lines = verifyOut.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                if verifyCode == 0, lines.first == "afs-connected" {
                    let identity = lines.dropFirst().first { !$0.isEmpty && $0 != "unknown" && !isWirelessSerial($0) }
                    if let expectedHardwareSerial, identity != expectedHardwareSerial {
                        return (false, "Device identity did not match remembered device")
                    }
                    if let identity {
                        hardwareSerialCache[target] = identity
                        rememberWirelessDevice(target: target, hardwareSerial: identity,
                            hostname: WirelessDiscovery.shared.endpoints.first { $0.target == target }?.hostname)
                    }
                    markAppManagedWirelessTarget(target)
                    return (true, messages.joined(separator: "\n"))
                }
                messages.append((verifyOut + verifyErr).trimmingCharacters(in: .whitespacesAndNewlines))
                if verification < max(1, verificationAttempts) { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            guard attempt == 1, refreshStaleTransport, !Task.isCancelled else { break }
            _ = await Shell.runAsyncWithTimeout(path, args: ["disconnect", target],
                timeoutSeconds: 1, environment: environment)
        }
        return (false, messages.joined(separator: "\n"))
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

        // Do NOT restart the server if we are in shared mode (port 5037) or if a device is connected.
        // Doing so will disrupt Android Studio or disconnect the active session.
        if Shell.useDefaultServer {
            print("🔄 ADB: Server restart skipped — app is in shared mode (port 5037).")
            return false
        }
        if activeDeviceSerial != nil {
            print("🔄 ADB: Server restart skipped — a device is currently connected (\(activeDeviceSerial!)).")
            return false
        }

        // Do NOT restart the server while a pairing handshake is in flight.
        // Killing the ADB daemon during an active TLS pairing session causes:
        //   "protocol fault (couldn't read status message): Undefined error: 0"
        // which makes the first pairing attempt fail every time.
        if isPairingInProgress {
            print("🔄 ADB: Restart skipped — pairing is currently in progress.")
            return false
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
                path, args: ["kill-server"], timeoutSeconds: 2.0, environment: Shell.adbEnvironment
            )
            print("🔄 ADB: kill-server result: code=\(killCode), error=\(killError)")

            guard !Task.isCancelled, !isPairingInProgress, activeDeviceSerial == nil else { return false }

            let (startCode, startOutput, startError) = await Shell.runAsyncWithTimeout(
                path, args: ["start-server"], timeoutSeconds: 3.0, environment: Shell.adbEnvironment
            )
            print("🔄 ADB: start-server result: code=\(startCode), output=\(startOutput), error=\(startError)")

            let success = startCode == 0 || startError.lowercased().contains("started successfully")
            print("🔄 ADB: Server restart \(success ? "✅ succeeded" : "❌ failed")")
            hasRestarted = true
            return success
        }

        restartServerTask = task
        let success = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
                timeoutSeconds: 3.0, environment: Shell.adbEnvironment
            )

            try? await Task.sleep(nanoseconds: 700_000_000)

            let (startCode, startOutput, startError) = await Shell.runAsyncWithTimeout(
                path,
                args: ["start-server"],
                timeoutSeconds: 6.0, environment: Shell.adbEnvironment
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
            timeoutSeconds: 3.0,
            environment: Shell.adbEnvironment
        )
        if privateOutput.contains(" usb:") {
            return false
        }

        guard Shell.isDefaultServerRunning() else { return false }
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
                timeoutSeconds: 2.0,
                environment: Shell.adbEnvironment
            )
            if postKillOutput.contains(" usb:") {
                print("🔄 ADB: Private server automatically claimed the USB transport after \(Double(attempt) * 0.5)s.")
                claimed = true
                break
            }
        }
        
        if claimed {
            Shell.useDefaultServer = false
            return true
        }

        // Fallback: If it didn't auto-detect, restart the private server, BUT only if there's no active wireless connection or if we are forcing it.
        if !forceRestart, let activeSerial = activeDeviceSerial, isWirelessSerial(activeSerial) {
            print("🔄 ADB: Private server did not auto-claim USB after polling, but wireless connection is active. Skipping private server restart to prevent disconnect.")
            return false
        }

        let restarted = await restartPrivateServer(reason: "Starting private server after releasing default USB owner.")
        if restarted {
            Shell.useDefaultServer = false
        }
        
        // Last resort: if our private server still doesn't have the USB device (e.g. Android Studio
        // auto-respawned its server), fall back to coexistence mode so the user can still use the app.
        if restarted {
            let (_, checkOutput, _) = await Shell.runAsyncWithTimeout(
                path, args: ["devices", "-l"], timeoutSeconds: 2.0, environment: Shell.adbEnvironment
            )
            if !checkOutput.contains(" usb:") {
                let (_, defaultCheck, _) = await Shell.runAsyncWithTimeout(
                    path, args: ["devices", "-l"], timeoutSeconds: 2.0, environment: Shell.defaultADBEnvironment
                )
                if defaultCheck.contains(" usb:") {
                    print("🔄 ADB Coexistence: Private server could not claim USB (likely reclaimed by another app). Switching to shared mode.")
                    Shell.useDefaultServer = true
                    return true
                }
            }
        }
        
        return restarted
    }

    /// Runs `adb mdns services` with optional daemon recovery.
    /// Returns raw command tuple (exitCode, stdout, stderr).
    static func mdnsServicesWithRecovery(allowRecovery: Bool = true,
        requiredPairingService: String? = nil) async -> (Int32, String, String) {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return (-1, "", "ADB not found") }

        WirelessDiscovery.shared.start()
        func satisfiesRequest(_ output: String) -> Bool {
            guard let requiredPairingService else { return containsADBMDNSService(output) }
            return WirelessEndpoint.parse(output).contains {
                $0.serviceType == "_adb-tls-pairing._tcp" && $0.serviceName == requiredPairingService
            }
        }
        let native = WirelessDiscovery.shared.endpoints.map(\.outputLine).joined(separator: "\n")
        // A connect service (or another phone's pairing service) does not satisfy
        // a QR lookup. Keep querying ADB until this QR's service is resolved.
        if satisfiesRequest(native) { return (0, "List of discovered mdns services\n" + native, "") }
        func runOnce() async -> (Int32, String, String) {
            await Shell.runAsyncWithTimeout(adbPath, args: ["mdns", "services"], timeoutSeconds: 1.5)
        }

        func withBonjourFallback(_ result: (Int32, String, String)) async -> (Int32, String, String) {
            WirelessDiscovery.shared.start()
            let nativeOutput = WirelessDiscovery.shared.endpoints.map(\.outputLine).joined(separator: "\n")
            let bonjourOutput: String
            if Task.isCancelled || satisfiesRequest(nativeOutput) || (result.0 == 0 && satisfiesRequest(result.1)) {
                bonjourOutput = nativeOutput
            } else {
                async let direct = directPairingServices(serviceName: requiredPairingService)
                let fallback = await cachedBonjourADBServices()
                bonjourOutput = nativeOutput + "\n" + fallback + "\n" + (await direct)
            }
            
            // If Bonjour is empty and ADB output is empty, return the original empty result
            if bonjourOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (result.0 != 0 || result.1.isEmpty) {
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
                    
                    let type = parts.count >= 2 ? parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ".")) : ""
                    let key = serviceName + "/" + type
                    
                    if !seenServiceNames.contains(key) {
                        seenServiceNames.insert(key)
                        mergedLines.append(str)
                    }
                }
            }
            
            // A current native resolution takes precedence over an ADB snapshot.
            addLines(nativeOutput)
            if result.0 == 0 { addLines(result.1) }
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
        let shouldRecover = allowRecovery && !Shell.useDefaultServer && activeDeviceSerial == nil &&
            !Task.isCancelled && isProtocolError(combinedLower)
        if !shouldRecover {
            return await withBonjourFallback(first)
        }

        let now = Date()
        let canRecover: Bool = {
            guard let last = lastMDNSRecoveryAt else { return true }
            // 15s cooldown — reduces the chance that a background mDNS
            // recovery restart races with an active pairing or connect attempt.
            return now.timeIntervalSince(last) > 15.0
        }()
        guard canRecover else {
            return await withBonjourFallback(first)
        }

        lastMDNSRecoveryAt = now
        print("🔄 ADB: mDNS reported a daemon fault; restarting and retrying services...")
        let restarted = await restartServer()
        guard restarted else { return await withBonjourFallback(first) }
        return await withBonjourFallback(await runOnce())
    }

    private static func containsADBMDNSService(_ output: String) -> Bool {
        output.contains("_adb-tls-connect._tcp") || output.contains("_adb-tls-pairing._tcp")
    }

    private static func directPairingServices(serviceName: String?) async -> String {
        guard let serviceName, !Task.isCancelled else { return "" }
        if let cache = pairingProbeCache, cache.serviceName == serviceName,
           Date().timeIntervalSince(cache.timestamp) < 2 { return cache.output }
        let endpoints = await PairingMDNSProbe.discover(serviceName: serviceName)
        guard !Task.isCancelled else { return "" }
        let output = endpoints.map(\.outputLine).joined(separator: "\n")
        pairingProbeCache = (serviceName, output, Date())
        for endpoint in endpoints {
            AppLogger.log("📷 [QRPairing] source=mdns-direct-reply, service=\(serviceName), target=\(endpoint.target)")
        }
        return output
    }

    /// Resolve current connect services by hardware serial. No saved address is a candidate.
    static func discoverWirelessEndpoints(for serials: Set<String>,
        onEndpoint: (@MainActor (WirelessEndpoint) -> Void)? = nil) async -> (endpoints: [WirelessEndpoint], error: String) {
        guard !serials.isEmpty, !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return ([], "") }
        func matching(_ endpoints: [WirelessEndpoint]) -> [WirelessEndpoint] {
            endpoints.filter { $0.isConnectService && $0.hardwareSerial.map(serials.contains) == true &&
                WirelessDiscovery.shared.acceptsSnapshot($0) }
        }
        WirelessDiscovery.shared.start()
        let native = matching(WirelessDiscovery.shared.endpoints)
        var endpoints = native
        native.forEach { onEndpoint?($0) }
        var missing = serials.subtracting(native.compactMap(\.hardwareSerial))
        if missing.isEmpty { return (endpoints, "") }
        let (code, output, error) = await Shell.runAsyncWithTimeout(getADBPath(),
            args: ["mdns", "services"], timeoutSeconds: 1.5)
        let adbEndpoints = matching(WirelessEndpoint.parse(output))
        if code == 0 {
            adbEndpoints.forEach { WirelessDiscovery.shared.observeConnectEndpoint($0) }
            endpoints += adbEndpoints
            adbEndpoints.forEach { onEndpoint?($0) }
            missing.subtract(adbEndpoints.compactMap(\.hardwareSerial))
        }
        if missing.isEmpty { return (uniqueWirelessEndpoints(matching(endpoints)), "") }
        guard !Task.isCancelled else { return ([], "") }

        // Some ADB 37 installations have no working mDNS backend. Browse Bonjour
        // and resolve only names containing a remembered hardware serial.
        let type = "_adb-tls-connect._tcp"
        let browse = await runDNSService(["-B", type, "local."], seconds: 1.5)
        let names = parseDNSServiceBrowseInstances(from: browse, serviceType: type).filter {
            extractHardwareSerial(from: $0).map(missing.contains) == true
        }
        names.forEach { WirelessDiscovery.shared.observeConnectService(name: $0) }
        let deadline = Date().addingTimeInterval(names.isEmpty ? 0 : 2)
        var published = Set(endpoints.map(\.target))
        repeat {
            let freshNative = matching(WirelessDiscovery.shared.endpoints)
            for endpoint in freshNative where published.insert(endpoint.target).inserted { onEndpoint?(endpoint) }
            let nativeIDs = Set(freshNative.compactMap(\.hardwareSerial))
            // Replace older snapshots for identities that have a live native resolution.
            endpoints = uniqueWirelessEndpoints(freshNative + (code == 0 ? matching(adbEndpoints) : []).filter {
                $0.hardwareSerial.map { !nativeIDs.contains($0) } == true
            })
            if serials.isSubset(of: Set(endpoints.compactMap(\.hardwareSerial))) || Date() >= deadline { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        } while !Task.isCancelled
        return (matching(endpoints), code == 0 ? "" : error)
    }

    private static func uniqueWirelessEndpoints(_ endpoints: [WirelessEndpoint]) -> [WirelessEndpoint] {
        var seen = Set<String>()
        return endpoints.filter { seen.insert($0.target).inserted }
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
        let (_, output, error) = await Shell.runAsyncWithTimeout(
            "/usr/bin/dns-sd", args: args, timeoutSeconds: seconds
        )
        return output + error
    }

    nonisolated private static func parseDNSServiceBrowseInstances(from output: String, serviceType: String) -> [String] {
        var instances = Set<String>()
        let marker = serviceType + "."

        for line in output.components(separatedBy: .newlines) where line.contains(marker) && line.contains(" Add ") {
            guard let range = line.range(of: marker) else { continue }
            let instance = String(line[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !instance.isEmpty { instances.insert(instance) }
        }

        return Array(instances).sorted()
    }

    nonisolated private static func parseDNSServiceLookup(_ output: String) -> (host: String, port: String)? {
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

    private static func resolveBonjourHost(_ host: String) async -> String? {
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
            if fileManager.isExecutableFile(atPath: candidate) {
                let resolved = (candidate as NSString).standardizingPath
                print("📱 ADB: Using bundled ADB at: \(resolved)")
                adbPath = resolved
                return resolved
            }
        }
        
        // Process.executableURL does not search PATH; resolve the fallback to an absolute file.
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true).appendingPathComponent("adb").path
            if fileManager.isExecutableFile(atPath: candidate) {
                adbPath = candidate
                return candidate
            }
        }
        return ""
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
        let cmd = "find '\(FileNameHelper.escapeForSingleQuotedShell(path))' -type f -printf '%s %P\\n' 2>/dev/null"
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
            // Strip \r to handle carriage returns from ADB shell output
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

    static func listFiles(path: String, onPageLoaded: (([ADBFile]) -> Void)? = nil) async throws -> [ADBFile] {
        let adbPath = getADBPath()
        let totalStart = Date()
        AppLogger.log("⚙️ [listFiles] Request to list directory: \(path)")
        
        let startTime = Date()
        let listCommand = "ls -1a '\(FileNameHelper.escapeForSingleQuotedShell(path))' 2>&1"
        AppLogger.log("⚙️ [listFiles] Executing command: ls -1a '\(path)' 2>&1")
        
        // Shorter timeout for media paths — FUSE/Scoped Storage can block ls on Android 14+
        let isMediaPath = path.contains("/DCIM") || path.contains("/Pictures") || path.contains("/Movies")
        let lsTimeout: Double = isMediaPath ? 12.0 : 30.0
        if isMediaPath {
            AppLogger.log("⚙️ [listFiles] Media path detected — using \(Int(lsTimeout))s ls timeout (content:// fallback available)")
        }
        
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", listCommand]),
            timeoutSeconds: lsTimeout
        )
        
        let elapsed = Date().timeIntervalSince(startTime)
        AppLogger.log("⚙️ [listFiles] Command finished. Code: \(code), Elapsed: \(String(format: "%.3fs", elapsed)), Output length: \(output.count) chars, Stderr length: \(error.count) chars")
        
        if !error.isEmpty {
            AppLogger.log("⚠️ [listFiles] Stderr: \(error)")
        }
        
        let lines = output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        AppLogger.log("⚙️ [listFiles] Raw output lines count: \(lines.count)")
        
        if code != 0 {
            AppLogger.log("❌ [listFiles] Command failed with code \(code)")
            let isDCIMOnError = path.contains("/DCIM") || path.contains("/Pictures") || path.contains("/Movies")
            if isDCIMOnError {
                AppLogger.log("⚠️ [listFiles] Path contains DCIM/Pictures/Movies on error, attempting listMediaFiles content:// fallback...")
                let mediaFiles = await listMediaFiles(dcimPath: path, adbPath: adbPath, onPageLoaded: onPageLoaded)
                if !mediaFiles.isEmpty {
                    let totalElapsed = Date().timeIntervalSince(totalStart)
                    AppLogger.log("📷 [listFiles] content:// fallback recovered \(mediaFiles.count) files in \(String(format: "%.3fs", totalElapsed)) total")
                    return mediaFiles
                } else {
                    AppLogger.log("⚠️ [listFiles] content:// fallback returned 0 files")
                }
            }
            
            if !error.contains("No such file or directory") && !output.contains("No such file or directory") {
                AppLogger.log("❌ [listFiles] Error: \(error.isEmpty ? output : error)")
            }
            throw NSError(
                domain: "ADBError",
                code: Int(code),
                userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Failed to list files" : error]
            )
        }
        
        var fileNames: [String] = []
        output.enumerateLines { name, _ in
            let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            guard !cleanName.isEmpty && cleanName != "." && cleanName != ".." else { return }
            guard !cleanName.hasPrefix("ls:") && !cleanName.contains("Permission denied") && !cleanName.contains("Operation not permitted") else {
                // Safe to log: these lines contain only directory paths, not file names
                AppLogger.log("⚠️ [listFiles] Permission error: \(cleanName)")
                return
            }
            fileNames.append(cleanName)
        }
        
        let rawCount = output.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let skipped = rawCount - fileNames.count - 2 // subtract "." and ".."
        if skipped > 0 {
            AppLogger.log("⚙️ [listFiles] Parsed \(fileNames.count) valid filenames (\(skipped) lines filtered out — '.' / '..' / permission errors)")
        } else {
            AppLogger.log("⚙️ [listFiles] Parsed \(fileNames.count) valid filenames (raw: \(rawCount) lines, no errors filtered)")
        }
        
        if fileNames.isEmpty {
            AppLogger.log("⚠️ [listFiles] No files returned by ls. Checking if media fallback is appropriate...")
            let isDCIM = path.contains("/DCIM") || path.contains("/Pictures") || path.contains("/Movies")
            if isDCIM {
                // Classify the permission type for diagnostics
                let permType: String
                if output.contains("Operation not permitted") {
                    permType = "SELinux/Capability (Operation not permitted)"
                } else if output.contains("Permission denied") {
                    permType = "FUSE/Scoped Storage (Permission denied)"
                } else {
                    permType = "Unknown (ls returned 0 files with no error text)"
                }
                
                // ls returned Code 0 + 0 bytes — either a genuinely empty folder or FUSE sync delay.
                // Use a quick 'find' check (different syscalls than ls) to distinguish the two cases
                // before doing any slow retries. find takes ~0.1s vs 4.5s of blind retries.
                if output.isEmpty && !output.contains("Permission denied") && !output.contains("Operation not permitted") {
                    let escapedPathForFind = path.replacingOccurrences(of: "'", with: "'\\''")
                    let findCheckCmd = "find '\(escapedPathForFind)' -mindepth 1 -maxdepth 1 2>/dev/null | head -5"
                    AppLogger.log("⚙️ [listFiles] ls returned 0 chars. Running quick find check...")
                    let (findCode, findOut, _) = await Shell.runAsyncWithTimeout(
                        adbPath, args: deviceArgs(["shell", findCheckCmd]), timeoutSeconds: 5.0
                    )
                    let findResults = findOut.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if findCode == 0 && findResults.isEmpty {
                        // Both ls and find agree: directory is genuinely empty — return immediately
                        AppLogger.log("⚙️ [listFiles] find also returned 0 entries. Directory is genuinely empty.")
                        let totalElapsed = Date().timeIntervalSince(totalStart)
                        AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - 0 files in \(String(format: "%.3fs", totalElapsed)) total")
                        return []
                    }
                    
                    if !findResults.isEmpty {
                        // find found files but ls didn't → genuine FUSE sync delay. Single retry after 1.5s.
                        AppLogger.log("⚠️ [listFiles] find found entries but ls returned empty — FUSE sync delay confirmed. Retrying ls after 1.5s...")
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        
                        let (retryCode, retryOutput, retryError) = await Shell.runAsyncWithTimeout(
                            adbPath, args: deviceArgs(["shell", listCommand]), timeoutSeconds: 10.0
                        )
                        let retryLines = retryOutput.components(separatedBy: .newlines).filter { !$0.isEmpty }
                        AppLogger.log("⚙️ [listFiles] Retry result - Code: \(retryCode), Output length: \(retryOutput.count) chars, Lines: \(retryLines.count)")
                        
                        if retryCode == 0 && !retryOutput.isEmpty {
                            var retryFileNames: [String] = []
                            retryOutput.enumerateLines { name, _ in
                                let cleanName = name.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                                guard !cleanName.isEmpty && cleanName != "." && cleanName != ".." else { return }
                                guard !cleanName.hasPrefix("ls:") && !cleanName.contains("Permission denied") && !cleanName.contains("Operation not permitted") else { return }
                                retryFileNames.append(cleanName)
                            }
                            if !retryFileNames.isEmpty {
                                AppLogger.log("✅ [listFiles] Retry recovered \(retryFileNames.count) files — FUSE sync delay resolved")
                                let totalElapsed = Date().timeIntervalSince(totalStart)
                                if retryFileNames.count <= 100 {
                                    let result = try await listFilesWithDetails(path: path, adbPath: adbPath, exactNames: retryFileNames)
                                    AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - \(result.count) files in \(String(format: "%.3fs", totalElapsed)) total (1 retry)")
                                    return result
                                }
                                fileNames = retryFileNames
                            } else {
                                AppLogger.log("⚠️ [listFiles] Retry also returned 0 valid filenames")
                                if !retryError.isEmpty {
                                    AppLogger.log("⚠️ [listFiles] Retry error: \(retryError)")
                                }
                            }
                        } else {
                            AppLogger.log("⚠️ [listFiles] Retry failed - Code: \(retryCode), Error: \(retryError)")
                        }
                    }
                }
                
                if fileNames.isEmpty {
                    // Optimization: If the ls command executed successfully (code 0) and returned no permission errors,
                    // the folder is verified accessible and simply empty. Avoid calling slow media content fallback.
                    let hasPermissionError = output.contains("Permission denied") || output.contains("Operation not permitted") || error.contains("Permission denied") || error.contains("Operation not permitted")
                    if !hasPermissionError && code == 0 {
                        AppLogger.log("⚙️ [listFiles] Directory is verified accessible and empty. Skipping content:// fallback.")
                        let totalElapsed = Date().timeIntervalSince(totalStart)
                        AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - 0 files in \(String(format: "%.3fs", totalElapsed)) total")
                        return []
                    }
                    
                    AppLogger.log("⚠️ [listFiles] Empty result on media path. Permission type: \(permType). Attempting content:// fallback...")
                    let mediaFiles = await listMediaFiles(dcimPath: path, adbPath: adbPath, onPageLoaded: onPageLoaded)
                    if !mediaFiles.isEmpty {
                        let totalElapsed = Date().timeIntervalSince(totalStart)
                        AppLogger.log("📷 [listFiles] content:// fallback returned \(mediaFiles.count) files in \(String(format: "%.3fs", totalElapsed)) total")
                        return mediaFiles
                    } else {
                        AppLogger.log("⚠️ [listFiles] content:// fallback returned 0 files")
                    }
                }
            }
            let totalElapsed = Date().timeIntervalSince(totalStart)
            AppLogger.log("⚠️ [listFiles] ❗ Returning EMPTY for path: \(path) - no files from ls and \(isDCIM ? "content:// fallback also empty" : "not a media path, no fallback available"). Elapsed: \(String(format: "%.3fs", totalElapsed))")
            return []
        }
        
        AppLogger.log("⚙️ [listFiles] Deciding strategy for \(fileNames.count) files...")
        
        if fileNames.count <= 100 {
            AppLogger.log("⚙️ [listFiles] Small directory (<=100 files) -> using listFilesWithDetails")
            let detailStart = Date()
            let result = try await listFilesWithDetails(path: path, adbPath: adbPath, exactNames: fileNames)
            let detailElapsed = Date().timeIntervalSince(detailStart)
            AppLogger.log("⚙️ [listFiles] listFilesWithDetails returned \(result.count) files in \(String(format: "%.3fs", detailElapsed))")
            // Log file size stats (privacy-safe: no names, just min/max/total)
            let sizes = result.map { $0.size }
            let totalBytes = sizes.reduce(0, +)
            let maxSize = sizes.max() ?? 0
            let minSize = sizes.filter { $0 > 0 }.min() ?? 0
            AppLogger.log("⚙️ [listFiles] Size stats: total=\(totalBytes) bytes (\(totalBytes / 1_048_576) MB), max=\(maxSize) bytes (\(maxSize / 1_048_576) MB), min=\(minSize) bytes")
            let totalElapsed = Date().timeIntervalSince(totalStart)
            AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - \(result.count) files in \(String(format: "%.3fs", totalElapsed)) total")
            return result
        }
        
        AppLogger.log("⚙️ [listFiles] Large directory (>100 files) -> trying fast stat path")
        let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
        let statAllCmd = "cd '\(escapedPath)' && stat -c '%A|%s|%Y|%n' * 2>/dev/null"
        let fastStatStart = Date()
        AppLogger.log("⚙️ [listFiles] Executing fast stat on \(fileNames.count) files in: \(path)")
        let (statCode, statOutput, statErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", statAllCmd]), timeoutSeconds: 3.0
        )
        let fastStatElapsed = Date().timeIntervalSince(fastStatStart)
        AppLogger.log("⚙️ [listFiles] Fast stat result - Code: \(statCode), Elapsed: \(String(format: "%.3fs", fastStatElapsed)), Output length: \(statOutput.count) chars, Stderr length: \(statErr.count) chars")
        
        // Parse stdout regardless of exit code — stat outputs results for
        // successful files even when some files cause errors (non-zero exit).
        if !statOutput.isEmpty {
            var files: [ADBFile] = []
            files.reserveCapacity(fileNames.count)
            let nameSet = Set(fileNames)
            
            statOutput.enumerateLines { line, _ in
                let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                let parts = cleanLine.split(separator: "|", maxSplits: 3)
                guard parts.count == 4 else { return }
                let perms = String(parts[0])
                let size  = UInt64(parts[1]) ?? 0
                let ts    = Double(parts[2])
                let name  = String(parts[3]).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard nameSet.contains(name) else { return }
                let isDir = perms.hasPrefix("d")
                let modDate = ts.map { Date(timeIntervalSince1970: $0) }
                let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                files.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
            }
            
            if files.count == fileNames.count {
                AppLogger.log("⚙️ [listFiles] stat * returned all \(files.count) files")
                let totalElapsed = Date().timeIntervalSince(totalStart)
                AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - \(files.count) files in \(String(format: "%.3fs", totalElapsed)) total")
                return files
            }
            // stat * got some — fill missing
            if !files.isEmpty {
                AppLogger.log("⚙️ [listFiles] stat * returned \(files.count)/\(fileNames.count), filling missing")
                return await fillMissing(from: fileNames, existing: files, basePath: path, adbPath: adbPath)
            }
        }
        
        // stat * failed or timed out — return names immediately so user isn't stuck waiting.
        // Files show with "---" for size/date but are fully browsable, downloadable, etc.
        AppLogger.log("⚙️ [listFiles] stat * unavailable, returning \(fileNames.count) files with names only")
        let totalElapsed = Date().timeIntervalSince(totalStart)
        AppLogger.log("⚙️ [listFiles] ✅ COMPLETE for \(path) - \(fileNames.count) names-only in \(String(format: "%.3fs", totalElapsed)) total")
        return await fillMissing(from: fileNames, existing: [], basePath: path, adbPath: adbPath)
    }
    
    // MARK: - Device Diagnostics
    
    /// Logs device info at connection time for debugging Samsung/Scoped Storage issues.
    /// Privacy-safe: file names are masked (e.g. IMG***456.jpg) — enough to verify data flow without revealing content.
    static func logDeviceDiagnostics() async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        // Masks a file name: "IMG_20240101_vacation.jpg" → "IMG***ion.jpg"
        func mask(_ name: String) -> String {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            if base.count <= 6 {
                return "***" + (ext.isEmpty ? "" : ".\(ext)")
            }
            let prefix = String(base.prefix(3))
            let suffix = String(base.suffix(3))
            return "\(prefix)***\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
        }
        
        AppLogger.log("═══════════════════════════════════════════════════════")
        AppLogger.log("📱 [DEVICE DIAGNOSTICS] Starting (file names masked for privacy)...")
        
        // --- Device system info (not user-private) ---
        let props: [(String, String)] = [
            ("Device Model", "ro.product.model"),
            ("Manufacturer", "ro.product.manufacturer"),
            ("Android Version", "ro.build.version.release"),
            ("SDK Level", "ro.build.version.sdk"),
            ("Build Display", "ro.build.display.id"),
            ("Security Patch", "ro.build.version.security_patch"),
            ("One UI Version", "ro.build.version.oneui"),
        ]
        
        for (label, prop) in props {
            let (_, val, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", "getprop", prop]), timeoutSeconds: 5.0
            )
            let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLogger.log("📱 [DIAG] \(label): \(trimmed.isEmpty ? "(empty)" : trimmed)")
        }
        
        // SELinux status
        let (_, selinux, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "getenforce"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] SELinux: \(selinux.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // Shell user identity (UID/GID, no personal data)
        let (_, idOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "id"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] Shell User: \(idOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // ADB security setting
        let (_, secOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "settings get global adb_enabled"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] ADB enabled setting: \(secOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // --- File system access tests ---
        
        // Test ls on DCIM/Camera — log count + 3 masked sample names
        let (lsCode, lsOut, lsErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "ls -1 /storage/emulated/0/DCIM/Camera/ 2>&1"]), timeoutSeconds: 5.0
        )
        let lsLines = lsOut.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.contains("Permission denied") && !$0.contains("No such file") }
        AppLogger.log("📱 [DIAG] ls DCIM/Camera - Code: \(lsCode), File count: \(lsLines.count)")
        // Log 3 masked samples to verify ls is actually returning file data
        for (idx, name) in lsLines.prefix(3).enumerated() {
            AppLogger.log("📱 [DIAG]   ls sample[\(idx)]: \(mask(name.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }
        if !lsErr.isEmpty {
            AppLogger.log("📱 [DIAG] ls DCIM/Camera Stderr: \(lsErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if lsOut.contains("Permission denied") || lsOut.contains("No such file") {
            AppLogger.log("📱 [DIAG] ⚠️ ls errors in output: \(lsOut.components(separatedBy: .newlines).filter { $0.contains("Permission") || $0.contains("No such") }.joined(separator: "; "))")
        }
        
        // Readable test
        let (testCode, testOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "test -r /storage/emulated/0/DCIM/Camera && echo 'READABLE' || echo 'NOT_READABLE'"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] DCIM/Camera readable: \(testOut.trimmingCharacters(in: .whitespacesAndNewlines)) (code: \(testCode))")
        
        // --- Permission type classification ---
        
        // Test write access (distinguishes read-only vs full block)
        let (_, writeOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "touch /storage/emulated/0/DCIM/Camera/.afs_perm_test 2>&1 && rm /storage/emulated/0/DCIM/Camera/.afs_perm_test 2>&1 && echo 'WRITABLE' || echo 'NOT_WRITABLE'"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] DCIM/Camera writable: \(writeOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // Test reading a single file's first byte (can we actually access file content?)
        // Use simple two-step: get first filename, then try to read it
        let (_, firstFileOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "ls /storage/emulated/0/DCIM/Camera/ 2>/dev/null | head -1"]), timeoutSeconds: 5.0
        )
        let firstFile = firstFileOut.trimmingCharacters(in: .whitespacesAndNewlines)
        if !firstFile.isEmpty && !firstFile.contains("No such") {
            let (readCode, _, readErr) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", "head -c 1 '/storage/emulated/0/DCIM/Camera/\(firstFile)' >/dev/null 2>&1; echo $?"]), timeoutSeconds: 5.0
            )
            let exitResult = readErr.isEmpty ? "code \(readCode)" : readErr.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLogger.log("📱 [DIAG] Single file read test: \(readCode == 0 ? "FILE_READABLE" : "FILE_NOT_READABLE") (\(exitResult))")
        } else {
            AppLogger.log("📱 [DIAG] Single file read test: SKIPPED (no files found by ls)")
        }
        
        // Check SELinux status and recent denials (logcat is more reliable than dmesg on Android)
        let (_, logcatOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "logcat -d -s avc -t 10 2>/dev/null || echo 'LOGCAT_NOT_AVAILABLE'"]), timeoutSeconds: 5.0
        )
        let logcatClean = logcatOut.trimmingCharacters(in: .whitespacesAndNewlines)
        if logcatClean.contains("denied") {
            AppLogger.log("📱 [DIAG] ⚠️ SELinux AVC denials found in logcat:")
            logcatClean.components(separatedBy: .newlines)
                .filter { $0.contains("denied") }
                .prefix(3)
                .forEach { AppLogger.log("📱 [DIAG]   \($0)") }
        } else if logcatClean.contains("LOGCAT_NOT_AVAILABLE") {
            AppLogger.log("📱 [DIAG] SELinux AVC check: logcat not available")
        } else {
            AppLogger.log("📱 [DIAG] SELinux AVC denials: none found")
        }
        
        // Samsung-specific: check USB debugging security setting
        let (_, samSecOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "settings get global development_settings_enabled"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] Developer settings enabled: \(samSecOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // Check shell user's group memberships using 'id' — always outputs named groups
        let (_, groupsOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "id"]), timeoutSeconds: 5.0
        )
        let groupLines = groupsOut.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSDCardRW  = groupLines.contains("sdcard_rw")  || groupLines.contains("1015")
        let hasMediaRW   = groupLines.contains("media_rw")   || groupLines.contains("1023")
        let hasExtDataRW = groupLines.contains("ext_data_rw") || groupLines.contains("1078")
        let hasSDCardR   = groupLines.contains("sdcard_r")   || groupLines.contains("1028")
        AppLogger.log("📱 [DIAG] Shell groups: sdcard_rw=\(hasSDCardRW), sdcard_r=\(hasSDCardR), media_rw=\(hasMediaRW), ext_data_rw=\(hasExtDataRW)")
        
        // --- Content provider tests (masked file names for verification) ---
        
        // Unfiltered content query — check _data prefix pattern and verify data flows (limit to top 3)
        let contentCmd = "content query --uri \"content://media/external/images/media?limit=3\" --projection _display_name:_data:relative_path --sort \"date_modified DESC\""
        let (cCode, cOut, cErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", contentCmd]), timeoutSeconds: 10.0
        )
        AppLogger.log("📱 [DIAG] Content query (images, top 3) - Code: \(cCode)")
        if !cErr.isEmpty {
            AppLogger.log("📱 [DIAG] Content query Stderr: \(cErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        var printedCount = 0
        cOut.enumerateLines { line, stop in
            let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if clean.contains("Permission") || clean.contains("Error") || clean.contains("No result") {
                AppLogger.log("📱 [DIAG] ⚠️ \(clean)")
            } else if clean.hasPrefix("Row:") {
                printedCount += 1
                if printedCount > 3 {
                    stop = true
                    return
                }
                // Extract _data prefix (directory only) and masked _display_name
                var dirPrefix = "(none)"
                var maskedName = "(none)"
                var relPath = "(none)"
                if let dataRange = clean.range(of: "_data=") {
                    let pathValue = String(clean[dataRange.upperBound...]).components(separatedBy: ",").first ?? ""
                    dirPrefix = (pathValue as NSString).deletingLastPathComponent
                }
                if let nameRange = clean.range(of: "_display_name=") {
                    let nameValue = String(clean[nameRange.upperBound...]).components(separatedBy: ",").first ?? ""
                    maskedName = mask(nameValue.trimmingCharacters(in: .whitespaces))
                }
                if let rpRange = clean.range(of: "relative_path=") {
                    relPath = String(clean[rpRange.upperBound...]).components(separatedBy: ",").first ?? ""
                }
                AppLogger.log("📱 [DIAG]   → dir: \(dirPrefix), name: \(maskedName), relative_path: \(relPath)")
            }
        }
        
        // Count + sample images in DCIM/Camera via _data LIKE
        let countCmd = "content query --uri content://media/external/images/media --projection _display_name --where \"_data LIKE '/storage/emulated/0/DCIM/Camera/%' AND _data NOT LIKE '/storage/emulated/0/DCIM/Camera/%/%'\""
        let (_, countOut, countErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", countCmd]), timeoutSeconds: 15.0
        )
        let countLines = countOut.components(separatedBy: .newlines).filter { $0.hasPrefix("Row:") }
        AppLogger.log("📱 [DIAG] Image count (_data LIKE '/storage/emulated/0/DCIM/Camera/%%'): \(countLines.count)")
        // Log 3 masked samples to prove data is actually returned
        for (idx, row) in countLines.prefix(3).enumerated() {
            if let nameRange = row.range(of: "_display_name=") {
                let nameVal = String(row[nameRange.upperBound...]).components(separatedBy: ",").first ?? ""
                AppLogger.log("📱 [DIAG]   _data sample[\(idx)]: \(mask(nameVal.trimmingCharacters(in: .whitespaces)))")
            }
        }
        if countOut.contains("No result") { AppLogger.log("📱 [DIAG] ⚠️ _data WHERE returned no results") }
        if countOut.contains("Permission") || countOut.contains("Error") {
            AppLogger.log("📱 [DIAG] ⚠️ _data WHERE error: \(countErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        
        // Count + sample images in DCIM/Camera via relative_path
        let rpCountCmd = "content query --uri content://media/external/images/media --projection _display_name --where \"relative_path='DCIM/Camera/'\""
        let (_, rpCountOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", rpCountCmd]), timeoutSeconds: 15.0
        )
        let rpCountLines = rpCountOut.components(separatedBy: .newlines).filter { $0.hasPrefix("Row:") }
        AppLogger.log("📱 [DIAG] Image count (relative_path='DCIM/Camera/'): \(rpCountLines.count)")
        for (idx, row) in rpCountLines.prefix(3).enumerated() {
            if let nameRange = row.range(of: "_display_name=") {
                let nameVal = String(row[nameRange.upperBound...]).components(separatedBy: ",").first ?? ""
                AppLogger.log("📱 [DIAG]   rp sample[\(idx)]: \(mask(nameVal.trimmingCharacters(in: .whitespaces)))")
            }
        }
        if rpCountOut.contains("No result") { AppLogger.log("📱 [DIAG] ⚠️ relative_path WHERE returned no results") }
        
        // Count videos in DCIM/Camera
        let vidCountCmd = "content query --uri content://media/external/video/media --projection _id --where \"relative_path='DCIM/Camera/'\""
        let (_, vidCountOut, vidErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", vidCountCmd]), timeoutSeconds: 15.0
        )
        let vidCountRows = vidCountOut.components(separatedBy: .newlines).filter { $0.hasPrefix("Row:") }.count
        AppLogger.log("📱 [DIAG] Video count (relative_path='DCIM/Camera/'): \(vidCountRows)")
        if !vidErr.isEmpty && (vidErr.contains("Permission") || vidErr.contains("Error")) {
            AppLogger.log("📱 [DIAG] ⚠️ Video query error: \(vidErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        
        // Count all files in DCIM/Camera via files table
        let filesCountCmd = "content query --uri content://media/external/file --projection _id --where \"_data LIKE '/storage/emulated/0/DCIM/Camera/%' AND _data NOT LIKE '/storage/emulated/0/DCIM/Camera/%/%'\""
        let (_, filesCountOut, filesErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", filesCountCmd]), timeoutSeconds: 15.0
        )
        let filesCountRows = filesCountOut.components(separatedBy: .newlines).filter { $0.hasPrefix("Row:") }.count
        AppLogger.log("📱 [DIAG] Files table count in DCIM/Camera: \(filesCountRows)")
        if !filesErr.isEmpty && (filesErr.contains("Permission") || filesErr.contains("Error")) {
            AppLogger.log("📱 [DIAG] ⚠️ Files table error: \(filesErr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        
        // DCIM subdirectory count (not names — privacy safe)
        let (_, dcimCountOut, _) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", "ls -1 /storage/emulated/0/DCIM/ 2>&1 | wc -l"]), timeoutSeconds: 5.0
        )
        AppLogger.log("📱 [DIAG] DCIM subdirectory count: \(dcimCountOut.trimmingCharacters(in: .whitespacesAndNewlines))")
        
        // --- CONCLUSION: compare ls vs MediaStore to identify root cause ---
        let totalMediaStoreCount = countLines.count + rpCountLines.count + vidCountRows + filesCountRows
        AppLogger.log("─────────────────────────────────────────────────────────")
        AppLogger.log("📱 [DIAG CONCLUSION]")
        AppLogger.log("📱   ls file count:         \(lsLines.count)")
        AppLogger.log("📱   MediaStore total count: \(totalMediaStoreCount) (images+rp+videos+files)")
        
        if lsLines.count == 0 && totalMediaStoreCount == 0 {
            AppLogger.log("📱   ❌ DIAGNOSIS: Both ls AND MediaStore return 0")
            AppLogger.log("📱   ❌ Likely causes: FUSE/Scoped Storage blocking ls, SELinux policy, OR Samsung 'USB debugging (Security settings)' not enabled")
        } else if lsLines.count > 0 && totalMediaStoreCount == 0 {
            AppLogger.log("📱   ⚠️ DIAGNOSIS: ls sees \(lsLines.count) files but MediaStore returns 0")
            AppLogger.log("📱   ⚠️ Possible causes:")
            AppLogger.log("📱     1. Files added via ADB directly (bypassing media scanner) — most common on test devices")
            AppLogger.log("📱     2. Media scan ran but Android 13+ FUSE blocked indexing of these files")
        } else if lsLines.count > 0 && totalMediaStoreCount > 0 {
            AppLogger.log("📱   ✅ DIAGNOSIS: Both ls and MediaStore return data — no access issues detected")
        }
        AppLogger.log("─────────────────────────────────────────────────────────")
        
        AppLogger.log("📱 [DEVICE DIAGNOSTICS] Complete.")
        AppLogger.log("═══════════════════════════════════════════════════════")
    }
    
    // MARK: - content:// Media Provider fallback
    
    private static func resolvePhysicalPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/sdcard") {
            p = "/storage/emulated/0" + p.dropFirst("/sdcard".count)
        } else if p.hasPrefix("sdcard") {
            p = "/storage/emulated/0" + p.dropFirst("sdcard".count)
        }
        return p
    }
    
    /// Fallback for DCIM/Camera where direct `ls` may be blocked by Android FUSE/Scoped Storage.
    /// Queries the Android MediaStore content provider with a WHERE clause to fetch only
    /// files in the target directory — fast even on devices with thousands of media files.
    private static func listMediaFiles(dcimPath: String, adbPath: String, onPageLoaded: (([ADBFile]) -> Void)? = nil) async -> [ADBFile] {
        let resolvedPath = resolvePhysicalPath(dcimPath)
        let normalizedPath = resolvedPath.hasSuffix("/") ? resolvedPath : resolvedPath + "/"
        AppLogger.log("⚙️ [listMediaFiles] Starting scan for: \(dcimPath) (Normalized: \(normalizedPath))", level: .info)
        
        var fileNames: [String] = []
        var seenNames = Set<String>()
        
        // ── Strategy 1: `find` command ──
        // Gets ALL files (media + non-media). Uses different syscalls than `ls`,
        // which may bypass FUSE blocking on some Samsung builds.
        AppLogger.log("⚙️ [listMediaFiles] Strategy 1: find command (gets all file types)", level: .info)
        let escapedPath = dcimPath.replacingOccurrences(of: "'", with: "'\\''")
        let findCmd = "find '\(escapedPath)' -maxdepth 1 -not -name '.' -not -name '..' 2>/dev/null"
        let (findCode, findOutput, findError) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: deviceArgs(["shell", findCmd]),
            timeoutSeconds: 10.0
        )
        AppLogger.log("⚙️ [listMediaFiles] find result - Code: \(findCode), Output: \(findOutput.count) chars", level: .info)
        if !findError.isEmpty {
            AppLogger.log("⚠️ [listMediaFiles] find stderr: \(findError)", level: .warning)
        }
        
        if findCode == 0, !findOutput.isEmpty {
            findOutput.enumerateLines { line, _ in
                let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                guard !clean.isEmpty else { return }
                let name = (clean as NSString).lastPathComponent
                guard !name.isEmpty, name != "." , name != ".." else { return }
                // Skip the directory itself (find outputs the search dir as first result)
                let fullPath = clean.hasPrefix("/") ? clean : normalizedPath + clean
                guard fullPath != dcimPath, fullPath != normalizedPath,
                      fullPath != String(normalizedPath.dropLast()) else { return }
                if seenNames.insert(name).inserted {
                    fileNames.append(name)
                }
            }
            if !fileNames.isEmpty {
                AppLogger.log("⚙️ [listMediaFiles] Strategy 1 (find) found \(fileNames.count) entries", level: .info)
            }
        }
        
        // ── Strategy 2: file URI (ALL indexed files) — PAGINATED ──
        // content://media/external/file contains images, videos, audio, documents — everything.
        // Uses keyset pagination (_id > lastId, LIMIT 500) to avoid FUSE/SQLite timeouts
        // on large directories. Each page is forwarded via onPageLoaded for progressive UI.
        if fileNames.isEmpty {
            let storagePrefix = "/storage/emulated/0/"
            let relativePath: String? = {
                if normalizedPath.hasPrefix(storagePrefix) {
                    return String(normalizedPath.dropFirst(storagePrefix.count))
                }
                let storagePrefixBase = "/storage/"
                if normalizedPath.hasPrefix(storagePrefixBase) {
                    let afterStorage = String(normalizedPath.dropFirst(storagePrefixBase.count))
                    if let slashIndex = afterStorage.firstIndex(of: "/") {
                        let afterVolume = String(afterStorage[afterStorage.index(after: slashIndex)...])
                        if !afterVolume.isEmpty { return afterVolume }
                    }
                }
                return nil
            }()
            
            let baseWhereClause: String
            if let rp = relativePath, !rp.isEmpty {
                let escapedRP = rp.replacingOccurrences(of: "'", with: "''")
                baseWhereClause = "relative_path='\(escapedRP)'"
            } else {
                let escapedNorm = normalizedPath.replacingOccurrences(of: "'", with: "''")
                baseWhereClause = "_data LIKE '\(escapedNorm)%' AND _data NOT LIKE '\(escapedNorm)%/%'"
            }
            
            let pageSize = 500
            var lastId = 0
            var pageIndex = 0
            AppLogger.log("⚙️ [listMediaFiles] Strategy 2: file URI (paginated, page size: \(pageSize))", level: .info)
            
            while true {
                // Stop immediately if the task was cancelled (user navigated to another directory)
                guard !Task.isCancelled else {
                    AppLogger.log("⚙️ [listMediaFiles] Strategy 2 pagination cancelled at page \(pageIndex)", level: .info)
                    break
                }
                let paginatedWhere = "\(baseWhereClause) AND _id>\(lastId)"
                let fileCmd = "content query --uri \"content://media/external/file?limit=\(pageSize)\" --projection _display_name:_id --where \"\(paginatedWhere)\" --sort \"_id ASC\""
                let (fileCode, fileOutput, fileError) = await Shell.runAsyncWithTimeout(
                    adbPath,
                    args: deviceArgs(["shell", fileCmd]),
                    timeoutSeconds: 15.0
                )
                if !fileError.isEmpty {
                    AppLogger.log("⚠️ [listMediaFiles] Strategy 2 page \(pageIndex) stderr: \(fileError)", level: .warning)
                }
                
                guard fileCode == 0, !fileOutput.isEmpty else { break }
                
                var pageNames: [String] = []
                var maxIdInPage = lastId
                
                fileOutput.enumerateLines { line, _ in
                    let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    guard clean.hasPrefix("Row:") else { return }
                    if let name = extractDisplayName(from: clean),
                       seenNames.insert(name).inserted {
                        pageNames.append(name)
                        fileNames.append(name)
                    }
                    if let id = extractId(from: clean), id > maxIdInPage {
                        maxIdInPage = id
                    }
                }
                
                if pageNames.isEmpty { break }
                
                // Progressive callback: send placeholder ADBFile entries for immediate UI display
                if let callback = onPageLoaded {
                    let pageFiles = pageNames.map { name in
                        ADBFile(
                            name: name,
                            path: normalizedPath + name,
                            isDirectory: false,
                            size: 0,
                            modificationDate: nil
                        )
                    }
                    callback(pageFiles)
                }
                
                AppLogger.log("⚙️ [listMediaFiles] Strategy 2 page \(pageIndex): \(pageNames.count) files (total: \(fileNames.count), lastId: \(maxIdInPage))", level: .info)
                
                lastId = maxIdInPage
                pageIndex += 1
                
                // If we got fewer than pageSize, this is the last page
                if pageNames.count < pageSize { break }
            }
            
            if !fileNames.isEmpty {
                AppLogger.log("⚙️ [listMediaFiles] Strategy 2 (paginated) found \(fileNames.count) files in \(pageIndex) pages", level: .info)
            }
        }
        
        // ── Strategy 3: Per-type URIs (fallback) — PAGINATED ──
        // If file URI failed, try individual media type URIs with keyset pagination.
        if fileNames.isEmpty {
            let lowerPath = dcimPath.lowercased()
            var uris: [String] = []
            if lowerPath.contains("music") || lowerPath.contains("audio") || lowerPath.contains("recording") {
                uris.append("content://media/external/audio/media")
            } else if lowerPath.contains("video") || lowerPath.contains("movies") {
                uris.append("content://media/external/video/media")
                uris.append("content://media/external/images/media")
            } else {
                uris.append("content://media/external/images/media")
                uris.append("content://media/external/video/media")
                uris.append("content://media/external/audio/media")
            }
            
            let storagePrefix = "/storage/emulated/0/"
            let relativePath: String? = normalizedPath.hasPrefix(storagePrefix) ? String(normalizedPath.dropFirst(storagePrefix.count)) : nil
            let baseWhereClause: String
            if let rp = relativePath, !rp.isEmpty {
                baseWhereClause = "relative_path='\(rp.replacingOccurrences(of: "'", with: "''"))'"
            } else {
                let escapedNorm = normalizedPath.replacingOccurrences(of: "'", with: "''")
                baseWhereClause = "_data LIKE '\(escapedNorm)%' AND _data NOT LIKE '\(escapedNorm)%/%'"
            }
            
            let pageSize = 500
            AppLogger.log("⚙️ [listMediaFiles] Strategy 3: per-type URIs (\(uris.count) types, paginated)", level: .info)
            for uri in uris {
                var lastId = 0
                var pageIndex = 0
                
                while true {
                    // Stop immediately if the task was cancelled (user navigated to another directory)
                    guard !Task.isCancelled else {
                        AppLogger.log("⚙️ [listMediaFiles] Strategy 3 [\(uri)] pagination cancelled at page \(pageIndex)", level: .info)
                        break
                    }
                    let paginatedWhere = "\(baseWhereClause) AND _id>\(lastId)"
                    let cmd = "content query --uri \"\(uri)?limit=\(pageSize)\" --projection _display_name:_id --where \"\(paginatedWhere)\" --sort \"_id ASC\""
                    let (code, output, error) = await Shell.runAsyncWithTimeout(
                        adbPath,
                        args: deviceArgs(["shell", cmd]),
                        timeoutSeconds: 15.0
                    )
                    if !error.isEmpty {
                        AppLogger.log("⚠️ [listMediaFiles] Strategy 3 [\(uri)] page \(pageIndex) stderr: \(error)", level: .warning)
                    }
                    guard code == 0, !output.isEmpty else { break }
                    
                    var pageNames: [String] = []
                    var maxIdInPage = lastId
                    
                    output.enumerateLines { line, _ in
                        let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                        guard clean.hasPrefix("Row:") else { return }
                        if let name = extractDisplayName(from: clean),
                           seenNames.insert(name).inserted {
                            pageNames.append(name)
                            fileNames.append(name)
                        }
                        if let id = extractId(from: clean), id > maxIdInPage {
                            maxIdInPage = id
                        }
                    }
                    
                    if pageNames.isEmpty { break }
                    
                    // Progressive callback
                    if let callback = onPageLoaded {
                        let pageFiles = pageNames.map { name in
                            ADBFile(
                                name: name,
                                path: normalizedPath + name,
                                isDirectory: false,
                                size: 0,
                                modificationDate: nil
                            )
                        }
                        callback(pageFiles)
                    }
                    
                    AppLogger.log("⚙️ [listMediaFiles] Strategy 3 [\(uri)] page \(pageIndex): \(pageNames.count) files (total: \(fileNames.count), lastId: \(maxIdInPage))", level: .info)
                    
                    lastId = maxIdInPage
                    pageIndex += 1
                    
                    if pageNames.count < pageSize { break }
                }
            }
            if !fileNames.isEmpty {
                AppLogger.log("⚙️ [listMediaFiles] Strategy 3 (paginated) found \(fileNames.count) files", level: .info)
            }
        }
        
        if fileNames.isEmpty {
            // All three strategies returned 0 files.
            // This can happen when files were pushed externally (e.g. adb push from terminal,
            // another app) and are physically on disk but not yet indexed in MediaStore.
            // Strategy 1 (find) failed due to FUSE/Scoped Storage, Strategies 2 & 3 queried
            // MediaStore which hasn't indexed the new files yet.
            //
            // Fix: trigger a quick media scan for this directory, wait briefly for MediaStore to
            // index, then retry Strategy 2 once. Only fires in the "all failed" path — no overhead
            // in normal browsing.
            AppLogger.log("⚙️ [listMediaFiles] All strategies returned 0 files. Triggering media scan + retry for: \(dcimPath)", level: .info)
            
            let escapedScan = dcimPath.replacingOccurrences(of: "'", with: "'\\''")
            let scanCmd = "cmd media.scanner scan '\(escapedScan)' >/dev/null 2>&1"
            _ = await Shell.runAsyncWithTimeout(adbPath, args: deviceArgs(["shell", scanCmd]), timeoutSeconds: 8.0)
            
            // Give MediaStore ~1.5s to process the scan before retrying
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            
            // Retry Strategy 2: content://media/external/file (paginated)
            let storagePrefix = "/storage/emulated/0/"
            let retryRP: String? = normalizedPath.hasPrefix(storagePrefix)
                ? String(normalizedPath.dropFirst(storagePrefix.count)) : nil
            let retryBaseWhere: String
            if let rp = retryRP, !rp.isEmpty {
                retryBaseWhere = "relative_path='\(rp.replacingOccurrences(of: "'", with: "''"))'"
            } else {
                let esc = normalizedPath.replacingOccurrences(of: "'", with: "''")
                retryBaseWhere = "_data LIKE '\(esc)%' AND _data NOT LIKE '\(esc)%/%'"
            }
            
            let retryPageSize = 500
            var retryLastId = 0
            var retryPageIndex = 0
            
            while true {
                // Stop immediately if the task was cancelled (user navigated to another directory)
                guard !Task.isCancelled else {
                    AppLogger.log("⚙️ [listMediaFiles] Post-scan retry pagination cancelled at page \(retryPageIndex)", level: .info)
                    break
                }
                let paginatedWhere = "\(retryBaseWhere) AND _id>\(retryLastId)"
                let retryCmd = "content query --uri \"content://media/external/file?limit=\(retryPageSize)\" --projection _display_name:_id --where \"\(paginatedWhere)\" --sort \"_id ASC\""
                let (retryCode, retryOut, _) = await Shell.runAsyncWithTimeout(
                    adbPath, args: deviceArgs(["shell", retryCmd]), timeoutSeconds: 15.0
                )
                AppLogger.log("⚙️ [listMediaFiles] Post-scan retry page \(retryPageIndex) - Code: \(retryCode), Output: \(retryOut.count) chars", level: .info)
                
                guard retryCode == 0, !retryOut.isEmpty else { break }
                
                var pageNames: [String] = []
                var maxIdInPage = retryLastId
                
                retryOut.enumerateLines { line, _ in
                    let clean = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                    guard clean.hasPrefix("Row:") else { return }
                    if let name = extractDisplayName(from: clean),
                       seenNames.insert(name).inserted {
                        pageNames.append(name)
                        fileNames.append(name)
                    }
                    if let id = extractId(from: clean), id > maxIdInPage {
                        maxIdInPage = id
                    }
                }
                
                if pageNames.isEmpty { break }
                
                // Progressive callback for post-scan retry pages
                if let callback = onPageLoaded {
                    let pageFiles = pageNames.map { name in
                        ADBFile(
                            name: name,
                            path: normalizedPath + name,
                            isDirectory: false,
                            size: 0,
                            modificationDate: nil
                        )
                    }
                    callback(pageFiles)
                }
                
                retryLastId = maxIdInPage
                retryPageIndex += 1
                
                if pageNames.count < retryPageSize { break }
            }
            
            if !fileNames.isEmpty {
                AppLogger.log("📷 [listMediaFiles] Post-scan retry found \(fileNames.count) newly indexed files in \(retryPageIndex) pages", level: .info)
            }
            
            if fileNames.isEmpty {
                AppLogger.log("📷 [listMediaFiles] Post-scan retry also returned 0 files for \(dcimPath)", level: .info)
                return []
            }
        }
        
        AppLogger.log("⚙️ [listMediaFiles] Total filenames discovered: \(fileNames.count)", level: .info)
        
        // ── Pass 2: Batch stat for metadata (size, date) ──
        let basePath = normalizedPath.hasSuffix("/") ? String(normalizedPath.dropLast()) : normalizedPath
        let statFiles = await listFilesViaStat(path: basePath, adbPath: adbPath, exactNames: fileNames, timeoutPerBatch: 8.0)
        
        if statFiles.count > 0 {
            AppLogger.log("📷 [listMediaFiles] stat returned \(statFiles.count)/\(fileNames.count) files with metadata", level: .info)
            if statFiles.count < fileNames.count {
                let statNames = Set(statFiles.map { $0.name })
                var merged = statFiles
                for name in fileNames where !statNames.contains(name) {
                    merged.append(ADBFile(
                        name: name,
                        path: normalizedPath + name,
                        isDirectory: false,
                        size: 0,
                        modificationDate: nil
                    ))
                }
                AppLogger.log("📷 [listMediaFiles] Finished. \(merged.count) total files for \(dcimPath)", level: .info)
                return merged
            }
            return statFiles
        }
        
        // stat failed entirely — return names-only entries (size=0, no date)
        AppLogger.log("⚙️ [listMediaFiles] Stat failed, returning \(fileNames.count) files without metadata", level: .info)
        return fileNames.map { name in
            ADBFile(
                name: name,
                path: normalizedPath + name,
                isDirectory: false,
                size: 0,
                modificationDate: nil
            )
        }
    }
    
    // Helper for small directories — tries stat first (modern), falls back to ls -la (legacy)
    private static func listFilesWithDetails(path: String, adbPath: String, exactNames: [String]) async throws -> [ADBFile] {
        AppLogger.log("⚙️ [listFilesWithDetails] Retrieving details for \(exactNames.count) files in: \(path)")
        
        let statFiles = await listFilesViaStat(path: path, adbPath: adbPath, exactNames: exactNames)
        AppLogger.log("⚙️ [listFilesWithDetails] Strategy 1 (stat) returned \(statFiles.count)/\(exactNames.count) files")
        if statFiles.count == exactNames.count {
            return statFiles
        }
        
        AppLogger.log("⚙️ [listFilesWithDetails] Strategy 1 incomplete, trying Strategy 2 (ls -la)...")
        let lsFiles = await listFilesViaLs(path: path, adbPath: adbPath, exactNames: exactNames)
        AppLogger.log("⚙️ [listFilesWithDetails] Strategy 2 (ls -la) returned \(lsFiles.count)/\(exactNames.count) files")
        
        if lsFiles.count > statFiles.count {
            let lsNames = Set(lsFiles.map { $0.name })
            var merged = lsFiles
            for f in statFiles where !lsNames.contains(f.name) {
                merged.append(f)
            }
            AppLogger.log("⚙️ [listFilesWithDetails] Merged stat + ls-la returned \(merged.count)/\(exactNames.count) files")
            if merged.count == exactNames.count { return merged }
            return await fillMissing(from: exactNames, existing: merged, basePath: path, adbPath: adbPath)
        }
        
        if !statFiles.isEmpty {
            return await fillMissing(from: exactNames, existing: statFiles, basePath: path, adbPath: adbPath)
        }
        if !lsFiles.isEmpty {
            return await fillMissing(from: exactNames, existing: lsFiles, basePath: path, adbPath: adbPath)
        }
        
        AppLogger.log("⚠️ [listFilesWithDetails] Both stat and ls-la failed completely. Falling back to names-only.")
        return await fillMissing(from: exactNames, existing: [], basePath: path, adbPath: adbPath)
    }
    
    /// Parses a `content query` row to extract the `_display_name` value.
    ///
    /// Handles both single-projection and multi-projection formats:
    ///   Single: `Row: 0 _display_name=My Photo, Summer.jpg`
    ///   Multi:  `Row: 0 _display_name=My Photo, Summer.jpg, _id=12345`
    ///
    /// When `_id` is also projected, the value ends at `, _id=` boundary.
    /// When `_display_name` is the only projection, value runs to end of line.
    private static func extractDisplayName(from line: String) -> String? {
        guard let range = line.range(of: "_display_name=") else { return nil }
        var value = String(line[range.upperBound...])
        // If _id is also projected, strip it from the end: ", _id=12345"
        if let idBoundary = value.range(of: ", _id=") {
            value = String(value[..<idBoundary.lowerBound])
        }
        value = value.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value != "null" else { return nil }
        return value
    }
    
    /// Parses a `content query` row to extract the `_id` value for keyset pagination.
    /// Row format: `Row: 0 _display_name=file.jpg, _id=12345`
    private static func extractId(from line: String) -> Int? {
        guard let range = line.range(of: "_id=") else { return nil }
        let afterId = String(line[range.upperBound...])
        // _id may be followed by ", " (more columns) or end of line
        let idStr = afterId.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? afterId.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(idStr)
    }
    
    private static func listFilesViaStat(path: String, adbPath: String, exactNames: [String], timeoutPerBatch: Double = 30.0) async -> [ADBFile] {
        var files: [ADBFile] = []
        let batchSize = 50
        for i in stride(from: 0, to: exactNames.count, by: batchSize) {
            let end = min(i + batchSize, exactNames.count)
            let batch = Array(exactNames[i..<end])
            
            let escapedArgs = batch.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }.joined(separator: " ")
            let command = "cd '\(path.replacingOccurrences(of: "'", with: "'\\''"))' && stat -c '%A|%s|%Y|%n' \(escapedArgs)"
            
            let batchStart = Date()
            AppLogger.log("⚙️ [listFilesViaStat] Executing stat batch of \(batch.count) files in: \(path)")
            let (code, output, error) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: timeoutPerBatch
            )
            let batchElapsed = Date().timeIntervalSince(batchStart)
            AppLogger.log("⚙️ [listFilesViaStat] Batch result - Code: \(code), Elapsed: \(String(format: "%.3fs", batchElapsed)), Output length: \(output.count) chars")
            if !error.isEmpty {
                AppLogger.log("⚠️ [listFilesViaStat] Batch stderr: \(error)")
            }
            
            guard !output.isEmpty else { continue }
            
            output.enumerateLines { line, _ in
                // Strip \r to handle carriage returns from ADB shell output.
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
        let lsStart = Date()
        AppLogger.log("⚙️ [listFilesViaLs] Executing ls -la on: \(path)")
        let (code, output, error) = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 60.0
        )
        let lsElapsed = Date().timeIntervalSince(lsStart)
        AppLogger.log("⚙️ [listFilesViaLs] ls -la result - Code: \(code), Elapsed: \(String(format: "%.3fs", lsElapsed)), Output length: \(output.count) chars")
        if !error.isEmpty {
            AppLogger.log("⚠️ [listFilesViaLs] ls -la stderr: \(error)")
        }
        guard code == 0 else { return [] }
        
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Build a dictionary keyed by filename for O(1) lookup to optimize performance.
        var linesByName: [String: String] = [:]
        linesByName.reserveCapacity(exactNames.count)
        
        output.enumerateLines { line, _ in
            let cleanLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            // Extract filename from end of ls -la line.
            // Format: "drwxrwx--x 2 root sdcard_rw 4096 2025-05-22 11:01 filename"
            // The filename is everything after the last date+time columns.
            let parts = cleanLine.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 7 else { return }
            
            // Find the date columns (YYYY-MM-DD HH:MM) to extract filename after them
            for idx in 3..<(parts.count - 1) {
                let candidate = String(parts[idx])
                if candidate.count == 10 && candidate.contains("-") {
                    let next = String(parts[idx + 1])
                    if next.count == 5 && next.contains(":") {
                        // Everything after date+time is the filename (may contain spaces)
                        let nameStartIndex = cleanLine.range(of: next, range: cleanLine.startIndex..<cleanLine.endIndex)?.upperBound
                        if let start = nameStartIndex {
                            let name = cleanLine[start...].trimmingCharacters(in: .whitespaces)
                            if !name.isEmpty {
                                linesByName[name] = cleanLine
                            }
                        }
                        return
                    }
                }
            }
        }
        
        // Now look up each exactName in O(1)
        var files: [ADBFile] = []
        files.reserveCapacity(exactNames.count)
        
        for exactName in exactNames {
            guard let cleanLine = linesByName[exactName] else { continue }
            
            let parts = cleanLine.split(whereSeparator: { $0.isWhitespace })
            guard parts.count >= 7 else { continue }
            
            let perms = String(parts[0])
            let isDir = perms.hasPrefix("d")
            
            // Find the date columns to extract size
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
                if di > 0 { size = UInt64(parts[di - 1]) ?? 0 }
                let dateStr = "\(parts[di]) \(parts[di + 1])"
                modDate = dateFormatter.date(from: dateStr)
            } else {
                if parts.count >= 8 { size = UInt64(parts[4]) ?? 0 }
            }
            
            let fullPath = path.hasSuffix("/") ? path + exactName : path + "/" + exactName
            files.append(ADBFile(name: exactName, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
        }
        return files
    }
    
    // MARK: - Raw-name fallback (guarantees no files are lost, but filters deleted ghosts)
    private static func fillMissing(from exactNames: [String], existing: [ADBFile], basePath: String, adbPath: String) async -> [ADBFile] {
        let parsed = Set(existing.map { $0.name })
        var result = existing
        for name in exactNames where !parsed.contains(name) {
            let fullPath = basePath.hasSuffix("/") ? basePath + name : basePath + "/" + name
            let escapedPath = FileNameHelper.escapeForSingleQuotedShell(fullPath)
            
            // Verify if the file actually exists. FUSE dcache or MediaStore might return 
            // recently deleted files as ghost entries.
            let (code, _, _) = await Shell.runAsyncWithTimeout(
                adbPath,
                args: deviceArgs(["shell", "[ -e '\(escapedPath)' ]"]),
                timeoutSeconds: 2.0
            )
            
            if code == 0 {
                let isDir = !name.contains(".")
                result.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: 0, modificationDate: nil))
            } else {
                AppLogger.log("👻 [fillMissing] Dropped ghost file (does not exist): \(name)")
            }
        }
        return result
    }
    
    // MARK: - Progressive batch metadata fetcher (for large directories)
    
    /// Fetches file metadata (size, date, isDirectory) in batches of 50 for large directories.
    /// After each batch, calls `onBatch` with an array of `ADBFile` entries that now have real metadata.
    /// The caller can update the UI progressively. Respects task cancellation between batches.
    static func fetchMetadataBatched(
        path: String,
        fileNames: [String],
        onBatch: @escaping ([ADBFile]) -> Void
    ) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        let batchSize = 50
        let totalBatches = (fileNames.count + batchSize - 1) / batchSize
        var completedFiles = 0
        var resolvedNames: Set<String> = []
        
        for batchIndex in 0..<totalBatches {
            // Check cancellation between batches
            guard !Task.isCancelled else {
                print("📂 ADB: Metadata batch loading cancelled at batch \(batchIndex + 1)/\(totalBatches)")
                return
            }
            
            let start = batchIndex * batchSize
            let end = min(start + batchSize, fileNames.count)
            let batch = Array(fileNames[start..<end])
            
            let escapedArgs = batch.map { name in
                let escaped = name.replacingOccurrences(of: "'", with: "'\\''")
                return "'\(escaped)'"
            }.joined(separator: " ")
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            let command = "cd '\(escapedPath)' && stat -c '%A|%s|%Y|%n' \(escapedArgs) 2>/dev/null"
            
            let (code, output, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 15.0
            )
            
            var batchFiles: [ADBFile] = []
            
            // Parse stdout regardless of exit code — stat outputs results
            // for successful files even when some files in the batch fail.
            if !output.isEmpty {
                output.enumerateLines { line, _ in
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
                    batchFiles.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
                }
            }
            
            completedFiles += batch.count
            
            if !batchFiles.isEmpty {
                onBatch(batchFiles)
                print("📂 ADB: Metadata batch \(batchIndex + 1)/\(totalBatches) — got \(batchFiles.count) files (\(completedFiles)/\(fileNames.count) total)")
            } else {
                print("📂 ADB: Metadata batch \(batchIndex + 1)/\(totalBatches) — stat returned nothing for \(batch.count) files")
            }
            
            // Track which files stat resolved
            for f in batchFiles { resolvedNames.insert(f.name) }
        }
        
        // ── Retry pass: individual ls -ld for files that stat missed ──────────
        let missedNames = fileNames.filter { !resolvedNames.contains($0) }
        if !missedNames.isEmpty && !Task.isCancelled {
            print("📂 ADB: \(missedNames.count) files missed by stat — retrying with individual ls -ld")
            
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm"
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            
            // Process in small sub-batches of 10 to give periodic UI updates
            let retryBatchSize = 10
            for retryStart in stride(from: 0, to: missedNames.count, by: retryBatchSize) {
                guard !Task.isCancelled else { break }
                
                let retryEnd = min(retryStart + retryBatchSize, missedNames.count)
                let retryBatch = Array(missedNames[retryStart..<retryEnd])
                var recovered: [ADBFile] = []
                
                for name in retryBatch {
                    guard !Task.isCancelled else { break }
                    let escapedName = name.replacingOccurrences(of: "'", with: "'\\''")
                    let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
                    let cmd = "ls -ld '\(escapedPath)/\(escapedName)'"
                    let (_, lsOut, _) = await Shell.runAsyncWithTimeout(
                        adbPath, args: deviceArgs(["shell", cmd]), timeoutSeconds: 5.0
                    )
                    let line = lsOut.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
                    guard !line.isEmpty else { continue }
                    
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    guard parts.count >= 7 else { continue }
                    
                    let perms = String(parts[0])
                    let isDir = perms.hasPrefix("d")
                    var size: UInt64 = 0
                    var modDate: Date? = nil
                    
                    // Find date columns (YYYY-MM-DD HH:MM) and size before them
                    for idx in 3..<(parts.count - 1) {
                        let candidate = String(parts[idx])
                        if candidate.count == 10 && candidate.contains("-") {
                            let next = String(parts[idx + 1])
                            if next.count == 5 && next.contains(":") {
                                if idx > 0 { size = UInt64(parts[idx - 1]) ?? 0 }
                                modDate = dateFormatter.date(from: "\(candidate) \(next)")
                                break
                            }
                        }
                    }
                    
                    let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
                    recovered.append(ADBFile(name: name, path: fullPath, isDirectory: isDir, size: size, modificationDate: modDate))
                }
                
                if !recovered.isEmpty {
                    onBatch(recovered)
                    print("📂 ADB: ls -ld retry recovered \(recovered.count) files (\(retryStart + retryEnd)/\(missedNames.count) retried)")
                }
            }
        }
        
        print("📂 ADB: Metadata batch loading complete — \(completedFiles)/\(fileNames.count) files processed, \(missedNames.count) needed ls -ld retry")
    }

    static func pullFileWithProgress(
        devicePath: String,
        localPath: String
    ) -> AsyncThrowingStream<(UInt64, Double), Error> {
        return AsyncThrowingStream { continuation in
            let adbPath = getADBPath()
            
            Task {
                var exitCode: Int32 = 0
                var adbError = ""
                
                await withTaskGroup(of: Void.self) { group in
                    // Task 1: Run the download
                    group.addTask {
                        let (code, _, err) = await Shell.runAsync(adbPath, args: deviceArgs(["pull", "-a", devicePath, localPath]))
                        exitCode = code
                        adbError = err
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
                
                if exitCode != 0 {
                    let errMsg = adbError.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: NSError(
                        domain: "ADBPull",
                        code: Int(exitCode),
                        userInfo: [NSLocalizedDescriptionKey: errMsg.isEmpty ? "Download failed" : errMsg]
                    ))
                } else {
                    // Send final update
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: localPath),
                       let finalSize = attrs[.size] as? UInt64 {
                        continuation.yield((finalSize, 0))
                    }
                    continuation.finish()
                }
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
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = deviceArgs(["push", localPath, devicePath])
                process.environment = Shell.activeADBEnvironment
                process.standardOutput = stdout
                process.standardError = stderr
                
                do {
                    try AppProcessLifecycle.run(process)
                    defer { AppProcessLifecycle.didExit(process) }
                    let pid = process.processIdentifier
                    
                    // Start cancellation monitor AFTER process is running
                    DispatchQueue.global(qos: .userInitiated).async {
                        while process.isRunning {
                            if cancellationCheck() {
                                AppLogger.log("🛑 Upload: Cancellation detected! Killing PID \(pid)...", level: .warning)
                                kill(pid, SIGKILL)
                                break
                            }
                            Thread.sleep(forTimeInterval: 0.1) // 100ms
                        }
                    }
                    
                    // Start progress polling AFTER process is running — only for files >= 20 MB to avoid ADB stat command contention on small files
                    if totalBytes >= 10 * 1024 * 1024 {
                        DispatchQueue.global(qos: .userInitiated).async {
                            var lastSize: UInt64 = 0
                            var lastCheck = Date()
                            var consecutiveFailures = 0
                            
                            // Wait a moment for transfer to start
                            Thread.sleep(forTimeInterval: 0.8)
                            
                            let escapedPath = FileNameHelper.escapeForShell(devicePath)
                            
                            while process.isRunning && !cancellationCheck() {
                                // Get remote file size using stat (synchronous for simplicity)
                                let (statCode, statOutput, _) = Shell.run(
                                    adbPath,
                                    args: deviceArgs(["shell", "stat", "-c%s", escapedPath])
                                )
                                
                                if statCode == 0, let currentSize = UInt64(statOutput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                    consecutiveFailures = 0
                                    let now = Date()
                                    let timeDiff = now.timeIntervalSince(lastCheck)
                                    
                                    if currentSize > lastSize && timeDiff >= 0.1 {
                                        let bytesDiff = currentSize - lastSize
                                        let speed = Double(bytesDiff) / timeDiff / (1024 * 1024) // MB/s
                                        
                                        continuation.yield((currentSize, speed))
                                        
                                        lastSize = currentSize
                                        lastCheck = now
                                    }
                                } else {
                                    consecutiveFailures += 1
                                    if consecutiveFailures >= 15 && !process.isRunning {
                                        break
                                    }
                                }
                                
                                // Relaxed polling interval to prevent ADB daemon socket starvation over USB
                                Thread.sleep(forTimeInterval: 1.5)
                            }
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
                        
                        // If compression isn't supported, retry without -z
                        let lowerMsg = message.lowercased()
                        let isCompressionError = lowerMsg.contains("unknown option") ||
                                                 lowerMsg.contains("unrecognized option") ||
                                                 lowerMsg.contains("unknown flags") ||
                                                 lowerMsg.contains("compression")
                        
                        if isCompressionError, totalBytes > 50 * 1024 * 1024 {
                            AppLogger.log("⚠️ ADB push compression not supported (error: \(message)), retrying without compression", level: .warning)
                            let retryProcess = Process()
                            let retryOut = Pipe()
                            let retryErr = Pipe()
                            retryProcess.executableURL = URL(fileURLWithPath: adbPath)
                            retryProcess.arguments = deviceArgs(["push", localPath, devicePath])
                            retryProcess.environment = Shell.activeADBEnvironment
                            retryProcess.standardOutput = retryOut
                            retryProcess.standardError = retryErr
                            
                            do {
                                try AppProcessLifecycle.run(retryProcess)
                                defer { AppProcessLifecycle.didExit(retryProcess) }
                                retryProcess.waitUntilExit()
                                if retryProcess.terminationStatus == 0 {
                                    if !cancellationCheck() {
                                        continuation.yield((totalBytes, 0))
                                    }
                                    continuation.finish()
                                    return
                                } else {
                                    let retryOutputData = retryOut.fileHandleForReading.readDataToEndOfFile()
                                    let retryErrorData = retryErr.fileHandleForReading.readDataToEndOfFile()
                                    let retryOutMsg = String(data: retryOutputData, encoding: .utf8) ?? ""
                                    let retryErrMsg = String(data: retryErrorData, encoding: .utf8) ?? ""
                                    let retryFinalMsg = (retryErrMsg.isEmpty ? retryOutMsg : retryErrMsg).trimmingCharacters(in: .whitespacesAndNewlines)
                                    
                                    AppLogger.log("❌ Retry push failed: \(retryFinalMsg)", level: .error)
                                    continuation.finish(throwing: NSError(
                                        domain: "ADBPush",
                                        code: Int(retryProcess.terminationStatus),
                                        userInfo: [NSLocalizedDescriptionKey: retryFinalMsg.isEmpty ? "Upload failed" : retryFinalMsg]
                                    ))
                                    return
                                }
                            } catch {
                                AppLogger.log("❌ Retry push process throw: \(error)", level: .error)
                                continuation.finish(throwing: error)
                                return
                            }
                        }
                        
                        AppLogger.log("❌ ADB Push exited with code \(process.terminationStatus): \(message)", level: .error)
                        continuation.finish(throwing: NSError(
                            domain: "ADBPush",
                            code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Upload failed" : message]
                        ))
                    }
                    
                } catch {
                    AppLogger.log("❌ ADB Push Error: \(error)", level: .error)
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
    static func deleteFile(devicePath: String, cancellationCheck: @escaping () -> Bool = { false }) async throws {
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        let adbPath = getADBPath()
        
        // Escape single quotes in the path
        let escapedPath = devicePath.replacingOccurrences(of: "'", with: "'\\''")
        
        // Strategy 1: Use rm -rf with single-quoted path (handles most cases)
        let command = "rm -rf '\(escapedPath)'"
        let (code, _, error, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", command]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        // rm -rf with -f flag can return 0 even on failure, so verify the file is gone
        let (_, checkOut, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
        )
        let stillExists = checkOut.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS"
        
        if !stillExists {
            // Successfully deleted
            return
        }
        
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        // Strategy 2: Pass rm and path as separate arguments (avoids shell re-parsing)
        // This handles filenames with spaces, dots, and special characters better
        print("⚠️ Delete: File still exists after rm -rf, retrying with separate args...")
        let (code2, _, error2, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", "rm", "-rf", devicePath]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        // Verify again
        let (_, checkOut2, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
        )
        let stillExists2 = checkOut2.trimmingCharacters(in: .whitespacesAndNewlines) == "EXISTS"
        
        if !stillExists2 {
            return
        }
        
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        // Strategy 3: Try verbose rm without -f to capture the EXACT error message from Android
        print("⚠️ Delete: Still exists, trying rm -rv without -f to capture error...")
        let (code3, out3, err3, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", "rm -rv '\(escapedPath)'"]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
        )
        
        if cancellationCheck() {
            throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
        }
        
        // Final verification
        let (_, checkOut3, _, _) = await Shell.runWithProgressCancellable(
            adbPath,
            args: deviceArgs(["shell", "[ -e '\(escapedPath)' ] && echo EXISTS || echo GONE"]),
            progressCallback: { _ in },
            cancellationCheck: cancellationCheck
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
    
    /// Deletes multiple files or folders on the device in chunks using batched `rm -rf` commands.
    /// This drastically reduces ADB round-trips and prevents device UI freezes/watchdog reboots during bulk deletes.
    /// - Parameters:
    ///   - devicePaths: Array of device paths to delete
    ///   - onChunkCompleted: Callback invoked after each chunk completes, passing deleted paths in that chunk
    ///   - cancellationCheck: Closure checking if cancellation was requested
    static func batchDeleteFiles(
        devicePaths: [String],
        onChunkCompleted: @escaping ([String]) -> Void = { _ in },
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws {
        guard !devicePaths.isEmpty else { return }
        
        let adbPath = getADBPath()
        let chunkSize = 20
        
        for i in stride(from: 0, to: devicePaths.count, by: chunkSize) {
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
            let chunk = Array(devicePaths[i..<min(i + chunkSize, devicePaths.count)])
            let escapedPaths = chunk.map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            let command = "rm -rf " + escapedPaths.joined(separator: " ")
            
            let (code, _, error, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: deviceArgs(["shell", command]),
                progressCallback: { _ in },
                cancellationCheck: cancellationCheck
            )
            
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
            if code != 0 {
                // Fallback to individual deletion for this chunk if batch command failed
                print("⚠️ Batch delete chunk failed (code \(code)): \(error) — retrying individually")
                for path in chunk {
                    if cancellationCheck() {
                        throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
                    }
                    try await deleteFile(devicePath: path, cancellationCheck: cancellationCheck)
                }
            }
            
            onChunkCompleted(chunk)
            
            // Brief pause between chunks to let storage I/O and device system breathe
            if i + chunkSize < devicePaths.count {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }
    }
    
    /// Moves/renames multiple files in chunks using batched `mv 'src1' 'dst1' && mv 'src2' 'dst2' ...` commands.
    /// This drastically speeds up bulk moves (e.g. moving hundreds of files to Trash or restoring them).
    /// - Parameters:
    ///   - moves: Array of tuple (src: String, dst: String)
    ///   - onChunkCompleted: Callback invoked after each chunk completes, passing the completed moves in that chunk
    ///   - cancellationCheck: Closure checking if cancellation was requested
    static func batchMoveFiles(
        moves: [(src: String, dst: String)],
        onChunkCompleted: @escaping ([(src: String, dst: String)]) -> Void = { _ in },
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws {
        guard !moves.isEmpty else { return }
        
        let adbPath = getADBPath()
        let chunkSize = 20
        
        for i in stride(from: 0, to: moves.count, by: chunkSize) {
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
            let chunk = Array(moves[i..<min(i + chunkSize, moves.count)])
            var moveCommands: [String] = []
            for item in chunk {
                let parentDir = (item.dst as NSString).deletingLastPathComponent
                let escParent = parentDir.replacingOccurrences(of: "'", with: "'\\''")
                let escSrc = item.src.replacingOccurrences(of: "'", with: "'\\''")
                let escDst = item.dst.replacingOccurrences(of: "'", with: "'\\''")
                moveCommands.append("mkdir -p '\(escParent)' && mv '\(escSrc)' '\(escDst)'")
            }
            
            let batchCommand = moveCommands.joined(separator: " && ")
            let (code, _, error, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: deviceArgs(["shell", batchCommand]),
                progressCallback: { _ in },
                cancellationCheck: cancellationCheck
            )
            
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
            if code != 0 {
                print("⚠️ Batch move chunk failed (code \(code)): \(error) — retrying individually")
                for item in chunk {
                    if cancellationCheck() {
                        throw NSError(domain: "ADB", code: -1, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
                    }
                    try await renameFile(oldPath: item.src, newPath: item.dst)
                }
            }
            
            onChunkCompleted(chunk)
            
            if i + chunkSize < moves.count {
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
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
        
        let (code, _, error) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
        
        if code != 0 {
            // Check for specific error types
            if error.contains("Read-only file system") || error.contains("read-only") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "File system is read-only"]
                )
            } else if error.contains("Permission denied") || error.contains("permission denied") {
                throw NSError(
                    domain: "ADB",
                    code: Int(code),
                    userInfo: [NSLocalizedDescriptionKey: "Permission denied"]
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
                    userInfo: [NSLocalizedDescriptionKey: error.isEmpty ? "Unknown error occurred" : error]
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
    static func copyFile(
        from sourcePath: String,
        to destinationPath: String,
        isDirectory: Bool = false,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws {
        let adbPath = getADBPath()
        let escapedSource = sourcePath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDest = destinationPath.replacingOccurrences(of: "'", with: "'\\''")
        
        if isDirectory {
            // Step 1: Create the directory (fast)
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            let mkdirCmd = "mkdir -p '\(escapedDest)'"
            let (mkdirCode, _, mkdirError) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", mkdirCmd]))
            
            if mkdirCode != 0 {
                throw NSError(domain: "ADB", code: Int(mkdirCode), userInfo: [NSLocalizedDescriptionKey: mkdirError.isEmpty ? "Failed to create folder" : mkdirError])
            }
            
            // Step 2: Copy contents if any exist (separate call, only if needed)
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            let cpCmd = "cp -r '\(escapedSource)/.' '\(escapedDest)/' 2>/dev/null || true"
            let (code, _, _, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: deviceArgs(["shell", cpCmd]),
                progressCallback: { _ in },
                cancellationCheck: cancellationCheck
            )
            
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            // Ignore result - empty folder might fail but that's OK
            
        } else {
            // Regular file copy
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            let command = "cp '\(escapedSource)' '\(escapedDest)'"
            let (code, output, error, _) = await Shell.runWithProgressCancellable(
                adbPath,
                args: deviceArgs(["shell", command]),
                progressCallback: { _ in },
                cancellationCheck: cancellationCheck
            )
            
            if cancellationCheck() {
                throw NSError(domain: "ADB", code: -999, userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"])
            }
            
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
        
        // Protect the TLS handshake from background restartServer() calls.
        isPairingInProgress = true
        defer { isPairingInProgress = false }
        
        func attemptPairing() async -> (Int32, String, String) {
            print("📶 ADB: Pairing with \(target)...")
            return await Shell.runAsyncWithTimeout(
                adbPath, args: ["pair", target, code], timeoutSeconds: 15.0
            )
        }
        
        var (exitCode, output, error) = await attemptPairing()
        var combined = output + error
        print("📶 ADB Pair result: code=\(exitCode), output=\(combined)")
        
        // Protocol fault = local ADB daemon failure; phone never saw the attempt
        // so the pairing code is still valid. Restart daemon and retry once.
        if isProtocolError(combined) {
            print("🔄 ADB: Protocol fault during pairing — restarting and retrying...")
            isPairingInProgress = false
            let restarted = await restartServer()
            isPairingInProgress = true
            
            if restarted {
                (exitCode, output, error) = await attemptPairing()
                combined = output + error
                print("📶 ADB Pair retry result: code=\(exitCode), output=\(combined)")
            }
        }
        
        if isProtocolError(combined) {
            return (false, "Connection to ADB service was interrupted. Please re-open 'Pair device with pairing code' on your phone and enter the new code.")
        }
        
        if exitCode == 0 && (combined.lowercased().contains("successfully paired") || combined.lowercased().contains("paired")) {
            hasRestarted = false
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

        WirelessDiscovery.shared.start()
        let records = rememberedWirelessDevices
        let expected = records.first {
            WirelessEndpoint.address(from: $0.target)?.host == ip || (hostname != nil && $0.hostname == hostname)
        }?.hardwareSerial
        let deadline = Date().addingTimeInterval(15)
        var attemptedAt: [String: Date] = [:]
        var lastFailure = ""
        var endpoints = WirelessDiscovery.shared.endpoints
        // A supplied address can work even when multicast is blocked. Discovery runs concurrently.
        var discoveryTask: Task<[WirelessEndpoint], Never>? = Task {
            let (code, output, _) = await Shell.runAsyncWithTimeout(adbPath,
                args: ["mdns", "services"], timeoutSeconds: 1)
            return code == 0 ? WirelessEndpoint.parse(output) : []
        }
        defer { discoveryTask?.cancel() }
        while Date() < deadline, !Task.isCancelled, !isPairingInProgress {
            var seen = Set<WirelessEndpoint>()
            endpoints = (WirelessDiscovery.shared.endpoints + endpoints).filter { seen.insert($0).inserted }
            var targets = endpoints.filter { endpoint in
                guard endpoint.isConnectService else { return false }
                if let expected { return endpoint.hardwareSerial == expected }
                return endpoint.host == ip || (hostname != nil && endpoint.hostname == hostname)
            }.map(\.target)
            // Current advertised ports precede stale supplied ports. No discovery wait is required.
            targets.append(WirelessEndpoint.target(host: ip, port: UInt16(port) ?? 5555))
            if let hostname, let port = UInt16(port) { targets.append(WirelessEndpoint.target(host: hostname, port: port)) }
            var seenTargets = Set<String>()
            for target in targets where seenTargets.insert(target).inserted &&
                (attemptedAt[target].map { Date().timeIntervalSince($0) >= 2.5 } ?? true) {
                guard !Task.isCancelled, Date() < deadline else { break }
                attemptedAt[target] = Date()
                let result = await connectAndVerifyWirelessTarget(target,
                    connectTimeout: min(2, deadline.timeIntervalSinceNow), verificationAttempts: 1,
                    expectedHardwareSerial: expected)
                guard !Task.isCancelled else { return (false, "Connection cancelled", nil) }
                if result.success { return (true, "Connected to \(target)", target) }
                lastFailure = result.output
                if wirelessConnectionRequiresRepair(lastFailure) {
                    return (false, "ADB authorization was rejected. Pair this Mac with the phone again. \(lastFailure)", nil)
                }
            }
            if let task = discoveryTask {
                endpoints = await task.value
                discoveryTask = nil
            } else {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let (code, output, _) = await Shell.runAsyncWithTimeout(adbPath,
                    args: ["mdns", "services"], timeoutSeconds: 1)
                endpoints = code == 0 ? WirelessEndpoint.parse(output) : []
            }
        }
        return (false, Task.isCancelled ? "Connection cancelled" :
            "Cannot reach \(ip). Keep the phone awake and make sure both devices are on the same Wi-Fi. The saved pairing was retained." +
            (lastFailure.isEmpty ? "" : " \(lastFailure)"), nil)
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
    static func appManagedWirelessCleanupTargets() -> [String: Int] {
        var targets = appManagedWirelessTargets
        if let active = activeDeviceSerial, isWirelessSerial(active) {
            targets.insert(active)
        }
        return Dictionary(uniqueKeysWithValues: targets.map {
            ($0, Shell.serverPortBySerial[$0] ?? (Shell.useDefaultServer ? 5037 : Shell.appADBServerPort))
        })
    }

    static func disconnectAppManagedWireless(timeoutSeconds: Double = 3.0, allowDuringTermination: Bool = false) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }

        let targets = appManagedWirelessCleanupTargets()

        // Targets are independent. Disconnecting them concurrently also gives quit
        // cleanup one fixed timeout instead of one timeout per paired device.
        await withTaskGroup(of: Void.self) { group in
            for (target, port) in targets {
                group.addTask {
                    _ = await Shell.runAsyncWithTimeout(
                        adbPath,
                        args: ["disconnect", target],
                        timeoutSeconds: timeoutSeconds,
                        environment: Shell.serverEnvironment(port: port),
                        allowDuringTermination: allowDuringTermination
                    )
                }
            }
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
        WirelessEndpoint.address(from: serial) != nil || serial.contains("._adb-tls-")
    }

    static func extractHardwareSerial(from serviceName: String) -> String? {
        WirelessEndpoint.hardwareSerial(from: serviceName)
    }

    /// get-serialno returns an IP:port for TCP transports, not the phone's hardware identity.
    static func getHardwareSerial(for target: String) async -> String? {
        if let cached = hardwareSerialCache[target] { return cached }
        if !isWirelessSerial(target) { return target }
        if let serial = extractHardwareSerial(from: target) {
            hardwareSerialCache[target] = serial
            return serial
        }
        let path = getADBPath()
        guard !path.isEmpty, !Task.isCancelled else { return nil }
        let (code, output, _) = await Shell.runAsyncWithTimeout(path,
            args: ["-s", target, "shell", "getprop ro.serialno; getprop ro.boot.serialno"],
            timeoutSeconds: 2)
        guard code == 0, !Task.isCancelled,
              let serial = output.split(whereSeparator: { $0.isNewline })
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty && $0 != "unknown" && !isWirelessSerial($0) }) else { return nil }
        hardwareSerialCache[target] = serial
        return serial
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
    
    private static func normalizeMediaPath(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/sdcard") {
            p = "/storage/emulated/0" + p.dropFirst(7)
        } else if p.hasPrefix("sdcard") {
            p = "/storage/emulated/0" + p.dropFirst(6)
        } else if p.hasPrefix("/mnt/sdcard") {
            p = "/storage/emulated/0" + p.dropFirst(11)
        }
        return p
    }

    /// Triggers the Android media scanner for a specific file path so it appears in the Gallery
    /// and Google Photos immediately. Scans the file using content call, content insert, cmd media.scanner, and broadcast intent.
    static func triggerMediaScan(path: String) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        let normPath = normalizeMediaPath(path)
        let escapedNorm = normPath.replacingOccurrences(of: "'", with: "'\\''")
        let escapedRaw = path.replacingOccurrences(of: "'", with: "'\\''")
        
        var parts: [String] = []
        // 1. Android 10+: ContentProvider scan_file IPC call
        parts.append("content call --uri content://media --method scan_file --arg '\(escapedNorm)' >/dev/null 2>&1")
        // 2. Direct MediaStore DB record insertion fallback
        parts.append("content insert --uri content://media/external/file --bind _data:s:'\(escapedNorm)' >/dev/null 2>&1")
        // 3. Android 11/12 service scan
        parts.append("cmd media.scanner scan '\(escapedNorm)' >/dev/null 2>&1")
        // 4. Legacy broadcast intent fallback
        parts.append("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedNorm)' >/dev/null 2>&1")
        if normPath != path {
            parts.append("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedRaw)' >/dev/null 2>&1")
        }
        
        let command = parts.joined(separator: "; ")
        _ = await Shell.runAsync(adbPath, args: deviceArgs(["shell", command]))
    }
    
    /// Lightweight post-batch media scan: scans multiple files in chunks so Google Photos picks up
    /// all newly uploaded files. Called once after a batch upload completes.
    /// Uses chunks of 20 files to avoid blocking ADB for too long.
    static func triggerMediaScanForFiles(_ filePaths: [String]) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty, !filePaths.isEmpty else { return }
        
        // Chunk into groups of 20 to avoid shell command length limits and ADB bottleneck
        let chunkSize = 20
        for i in stride(from: 0, to: filePaths.count, by: chunkSize) {
            let chunk = Array(filePaths[i..<min(i + chunkSize, filePaths.count)])
            
            var commandParts: [String] = []
            for path in chunk {
                let normPath = normalizeMediaPath(path)
                let escapedNorm = normPath.replacingOccurrences(of: "'", with: "'\\''")
                let escapedRaw = path.replacingOccurrences(of: "'", with: "'\\''")
                
                // 1. Android 10+: ContentProvider call directly to MediaProvider
                commandParts.append("content call --uri content://media --method scan_file --arg '\(escapedNorm)' >/dev/null 2>&1")
                // 2. Direct MediaStore DB record insertion fallback
                commandParts.append("content insert --uri content://media/external/file --bind _data:s:'\(escapedNorm)' >/dev/null 2>&1")
                // 3. Android 11/12 service scan
                commandParts.append("cmd media.scanner scan '\(escapedNorm)' >/dev/null 2>&1")
                // 4. Legacy broadcast intent fallback (canonical path + raw path)
                commandParts.append("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedNorm)' >/dev/null 2>&1")
                if normPath != path {
                    commandParts.append("am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedRaw)' >/dev/null 2>&1")
                }
            }
            
            let command = commandParts.joined(separator: "; ")
            
            // Give each chunk 10 seconds to finish
            _ = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 10.0
            )
            
            // Sleep briefly between chunks to let the Android system breathe
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        
        // Post-batch volume rescan trigger: forces MediaStore to sync external_primary volume
        let volumeCmd = "content call --uri content://media --method scan_volume --arg external_primary >/dev/null 2>&1; content call --uri content://media --method scan_volume --arg external >/dev/null 2>&1"
        _ = await Shell.runAsyncWithTimeout(
            adbPath, args: deviceArgs(["shell", volumeCmd]), timeoutSeconds: 5.0
        )
    }
    
    /// Triggers the media scanner for common media directories (DCIM/Camera, Pictures, etc.)
    /// so content:// fallback queries work even on devices where files were pushed via ADB.
    /// Called on device connection to pre-warm the MediaStore index.
    static func triggerMediaScanForCommonPaths() async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty else { return }
        
        let paths = [
            "/storage/emulated/0/DCIM/Camera",
            "/storage/emulated/0/DCIM",
            "/storage/emulated/0/Pictures",
            "/storage/emulated/0/Movies"
        ]
        
        AppLogger.log("📱 [MediaScanner] Pre-scanning \(paths.count) common media paths...")
        
        // Use 'cmd media.scanner scan' for each directory — it's recursive and fast
        for path in paths {
            let escapedPath = path.replacingOccurrences(of: "'", with: "'\\''")
            let command = "cmd media.scanner scan '\(escapedPath)' >/dev/null 2>&1"
            let (code, _, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: deviceArgs(["shell", command]), timeoutSeconds: 10.0
            )
            if code != 0 {
                // Try legacy broadcast as fallback
                let broadcastCmd = "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d 'file://\(escapedPath)' >/dev/null 2>&1"
                _ = await Shell.runAsyncWithTimeout(
                    adbPath, args: deviceArgs(["shell", broadcastCmd]), timeoutSeconds: 5.0
                )
            }
        }
        
        AppLogger.log("📱 [MediaScanner] Pre-scan complete.")
    }

    // MARK: - Remote Timestamp Preservation

    /// Sets modification timestamps on Android files to match their original Mac source dates.
    ///
    /// Uses `touch -t` (POSIX format: `yyyyMMddHHmm.ss`, UTC), which is supported by Toybox
    /// on all modern Android versions (Android 6+). Batches commands in chunks of 50 per
    /// `adb shell` call to avoid Android's shell command-length limits and minimise round-trips.
    ///
    /// This must be called **before** `triggerMediaScanForFiles` so that MediaStore picks up
    /// the correct modification time when it indexes the file.
    ///
    /// - Parameter timestamps: Array of (devicePath, date) pairs to stamp.
    static func setRemoteTimestamps(_ timestamps: [(devicePath: String, date: Date)]) async {
        let adbPath = getADBPath()
        guard !adbPath.isEmpty, !timestamps.isEmpty else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmm.ss"
        // Use the Mac's local timezone — Android's `touch -t` interprets the timestamp as device
        // local time, so formatting in UTC would shift the time by the UTC offset (e.g. -5:30 in IST).

        // Chunk into groups of 50 to stay well within Android shell limits (~128 KB)
        let chunkSize = 50
        let chunks = stride(from: 0, to: timestamps.count, by: chunkSize).map {
            Array(timestamps[$0..<min($0 + chunkSize, timestamps.count)])
        }

        for chunk in chunks {
            let commands = chunk.map { entry -> String in
                let ts = formatter.string(from: entry.date)
                let escaped = FileNameHelper.escapeForShell(entry.devicePath)
                return "touch -t \(ts) \(escaped)"
            }
            let shellCommand = commands.joined(separator: "; ")
            let (code, _, err) = await Shell.runAsync(adbPath, args: deviceArgs(["shell", shellCommand]))
            if code != 0 {
                AppLogger.log("⚠️ [setRemoteTimestamps] touch failed for chunk: \(err)", level: .warning)
            }
        }
    }

    // MARK: - Get File Info
    
    /// Gets detailed information about a file or folder.
    /// - Parameters:
    ///   - path: Path to the file/folder.
    ///   - isDirectory: Pass true when the selected item is a folder so size uses `du`.
    /// - Returns: Dictionary with file properties
    static func getFileInfo(path: String, isDirectory: Bool = false) async throws -> [String: String] {
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

        // `stat %s` returns directory entry size for folders (often 4K/8K), not total content size.
        // For "Get Info", prefer `du -sk` so folder size matches actual contents.
        let typeSuggestsDirectory = info["type"]?.localizedCaseInsensitiveContains("directory") == true
        if isDirectory || typeSuggestsDirectory {
            if let folderBytes = await fetchSingleFolderSize(path: path) {
                info["size"] = String(folderBytes)
            } else {
                // Avoid showing misleading inode size when recursive size couldn't be computed.
                info.removeValue(forKey: "size")
            }
        }
        
        info["path"] = path
        return info
    }
}
