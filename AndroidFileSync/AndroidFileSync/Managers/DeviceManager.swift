//  DeviceManager.swift
//  (DEFINITIVE DETECTION FIX)
//

import Foundation
internal import Combine

@MainActor
class DeviceManager: ObservableObject {
    /// Launch-wide guard against repeating the expensive wireless reconnect loop.
    private static var hasAttemptedWirelessReconnectThisLaunch = false
    
    // MARK: - Published Properties
    
    @Published var isConnected = false
    @Published var isDetecting = true // Start in "detecting" state
    @Published var connectionType: ConnectionType = .none
    @Published var deviceName = "No Device"
    @Published var statusMessage = "Scanning for devices..."
    @Published var lastWirelessIP = ""
    /// All currently connected ADB devices (USB + wireless)
    @Published var availableDevices: [ADBManager.ConnectedDevice] = []
    /// Path to the physical SD card if one is inserted, e.g. "/storage/1A2B-3C4D"
    @Published var sdCardPath: String? = nil
    /// Storage stats keyed by path (internal / SD card)
    @Published var storageStats: [String: StorageInfo] = [:]

    struct StorageInfo {
        let usedBytes: Int64
        let totalBytes: Int64
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
        var usedText: String { "\(formatBytes(usedBytes)) used of \(formatBytes(totalBytes))" }

        private func formatBytes(_ bytes: Int64) -> String {
            let gb = Double(bytes) / 1_073_741_824
            if gb >= 1 { return String(format: "%.1f GB", gb) }
            let mb = Double(bytes) / 1_048_576
            return String(format: "%.0f MB", mb)
        }
    }

    private var adbAvailable = false
    private var usbMonitor: USBDeviceMonitor? = nil
    /// True when user explicitly disconnected — prevents auto-reconnect
    @Published var userDisconnected = false
    /// One-time flag: restart ADB server on first detection to apply env var
    private var hasRestartedServer = false
    /// Prevent overlapping detection runs that can flood ADB and mDNS queries.
    private var isDetectionInProgress = false
    private var pendingDetection = false
    /// Single in-flight wireless hunt task to avoid spawning one per detect cycle.
    private var wirelessHuntTask: Task<Void, Never>? = nil
    private static let savedWirelessPortByIPKey = "wirelessLastKnownPortByIP"
    
    enum ConnectionType: String {
        case none = "None"
        case usb = "USB"
        case wireless = "WiFi"
    }
    
    // MARK: - Core Logic
    
    func detectDevice() async {
        if isDetectionInProgress {
            pendingDetection = true
            return
        }
        isDetectionInProgress = true
        defer {
            isDetectionInProgress = false
            if pendingDetection {
                pendingDetection = false
                Task { await self.detectDevice() }
            }
        }

        print("📱 DeviceManager: Starting device detection...")

        // Fast path: Check for already-connected devices (USB or existing wireless session)
        var allDevices = await ADBManager.listAllConnectedDevices()
        
        // If no devices found but we have saved wireless IPs, THEN attempt the heavy reconnect
        // We run this in the background so it doesn't block the UI from instantly showing "Disconnected"
        if allDevices.isEmpty && !hasRestartedServer && !Self.hasAttemptedWirelessReconnectThisLaunch {
            hasRestartedServer = true
            Self.hasAttemptedWirelessReconnectThisLaunch = true
            let savedIPs = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            
            if !savedIPs.isEmpty {
                if wirelessHuntTask == nil || wirelessHuntTask?.isCancelled == true {
                    wirelessHuntTask = Task { [weak self] in
                    let adbPath = ADBManager.getADBPath()
                    if !adbPath.isEmpty {
                        print("📱 DeviceManager: No active devices. Attempting to reconnect wireless devices...")
                        
                        // Reconnect saved wireless devices using mDNS
                        var connectedIPs = Set<String>()
                        for attempt in 1...10 {
                            if Task.isCancelled { break }
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s
                            
                            let (code, mdnsOut, _) = await ADBManager.mdnsServicesWithRecovery()
                            guard code == 0 else { continue }
                            
                            guard mdnsOut.contains("_adb-tls-connect._tcp") else {
                                print("📱 DeviceManager: No mDNS connect services found, trying last-known ports...")
                                // Fallback when mDNS connect service is missing:
                                // attempt reconnect using last successful port for known IPs.
                                let portMap = UserDefaults.standard.dictionary(forKey: Self.savedWirelessPortByIPKey) as? [String: String] ?? [:]
                                for savedIP in savedIPs where !connectedIPs.contains(savedIP) {
                                    guard let savedPort = portMap[savedIP], !savedPort.isEmpty else { continue }
                                    let target = "\(savedIP):\(savedPort)"
                                    print("📱 DeviceManager: Trying saved endpoint \(target)")
                                    let (_, out, err) = await Shell.runAsyncWithTimeout(
                                        adbPath, args: ["connect", target], timeoutSeconds: 3.0
                                    )
                                    let lower = (out + err).lowercased()
                                    if lower.contains("connected to") || lower.contains("already connected") {
                                        connectedIPs.insert(savedIP)
                                        print("📱 DeviceManager: ✅ Reconnected using saved endpoint \(target)")
                                    }
                                }
                                break
                            }
                            
                            print("📱 DeviceManager: mDNS poll attempt \(attempt)/10")
                            
                            for savedIP in savedIPs where !connectedIPs.contains(savedIP) {
                                for line in mdnsOut.split(separator: "\n") {
                                    let str = String(line)
                                    guard str.contains("_adb-tls-connect._tcp"),
                                          str.contains(savedIP) else { continue }
                                    let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                                    guard let ipPort = parts.first(where: { $0.hasPrefix(savedIP + ":") }) else { break }
                                    
                                    print("📱 DeviceManager: Reconnecting to: \(ipPort)")
                                    let (_, out, _) = await Shell.runAsyncWithTimeout(
                                        adbPath, args: ["connect", ipPort], timeoutSeconds: 3.0
                                    )
                                    if out.lowercased().contains("connected") {
                                        connectedIPs.insert(savedIP)
                                        print("📱 DeviceManager: ✅ Connected to \(ipPort)")
                                    } else {
                                        print("📱 DeviceManager: ❌ Failed: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    }
                                    break
                                }
                            }
                            
                            if connectedIPs.count >= savedIPs.count { break }
                        }
                        print("📱 DeviceManager: Reconnected \(connectedIPs.count)/\(savedIPs.count) devices")
                        
                        // If we successfully reconnected in the background, refresh the UI!
                        if !connectedIPs.isEmpty {
                            await self?.detectDevice()
                        } else {
                            // Hunt failed, explicitly update UI to disconnected ONLY if a USB device
                            // hasn't already connected in the meantime!
                            await MainActor.run {
                                guard let self = self, !self.isConnected else { return }
                                self.connectionType = .none
                                self.deviceName = "No Device"
                                self.statusMessage = "No device detected. Please connect your device."
                                self.isConnected = false
                                self.sdCardPath = nil
                                self.storageStats = [:]
                                self.isDetecting = false
                            }
                        }
                    }
                    await MainActor.run { self?.wirelessHuntTask = nil }
                    }
                }
                
                // Return early so we DON'T update the UI to "Disconnected" while the background task is running!
                // This keeps the spinner active on first launch.
                return
            } else {
                print("📱 DeviceManager: No saved wireless devices, trying direct mDNS connect...")
                if wirelessHuntTask == nil || wirelessHuntTask?.isCancelled == true {
                    wirelessHuntTask = Task { [weak self] in
                    let adbPath = ADBManager.getADBPath()
                    guard !adbPath.isEmpty else { return }

                    var connectedAny = false
                    for attempt in 1...10 {
                        if Task.isCancelled { break }
                        if attempt > 1 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s
                        }
                        let (code, mdnsOut, _) = await ADBManager.mdnsServicesWithRecovery()
                        guard code == 0 else {
                            print("📱 DeviceManager: mDNS query failed with code \(code)")
                            continue
                        }
                        let mdnsTrimmed = mdnsOut.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("📱 DeviceManager: mDNS services output (attempt \(attempt)/10):\n\(mdnsTrimmed.isEmpty ? "<empty>" : mdnsTrimmed)")

                        var attempted = Set<String>()
                        for line in mdnsOut.split(separator: "\n") {
                            let str = String(line)
                            guard str.contains("_adb-tls-connect._tcp") else { continue }
                            let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                            guard let ipPort = parts.first(where: { part in
                                let comps = part.split(separator: ":")
                                return comps.count >= 2 && UInt16(comps.last ?? "") != nil
                            }) else { continue }

                            guard !attempted.contains(ipPort) else { continue }
                            attempted.insert(ipPort)

                            print("📱 DeviceManager: Attempting mDNS connect to \(ipPort)")
                            let (exitCode, out, err) = await Shell.runAsyncWithTimeout(
                                adbPath, args: ["connect", ipPort], timeoutSeconds: 4.0
                            )
                            let combined = out + err
                            let lower = combined.lowercased()
                            print("📱 DeviceManager: mDNS connect result code=\(exitCode), output=\(combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                            if lower.contains("connected to") || lower.contains("already connected") {
                                connectedAny = true
                                print("📱 DeviceManager: ✅ mDNS direct connect succeeded: \(ipPort)")
                                break
                            }
                        }
                        if connectedAny { break }
                    }

                    if connectedAny {
                        await self?.detectDevice()
                    } else {
                        print("📱 DeviceManager: mDNS direct connect did not succeed (likely needs pairing)")
                    }
                    await MainActor.run { self?.wirelessHuntTask = nil }
                    }
                }

                // Keep current UI state while background mDNS connect hunt runs.
                // Without this return, the same detection cycle marks device as disconnected
                // even though connect may succeed moments later.
                return
            }
        }

        await MainActor.run { self.availableDevices = allDevices }

        // Derive active device from the list (same logic as isDeviceConnected but without a second adb call)
        if !allDevices.isEmpty {
            // Always validate wireless devices — ADB can show stale wireless
            // connections even after the phone disconnected or left the network.
            let hasWireless = allDevices.contains(where: { $0.isWireless })
            if hasWireless {
                var validDevices: [ADBManager.ConnectedDevice] = []
                let adbPath = ADBManager.getADBPath()
                for dev in allDevices {
                    if dev.isWireless {
                        // Quick liveness check — 1.5s timeout
                        let (code, out, _) = await Shell.runAsyncWithTimeout(
                            adbPath,
                            args: ["-s", dev.serial, "shell", "echo", "ok"],
                            timeoutSeconds: 1.5
                        )
                        if code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                            validDevices.append(dev)
                        } else {
                            print("📱 DeviceManager: Stale wireless device removed: \(dev.serial)")
                            // Disconnect the stale entry so ADB stops listing it
                            let _ = await Shell.runAsyncWithTimeout(
                                adbPath, args: ["disconnect", dev.serial], timeoutSeconds: 2.0
                            )
                        }
                    } else {
                        validDevices.append(dev)
                    }
                }
                allDevices = validDevices
                await MainActor.run { self.availableDevices = allDevices }
            }
            
            let updatedSerials = allDevices.map { $0.serial }
            if let current = ADBManager.activeDeviceSerial, updatedSerials.contains(current) {
                // Keep current active device
                print("📱 DeviceManager: Keeping active device: \(current)")
            } else if let usbSerial = updatedSerials.first(where: { !ADBManager.isWirelessSerial($0) }) {
                ADBManager.activeDeviceSerial = usbSerial
                print("📱 DeviceManager: Using USB device: \(usbSerial)")
            } else if let wirelessSerial = updatedSerials.first(where: { ADBManager.isWirelessSerial($0) }) {
                ADBManager.activeDeviceSerial = wirelessSerial
                print("📱 DeviceManager: Using wireless device: \(wirelessSerial)")
            } else {
                ADBManager.activeDeviceSerial = nil
            }
            adbAvailable = !allDevices.isEmpty
        } else {
            adbAvailable = false
            // Clear stale active serial so it doesn't block future detections
            ADBManager.activeDeviceSerial = nil
        }
        
        // If user explicitly disconnected, don't auto-pick wireless devices
        if userDisconnected, let serial = ADBManager.activeDeviceSerial, ADBManager.isWirelessSerial(serial) {
            adbAvailable = false
        }
        print("📱 DeviceManager: ADB available = \(adbAvailable), active = \(ADBManager.activeDeviceSerial ?? "nil")")
        
        // Determine connection type from the active serial
        let activeSerial = ADBManager.activeDeviceSerial
        let isWireless = adbAvailable && (activeSerial.map { ADBManager.isWirelessSerial($0) } ?? false)
        
        // Update the state on the main thread
        await MainActor.run {
            if adbAvailable {
                // Set device name instantly from the allDevices list without extra adb calls
                if let active = allDevices.first(where: { $0.serial == ADBManager.activeDeviceSerial }) {
                    self.deviceName = active.displayName
                }
                
                if isWireless {
                    self.connectionType = .wireless
                    self.statusMessage = "Connected via WiFi"
                    // Traditional serial: IP is embedded (e.g. "192.168.1.67:40395")
                    if let serial = activeSerial, serial.contains(":"), let ip = serial.components(separatedBy: ":").first {
                        self.lastWirelessIP = ip
                    }
                } else {
                    self.connectionType = .usb
                    self.statusMessage = "Connected via USB"
                    // Do NOT clear lastWirelessIP here — we may have a WiFi device in
                    // availableDevices that the user can still switch back to.
                }
                self.isConnected = true
                print("📱 DeviceManager: Device connected (\(self.connectionType.rawValue))!")
            } else {
                self.connectionType = .none
                self.deviceName = "No Device"
                self.statusMessage = "No device detected. Please connect your device."
                self.isConnected = false
                self.sdCardPath = nil
                self.storageStats = [:]
                // Only clear lastWirelessIP if no wireless device is available at all
                if !allDevices.contains(where: { $0.isWireless }) {
                    self.lastWirelessIP = ""
                }
                print("📱 DeviceManager: No device found")
            }
            
            // Detection is complete, hide the initial loading screen
            self.isDetecting = false
        }

        // If connected, fetch non-critical metadata concurrently so we don't block the UI
        if adbAvailable {
            Self.hasAttemptedWirelessReconnectThisLaunch = false
            Task {
                // ADB 37+ mDNS serial: resolve IP since it's not in the serial
                if isWireless {
                    let currentIP = await MainActor.run { self.lastWirelessIP }
                    if currentIP.isEmpty, let resolvedIP = await ADBManager.getWirelessIP() {
                        await MainActor.run { self.lastWirelessIP = resolvedIP }
                    }
                }
            }
        }
    }

    // MARK: - Device Switching

    /// Switch the active ADB device (e.g. from wireless → USB or between two devices)
    /// and re-detect all state.
    func switchToDevice(serial: String) async {
        ADBManager.switchToDevice(serial: serial)
        await detectDevice()
    }

    // MARK: - USB Device Monitor (IOKit, zero-overhead)

    /// Registers IOKit USB attach/detach callbacks. Fires instantly when a USB
    /// device is plugged or unplugged — no polling, no CPU cost when idle.
    func startMonitoring() {
        let monitor = USBDeviceMonitor()
        monitor.onChange = { [weak self] in
            guard let self else { return }
            Task {
                // Snapshot the device count before detection
                let previousDeviceCount = await MainActor.run { self.availableDevices.count }
                
                // Try immediately (fastest for disconnects, and sometimes connects)
                await self.detectDevice()
                
                // Poll a few times for ADB to register the change.
                // - On connect: ADB can take ~0.5-1s to register a new USB device
                // - On disconnect: detectDevice() above handles it instantly
                // We poll until the device list has actually changed or we time out.
                let hasUSBDevice = { @MainActor in
                    self.availableDevices.contains(where: { !$0.isWireless })
                }
                for _ in 1...4 {
                    let connected = await MainActor.run { self.isConnected }
                    let hasUSB = await hasUSBDevice()
                    // Stop if: we're connected AND have a USB device, OR if we were
                    // already connected (WiFi) and the device list updated
                    let currentCount = await MainActor.run { self.availableDevices.count }
                    if connected && hasUSB { break }
                    if connected && currentCount != previousDeviceCount { break }
                    if !connected && currentCount == 0 {
                        // Disconnect detected and reflected
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
                    await self.detectDevice()
                }
            }
        }
        monitor.start()
        usbMonitor = monitor
        print("📡 IOKit USB monitor started")
    }

    func stopMonitoring() {
        usbMonitor?.stop()
        usbMonitor = nil
    }

    // MARK: - SD Card Detection
    
    /// Scans /storage/ on the device and finds the first physical SD card.
    /// Physical SD cards appear as UUID-named volumes (e.g. "1A2B-3C4D"),
    /// distinct from "emulated", "self", and "sdcard" which are internal aliases.
    func detectSDCard() async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }

        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "ls", "/storage/"])
        )

        let systemVolumes: Set<String> = ["emulated", "self", "sdcard", ""]
        let sdUUID = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !systemVolumes.contains($0) && !$0.isEmpty }

        let detectedPath: String? = sdUUID.map { "/storage/\($0)" }

        await MainActor.run {
            self.sdCardPath = detectedPath
            if let path = detectedPath {
                print("💾 DeviceManager: SD card detected at \(path)")
            } else {
                print("💾 DeviceManager: No physical SD card found")
            }
        }
    }

    // MARK: - Storage Info

    /// Fetches used/total bytes for internal storage (and SD card if present).
    /// Uses `adb shell df -k <path>` — output is in 1K blocks.
    func fetchStorageInfo() async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }

        // Fetch internal storage and SD card in parallel
        async let internalFetch = Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "df", "-k", "/storage/emulated/0"])
        )
        async let sdFetch: (Int32, String, String)? = {
            guard let sdPath = await self.sdCardPath else { return nil }
            return await Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "df", "-k", sdPath]))
        }()

        let (_, internalOut, _) = await internalFetch
        let sdResult = await sdFetch

        var newStats: [String: StorageInfo] = [:]

        if let info = parseDfOutput(internalOut) {
            newStats["/storage/emulated/0"] = info
        }
        if let (_, sdOut, _) = sdResult, let sdPath = sdCardPath,
           let info = parseDfOutput(sdOut) {
            newStats[sdPath] = info
        }

        await MainActor.run {
            self.storageStats = newStats
        }
    }

    /// Parses `df -k` output. Handles two formats:
    /// - GNU df:   "Filesystem  1K-blocks  Used  Available  Use%  Mounted"  (integer KB)
    /// - Toybox:   "Filesystem    Size    Used    Free  Blksize"           (e.g. "48.9G")
    private func parseDfOutput(_ output: String) -> StorageInfo? {
        let lines = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard !line.lowercased().hasPrefix("filesystem") else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }

            // Try GNU df -k: all integers, values in KB blocks
            if let totalKB = Int64(parts[1]), let usedKB = Int64(parts[2]), totalKB > 0 {
                return StorageInfo(usedBytes: usedKB * 1024, totalBytes: totalKB * 1024)
            }

            // Try Android toybox df: columns are human-readable like "48.9G", "17.4G", "31.5G"
            if parts.count >= 4,
               let total = parseHumanBytes(String(parts[1])),
               let used  = parseHumanBytes(String(parts[2])),
               total > 0 {
                return StorageInfo(usedBytes: used, totalBytes: total)
            }
        }
        return nil
    }

    /// Parses human-readable byte strings: "48.9G", "512M", "1.2T", "1024K"
    private func parseHumanBytes(_ s: String) -> Int64? {
        let upper = s.uppercased()
        let units: [(String, Int64)] = [
            ("T", 1_099_511_627_776),
            ("G", 1_073_741_824),
            ("M", 1_048_576),
            ("K", 1_024),
            ("B", 1)
        ]
        for (suffix, multiplier) in units {
            if upper.hasSuffix(suffix) {
                let numStr = String(upper.dropLast(suffix.count))
                if let value = Double(numStr) { return Int64(value * Double(multiplier)) }
            }
        }
        return Int64(s) // plain integer — bytes as-is
    }

    
    // MARK: - Wireless Connection (Android 11+)
    
    /// Pair and connect to an Android 11+ device wirelessly
    func pairAndConnect(ip: String, pairingPort: String, pairingCode: String, connectPort: String, hostname: String? = nil) async -> (Bool, String) {
        await MainActor.run {
            self.isDetecting = true
            self.statusMessage = "Pairing with device..."
        }
        
        // Step 1: Pair
        let (pairSuccess, pairMessage) = await ADBManager.pairDevice(ip: ip, port: pairingPort, code: pairingCode)
        
        guard pairSuccess else {
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = pairMessage
            }
            return (false, pairMessage)
        }
        
        await MainActor.run {
            self.statusMessage = "Paired! Connecting..."
        }
        
        // Step 2: Connect — try .local hostname first (ADB 37+), fall back to IP
        let (connectSuccess, connectMessage, connectedTarget) = await ADBManager.connectWireless(
            ip: ip, port: connectPort, hostname: hostname
        )
        
        if connectSuccess {
            if let connectedTarget, !connectedTarget.isEmpty {
                ADBManager.switchToDevice(serial: connectedTarget)
                ADBManager.markAppManagedWirelessTarget(connectedTarget)
            }
            await MainActor.run {
                self.lastWirelessIP = ip
            }
            // Persist for reconnection on next app launch.
            // Save just the IP — connect port rotates when wireless debugging is toggled.
            var saved = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            if !saved.contains(ip) { saved.append(ip) }
            UserDefaults.standard.set(saved, forKey: "connectedWirelessDevices")
            // Persist last successful port for fallback reconnect when mDNS service is missing.
            if let connectedTarget,
               let last = connectedTarget.split(separator: ":").last {
                var portMap = UserDefaults.standard.dictionary(forKey: Self.savedWirelessPortByIPKey) as? [String: String] ?? [:]
                portMap[ip] = String(last)
                UserDefaults.standard.set(portMap, forKey: Self.savedWirelessPortByIPKey)
            }
            // Re-detect to update all state properly
            await detectDevice()
            return (true, "Connected wirelessly to \(hostname ?? ip)")
        } else {
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = connectMessage
            }
            return (false, connectMessage)
        }
    }
    
    /// Connect to a previously paired device.
    /// Pass `hostname` (e.g. "adb-XXXX.local") when available for ADB 37+ stability.
    func connectWirelessly(ip: String, port: String = "5555", hostname: String? = nil) async -> (Bool, String) {
        ADBPairingBrowser.suppressAutoConnect = false
        await MainActor.run {
            self.isDetecting = true
            self.statusMessage = "Connecting to \(hostname ?? ip)..."
            self.userDisconnected = false
        }
        
        let (success, message, connectedTarget) = await ADBManager.connectWireless(ip: ip, port: port, hostname: hostname)
        
        if success {
            // Explicitly make this the active device BEFORE detectDevice() runs,
            // so isDeviceConnected() honours it and switches away from USB.
            let target = connectedTarget ?? "\(ip):\(port)"
            ADBManager.switchToDevice(serial: target)
            ADBManager.markAppManagedWirelessTarget(target)
            await MainActor.run {
                self.lastWirelessIP = ip
            }
            // Persist for reconnection on next app launch (add to array)
            // Save just the IP — ports change on every wireless debugging toggle
            var saved = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            if !saved.contains(ip) { saved.append(ip) }
            UserDefaults.standard.set(saved, forKey: "connectedWirelessDevices")
            // Persist last successful port for fallback reconnect when mDNS service is missing.
            if let connectedTarget,
               let last = connectedTarget.split(separator: ":").last {
                var portMap = UserDefaults.standard.dictionary(forKey: Self.savedWirelessPortByIPKey) as? [String: String] ?? [:]
                portMap[ip] = String(last)
                UserDefaults.standard.set(portMap, forKey: Self.savedWirelessPortByIPKey)
            }
            await detectDevice()
            return (true, message)
        } else {
            // If connection fails (e.g. authorization revoked), remove from saved list
            // so the UI falls back to "Tap to pair" and stops auto-reconnecting
            var saved = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            if let idx = saved.firstIndex(of: ip) {
                saved.remove(at: idx)
                UserDefaults.standard.set(saved, forKey: "connectedWirelessDevices")
            }
            
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = message
            }
            return (false, message)
        }
    }
    
    /// Disconnect wireless device
    func disconnectWireless() async {
        ADBPairingBrowser.suppressAutoConnect = true
        let _ = await ADBManager.disconnectAllWireless()
        // Clear all saved wireless devices
        UserDefaults.standard.removeObject(forKey: "connectedWirelessDevices")
        UserDefaults.standard.removeObject(forKey: Self.savedWirelessPortByIPKey)
        await MainActor.run {
            self.lastWirelessIP = ""
            self.isConnected = false
            self.connectionType = .none
            self.deviceName = "No Device"
            self.statusMessage = "Disconnected. Connect a device to continue."
            self.sdCardPath = nil
            self.storageStats = [:]
            self.userDisconnected = true
        }
        // All cached sizes are stale after disconnect
        ADBManager.invalidateFolderSizeCache()
    }
    
    /// Re-detect device after QR pairing auto-connected it
    func detectDeviceAfterWirelessConnect() {
        Task {
            await detectDevice()
        }
    }
    
    func listFiles(path: String = "/sdcard") async throws -> [UnifiedFile] {
        guard adbAvailable else {
            throw NSError(
                domain: "DeviceManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No device connected"]
            )
        }
        
        let adbFiles = try await ADBManager.listFiles(path: path)
        return adbFiles.map { UnifiedFile(from: $0) }
    }
    
    func getRealStoragePath() async -> String {
        return "/storage/emulated/0" // Default fallback
    }
}
