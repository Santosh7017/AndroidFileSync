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
    /// True when the background device diagnostics task has completed
    @Published var diagnosticsComplete = false
    /// One-time flag: restart ADB server on first detection to apply env var
    private var hasRestartedServer = false
    /// Prevent overlapping detection runs that can flood ADB and mDNS queries.
    private var isDetectionInProgress = false
    private var pendingDetection = false
    /// A short window after a physical USB event where a newly listed ADB USB
    /// serial should become active even if a wireless serial is already active.
    private var preferUSBUntil: Date? = nil
    /// Rate-limit default-server USB ownership recovery during normal detection.
    private var lastUSBTransportRecoveryAt: Date? = nil
    /// Single in-flight wireless hunt task to avoid spawning one per detect cycle.
    private var wirelessHuntTask: Task<Void, Never>? = nil
    /// Background diagnostics task — cancelled on disconnect to avoid stale serial queries.
    private var diagnosticsTask: Task<Void, Never>? = nil
    private var lastWirelessReconnectAttemptAt: Date? = nil
    private static let wirelessReconnectCooldown: TimeInterval = 8.0
    /// Cache last liveness check timestamp per wireless serial to prevent spamming adb shell commands.
    private var lastLivenessCheckAt: [String: Date] = [:]
    private static let savedWirelessPortByIPKey = "wirelessLastKnownPortByIP"
    
    private var autoClaimUSB: Bool {
        UserDefaults.standard.bool(forKey: "autoClaimUSB")
    }
    private static let savedWirelessTargetByIPKey = "wirelessLastKnownTargetByIP"

    private static func clearSavedWirelessEndpoint(for ip: String) {
        var savedIPs = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
        savedIPs.removeAll { $0 == ip }
        UserDefaults.standard.set(savedIPs, forKey: "connectedWirelessDevices")

        var portMap = UserDefaults.standard.dictionary(forKey: savedWirelessPortByIPKey) as? [String: String] ?? [:]
        portMap.removeValue(forKey: ip)
        UserDefaults.standard.set(portMap, forKey: savedWirelessPortByIPKey)

        var targetMap = UserDefaults.standard.dictionary(forKey: savedWirelessTargetByIPKey) as? [String: String] ?? [:]
        targetMap.removeValue(forKey: ip)
        UserDefaults.standard.set(targetMap, forKey: savedWirelessTargetByIPKey)
    }

    private static func saveWirelessReconnectTarget(ip: String, connectedTarget: String?) {
        guard let connectedTarget, !connectedTarget.isEmpty else { return }

        var targetMap = UserDefaults.standard.dictionary(forKey: savedWirelessTargetByIPKey) as? [String: String] ?? [:]
        targetMap[ip] = connectedTarget
        UserDefaults.standard.set(targetMap, forKey: savedWirelessTargetByIPKey)

        if let last = connectedTarget.split(separator: ":").last {
            var portMap = UserDefaults.standard.dictionary(forKey: savedWirelessPortByIPKey) as? [String: String] ?? [:]
            portMap[ip] = String(last)
            UserDefaults.standard.set(portMap, forKey: savedWirelessPortByIPKey)
        }
    }
    
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

        // Cold-start case: USB may already be plugged in before IOKit monitoring
        // starts. In that path, no attach callback fires, so recover private ADB
        // ownership here before falling back to Wi-Fi-only state.
        if !allDevices.contains(where: { !$0.isWireless }), autoClaimUSB, canAttemptUSBTransportRecovery() {
            lastUSBTransportRecoveryAt = Date()
            if await ADBManager.recoverPrivateUSBTransportIfNeeded() {
                allDevices = await ADBManager.listAllConnectedDevices()
                if allDevices.contains(where: { !$0.isWireless }) {
                    preferUSBUntil = Date().addingTimeInterval(2.0)
                }
            }
        }
        
        // If no devices are listed, periodically retry wireless discovery/reconnect.
        // Wireless debugging ports rotate, so a one-shot launch guard misses phones that
        // start advertising after the app's first scan.
        let canAttemptWirelessReconnect: Bool = {
            guard !userDisconnected else { return false }
            guard wirelessHuntTask == nil || wirelessHuntTask?.isCancelled == true else { return false }
            guard let lastAttempt = lastWirelessReconnectAttemptAt else { return true }
            return Date().timeIntervalSince(lastAttempt) >= Self.wirelessReconnectCooldown
        }()

        if allDevices.isEmpty && canAttemptWirelessReconnect {
            hasRestartedServer = true
            Self.hasAttemptedWirelessReconnectThisLaunch = true
            lastWirelessReconnectAttemptAt = Date()
            let savedIPs = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            let savedSerials = UserDefaults.standard.stringArray(forKey: "connectedWirelessSerials") ?? []
            
            if !savedIPs.isEmpty || !savedSerials.isEmpty {
                if wirelessHuntTask == nil || wirelessHuntTask?.isCancelled == true {
                    wirelessHuntTask = Task { [weak self] in
                    let adbPath = ADBManager.getADBPath()
                    if !adbPath.isEmpty {
                        print("📱 DeviceManager: No active devices. Attempting to reconnect wireless devices...")
                        
                        // Reconnect saved wireless devices using mDNS
                        var connectedIPs = Set<String>()
                        var connectedSerials = Set<String>()
                        for attempt in 1...10 {
                            if Task.isCancelled { break }
                            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1.0s
                            
                            let (code, mdnsOut, _) = await ADBManager.mdnsServicesWithRecovery()
                            guard code == 0 else { continue }
                            
                            guard mdnsOut.contains("_adb-tls-connect._tcp") else {
                                print("📱 DeviceManager: No mDNS connect services found, trying last-known ports...")
                                // Fallback when mDNS connect service is missing:
                                // attempt reconnect using last successful port for known IPs.
                                let targetMap = UserDefaults.standard.dictionary(forKey: Self.savedWirelessTargetByIPKey) as? [String: String] ?? [:]
                                let portMap = UserDefaults.standard.dictionary(forKey: Self.savedWirelessPortByIPKey) as? [String: String] ?? [:]
                                for savedIP in savedIPs where !connectedIPs.contains(savedIP) {
                                    let savedTarget = targetMap[savedIP]
                                    let fallbackTarget = portMap[savedIP].map { "\(savedIP):\($0)" }
                                    let candidates = [savedTarget, fallbackTarget].compactMap { $0 }

                                    guard !candidates.isEmpty else {
                                        print("📱 DeviceManager: No saved ADB 37 target or port for \(savedIP); pairing is required.")
                                        Self.clearSavedWirelessEndpoint(for: savedIP)
                                        continue
                                    }

                                    var reconnected = false
                                    for target in candidates {
                                        print("📱 DeviceManager: Trying saved ADB target \(target)")
                                        let (_, out, err) = await Shell.runAsyncWithTimeout(
                                            adbPath, args: ["connect", target], timeoutSeconds: 4.0
                                        )
                                        let combined = out + err
                                        let lower = combined.lowercased()
                                        if lower.contains("connected to") || lower.contains("already connected") {
                                            connectedIPs.insert(savedIP)
                                            reconnected = true
                                            print("📱 DeviceManager: ✅ Reconnected using saved ADB target \(target)")
                                            break
                                        } else {
                                            print("📱 DeviceManager: ❌ Saved target failed: \(combined.trimmingCharacters(in: .whitespacesAndNewlines))")
                                        }
                                    }

                                    if !reconnected {
                                        print("📱 DeviceManager: Saved wireless target for \(savedIP) is stale; clearing it so user can pair/connect with the current ADB 37 service.")
                                        Self.clearSavedWirelessEndpoint(for: savedIP)
                                    }
                                }
                                break
                            }
                            
                            print("📱 DeviceManager: mDNS poll attempt \(attempt)/10")
                            
                            // 1. First attempt to match by serial number (ADB 37+ mDNS)
                            for line in mdnsOut.split(separator: "\n") {
                                let str = String(line)
                                guard str.contains("_adb-tls-connect._tcp") else { continue }
                                
                                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                                guard let serviceName = parts.first else { continue }
                                guard let ipPort = parts.first(where: { part in
                                    let comps = part.split(separator: ":")
                                    return comps.count >= 2 && UInt16(comps.last ?? "") != nil
                                }) else { continue }
                                
                                guard let hwSerial = ADBManager.extractHardwareSerial(from: serviceName) else { continue }
                                if savedSerials.contains(hwSerial) && !connectedSerials.contains(hwSerial) {
                                    print("📱 DeviceManager: Reconnecting to serial \(hwSerial) at: \(ipPort)")
                                    let (_, out, _) = await Shell.runAsyncWithTimeout(
                                        adbPath, args: ["connect", ipPort], timeoutSeconds: 3.0
                                    )
                                    if out.lowercased().contains("connected") {
                                        connectedSerials.insert(hwSerial)
                                        if let ip = ipPort.components(separatedBy: ":").first {
                                            connectedIPs.insert(ip)
                                        }
                                        print("📱 DeviceManager: ✅ Connected serial \(hwSerial) to \(ipPort)")
                                    } else {
                                        print("📱 DeviceManager: ❌ Failed serial reconnect: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    }
                                }
                            }
                            
                            // 2. Fallback to matching by raw IP (for legacy networks/backwards compatibility)
                            for savedIP in savedIPs where !connectedIPs.contains(savedIP) {
                                for line in mdnsOut.split(separator: "\n") {
                                    let str = String(line)
                                    guard str.contains("_adb-tls-connect._tcp"),
                                          str.contains(savedIP) else { continue }
                                    let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                                    guard let ipPort = parts.first(where: { $0.hasPrefix(savedIP + ":") }) else { break }
                                    
                                    print("📱 DeviceManager: Reconnecting to IP: \(ipPort)")
                                    let (_, out, _) = await Shell.runAsyncWithTimeout(
                                        adbPath, args: ["connect", ipPort], timeoutSeconds: 3.0
                                    )
                                    if out.lowercased().contains("connected") {
                                        connectedIPs.insert(savedIP)
                                        print("📱 DeviceManager: ✅ Connected IP to \(ipPort)")
                                    } else {
                                        print("📱 DeviceManager: ❌ Failed IP reconnect: \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
                                    }
                                    break
                                }
                            }
                            
                            let targetSerialCount = savedSerials.count
                            let targetIPCount = savedIPs.count
                            let serialReached = targetSerialCount > 0 && connectedSerials.count >= targetSerialCount
                            let ipReached = targetIPCount > 0 && connectedIPs.count >= targetIPCount
                            if serialReached || ipReached { break }
                        }
                        print("📱 DeviceManager: Reconnected \(connectedSerials.count) serial-based and \(connectedIPs.count) IP-based devices")
                        
                        // If we successfully reconnected in the background, refresh the UI!
                        if !connectedIPs.isEmpty || !connectedSerials.isEmpty {
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

                        let pairingServiceNames: Set<String> = Set(mdnsOut.split(separator: "\n").compactMap { line in
                            let str = String(line)
                            guard str.contains("_adb-tls-pairing._tcp") else { return nil }
                            return str.split(whereSeparator: { $0 == "\t" || $0 == " " }).first.map(String.init)
                        })

                        var attempted = Set<String>()
                        for line in mdnsOut.split(separator: "\n") {
                            let str = String(line)
                            guard str.contains("_adb-tls-connect._tcp") else { continue }
                            let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                            let serviceName = parts.first ?? ""
                            if pairingServiceNames.contains(serviceName) {
                                print("📱 DeviceManager: Skipping direct connect for \(serviceName); pairing dialog is open.")
                                continue
                            }
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
                        // Rate-limit the expensive getprop/shell query: only query if last check was > 15s ago
                        let now = Date()
                        if let lastCheck = lastLivenessCheckAt[dev.serial], now.timeIntervalSince(lastCheck) < 15.0 {
                            validDevices.append(dev)
                        } else {
                            // Quick liveness check — 3.0s timeout to allow sleeping devices to respond
                            let (code, out, _) = await Shell.runAsyncWithTimeout(
                                adbPath,
                                args: ["-s", dev.serial, "shell", "echo", "ok"],
                                timeoutSeconds: 3.0
                            )
                            if code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                                validDevices.append(dev)
                                lastLivenessCheckAt[dev.serial] = now
                            } else {
                                print("📱 DeviceManager: Stale wireless device removed: \(dev.serial)")
                                // Disconnect the stale entry so ADB stops listing it
                                let _ = await Shell.runAsyncWithTimeout(
                                    adbPath, args: ["disconnect", dev.serial], timeoutSeconds: 2.0
                                )
                                lastLivenessCheckAt.removeValue(forKey: dev.serial)
                            }
                        }
                    } else {
                        validDevices.append(dev)
                    }
                }
                allDevices = validDevices
                await MainActor.run { self.availableDevices = allDevices }
            }
            
            let updatedSerials = allDevices.map { $0.serial }
            let usbSerial = updatedSerials.first(where: { !ADBManager.isWirelessSerial($0) })
            let wirelessSerial = updatedSerials.first(where: { ADBManager.isWirelessSerial($0) })
            
            let isWirelessActive = isConnected && connectionType == .wireless
            let shouldPreferUSB = (preferUSBUntil.map { Date() <= $0 } ?? false) && !isWirelessActive

            if shouldPreferUSB, let usbSerial {
                ADBManager.activeDeviceSerial = usbSerial
                preferUSBUntil = nil
                print("📱 DeviceManager: USB attach detected, switching to USB device: \(usbSerial)")
            } else if let current = ADBManager.activeDeviceSerial, updatedSerials.contains(current) {
                // Keep current active device
                print("📱 DeviceManager: Keeping active device: \(current)")
            } else if let usbSerial {
                ADBManager.activeDeviceSerial = usbSerial
                print("📱 DeviceManager: Using USB device: \(usbSerial)")
            } else if let wirelessSerial {
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
            ADBManager.activeDeviceSerial = nil
        }
        print("📱 DeviceManager: ADB available = \(adbAvailable), active = \(ADBManager.activeDeviceSerial ?? "nil")")
        
        // Determine connection type from the active serial
        let activeSerial = ADBManager.activeDeviceSerial
        let isWireless = adbAvailable && (activeSerial.map { ADBManager.isWirelessSerial($0) } ?? false)
        
        // Update the state on the main thread
        await MainActor.run {
            if adbAvailable, let active = allDevices.first(where: { $0.serial == ADBManager.activeDeviceSerial }) {
                self.deviceName = active.displayName
                
                if active.status == "unauthorized" {
                    self.connectionType = isWireless ? .wireless : .usb
                    self.statusMessage = "Device unauthorized. Please check your phone screen to allow debugging."
                    self.isConnected = false
                } else if active.status == "offline" {
                    self.connectionType = isWireless ? .wireless : .usb
                    self.statusMessage = "Device is offline. Please reconnect your device."
                    self.isConnected = false
                } else {
                    if isWireless {
                        self.connectionType = .wireless
                        self.statusMessage = "Connected via WiFi"
                        // Traditional serials embed numeric IPs. Bonjour targets such as
                        // Android.local:45545 are resolved below via ADBManager.getWirelessIP().
                        if let serial = activeSerial,
                           serial.contains(":"),
                           let ip = serial.components(separatedBy: ":").first,
                           ip.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
                            self.lastWirelessIP = ip
                        } else {
                            self.lastWirelessIP = ""
                        }
                    } else {
                        self.connectionType = .usb
                        self.statusMessage = "Connected via USB"
                    }
                    self.isConnected = true
                    
                    // task and silently kill the upload popup. It resets only on disconnect.
                    print("📱 DeviceManager: Device connected (\(self.connectionType.rawValue))!")
                }
            } else {
                self.connectionType = .none
                self.deviceName = "No Device"
                self.statusMessage = "No device detected. Please connect your device."
                self.isConnected = false
                self.diagnosticsComplete = false
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

        // If connected and authorized, fetch non-critical metadata concurrently so we don't block the UI
        let isAuthorized = allDevices.first(where: { $0.serial == ADBManager.activeDeviceSerial })?.status == "device"
        if adbAvailable && isAuthorized {
            Self.hasAttemptedWirelessReconnectThisLaunch = false
            lastWirelessReconnectAttemptAt = nil
            
            // ── FUSE Pre-warm (Samsung fix) ─────────────────────────────────────
            // Samsung's FUSE filesystem can block `ls` on DCIM/Camera the first time
            // after USB connect. Running a lightweight `ls` NOW (in background) wakes
            // up the FUSE daemon so it's ready when the user navigates there.
            // This runs immediately — no 10s delay — because it's a single cheap command.
            Task.detached(priority: .utility) {
                let adbPath = ADBManager.getADBPath()
                guard !adbPath.isEmpty else { return }
                
                // Trigger media scanner FIRST — ensures MediaStore index is fresh
                await ADBManager.triggerMediaScanForCommonPaths()
                
                // Touch DCIM/Camera with a quick ls to wake FUSE
                let warmPaths = [
                    "/storage/emulated/0/DCIM/Camera",
                    "/storage/emulated/0/DCIM",
                    "/storage/emulated/0/Pictures"
                ]
                for path in warmPaths {
                    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
                    _ = await Shell.runAsyncWithTimeout(
                        adbPath,
                        args: ADBManager.deviceArgs(["shell", "ls '\(escaped)' >/dev/null 2>&1"]),
                        timeoutSeconds: 5.0
                    )
                }
                AppLogger.log("📱 [FUSE Pre-warm] Completed — DCIM/Camera/Pictures touched", level: .info)
            }
            
            if DiagnosticsControl.isEnabled {
                diagnosticsTask?.cancel()
                diagnosticsComplete = false
                diagnosticsTask = Task.detached(priority: .background) { [weak self] in
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled else { return }
                    guard let self, await MainActor.run(body: { self.isConnected }) else { return }
                    await ADBManager.logDeviceDiagnostics()
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        self.diagnosticsComplete = true
                    }
                }
            } else {
                diagnosticsTask?.cancel()
                diagnosticsTask = nil
                diagnosticsComplete = false
            }
            
            Task {
                if isWireless {
                    let currentIP = await MainActor.run { self.lastWirelessIP }
                    if currentIP.isEmpty, let resolvedIP = await ADBManager.getWirelessIP() {
                        await MainActor.run { self.lastWirelessIP = resolvedIP }
                    }
                    
                    if let target = ADBManager.activeDeviceSerial {
                        if let hwSerial = await ADBManager.getHardwareSerial(for: target) {
                            var savedSerials = UserDefaults.standard.stringArray(forKey: "connectedWirelessSerials") ?? []
                            if !savedSerials.contains(hwSerial) {
                                savedSerials.append(hwSerial)
                                UserDefaults.standard.set(savedSerials, forKey: "connectedWirelessSerials")
                            }
                            
                            let displayName = await MainActor.run { self.deviceName }
                            if !displayName.isEmpty && displayName != "No Device" {
                                var serialNames = UserDefaults.standard.dictionary(forKey: "wirelessDisplayNameBySerial") as? [String: String] ?? [:]
                                serialNames[hwSerial] = displayName
                                UserDefaults.standard.set(serialNames, forKey: "wirelessDisplayNameBySerial")
                            }
                        }
                    }
                }
            }
        }
    }

    private func canAttemptUSBTransportRecovery() -> Bool {
        guard let lastUSBTransportRecoveryAt else { return true }
        return Date().timeIntervalSince(lastUSBTransportRecoveryAt) > 10.0
    }

    func setDiagnosticsEnabled(_ enabled: Bool) {
        if !enabled {
            diagnosticsTask?.cancel()
            diagnosticsTask = nil
            diagnosticsComplete = false
            return
        }

        diagnosticsComplete = false
        if isConnected {
            Task { await detectDevice() }
        }
    }

    // MARK: - Device Switching

    func cancelWirelessReconnectHunt() {
        wirelessHuntTask?.cancel()
        wirelessHuntTask = nil
    }

    /// Switch the active ADB device (e.g. from wireless -> USB or between two devices)
    /// and re-detect all state.
    func switchToDevice(serial: String) async {
        ADBManager.switchToDevice(serial: serial)
        await detectDevice()
    }

    /// Switch using an already listed device snapshot so the UI responds immediately.
    /// A full detect still runs in the background to refresh metadata and storage state.
    func switchToDevice(_ device: ADBManager.ConnectedDevice) {
        ADBManager.switchToDevice(serial: device.serial)
        deviceName = device.displayName
        connectionType = device.isWireless ? .wireless : .usb
        statusMessage = device.isWireless ? "Connected via WiFi" : "Connected via USB"
        isConnected = true
        isDetecting = false
        if let ip = device.ipAddress, !ip.isEmpty {
            lastWirelessIP = ip
        } else if !device.isWireless {
            lastWirelessIP = ""
        }

        Task { await detectDevice() }
    }

    // MARK: - USB Device Monitor (IOKit, zero-overhead)

    func startMonitoring() {
        let monitor = USBDeviceMonitor()
        
        // USB device plugged in — poll for ADB to register the new device
        monitor.onDeviceAdded = { [weak self] in
            guard let self else { return }
            Task {
                // Cancel any running wireless hunt or stale diagnostics from prior disconnect
                self.cancelWirelessReconnectHunt()
                self.diagnosticsTask?.cancel()
                self.diagnosticsTask = nil
                
                await MainActor.run {
                    self.preferUSBUntil = Date().addingTimeInterval(6.0)
                }

                let previousDeviceCount = await MainActor.run { self.availableDevices.count }
                await self.detectDevice()
                
                var attemptedUSBTransportRecovery = false
                for _ in 1...4 {
                    let connected = await MainActor.run { self.isConnected }
                    let hasUSB = await MainActor.run {
                        self.availableDevices.contains(where: { !$0.isWireless })
                    }
                    let currentCount = await MainActor.run { self.availableDevices.count }
                    if connected && hasUSB { break }
                    if currentCount != previousDeviceCount { break }

                    if !hasUSB && self.autoClaimUSB && !attemptedUSBTransportRecovery {
                        attemptedUSBTransportRecovery = true
                        if await ADBManager.recoverPrivateUSBTransportIfNeeded() {
                            await self.detectDevice()
                            let recoveredUSB = await MainActor.run {
                                self.availableDevices.contains(where: { !$0.isWireless })
                            }
                            if recoveredUSB { break }
                        }
                    }

                    try? await Task.sleep(nanoseconds: 500_000_000)
                    await self.detectDevice()
                }

                await MainActor.run {
                    if let deadline = self.preferUSBUntil, Date() > deadline {
                        self.preferUSBUntil = nil
                    }
                }
            }
        }
        
        // USB device unplugged — instant UI response, then confirm with ADB
        monitor.onDeviceRemoved = { [weak self] in
            guard let self else { return }
            Task {
                // Cancel stale diagnostics so they don't query a disconnected serial
                self.diagnosticsTask?.cancel()
                self.diagnosticsTask = nil
                
                let wasUSB = await MainActor.run {
                    self.isConnected && self.connectionType == .usb
                }
                
                if wasUSB {
                    // IOKit fires for ALL USB devices (mouse, keyboard, etc.).
                    // Quick `adb devices` check to confirm our Android device is actually gone.
                    let adbPath = ADBManager.getADBPath()
                    let activeSerial = ADBManager.activeDeviceSerial
                    let (_, devOutput, _) = await Shell.runAsyncWithTimeout(
                        adbPath, args: ["devices"], timeoutSeconds: 2.0
                    )
                    let stillListed = activeSerial != nil && devOutput.contains(activeSerial!)
                    
                    if !stillListed {
                        // Preserve wireless entries — only remove USB device from the list
                        let wirelessDevices = await MainActor.run {
                            self.availableDevices.filter { $0.isWireless }
                        }
                        
                        if wirelessDevices.isEmpty {
                            // No wireless fallback — full disconnect
                            await MainActor.run {
                                self.isConnected = false
                                self.deviceName = "No Device"
                                self.statusMessage = "Device disconnected"
                                self.connectionType = .none
                                self.sdCardPath = nil
                                self.storageStats = [:]
                                self.availableDevices = []
                                print("📱 DeviceManager: USB removed — disconnected (no wireless fallback)")
                            }
                            ADBManager.activeDeviceSerial = nil
                        } else {
                            // Wireless fallback available — switch to it immediately
                            let wirelessDev = wirelessDevices[0]
                            await MainActor.run {
                                self.availableDevices = wirelessDevices
                                self.connectionType = .wireless
                                self.statusMessage = "Connected via WiFi"
                                self.deviceName = wirelessDev.displayName
                                print("📱 DeviceManager: USB removed — switching to wireless: \(wirelessDev.serial)")
                            }
                            ADBManager.activeDeviceSerial = wirelessDev.serial
                        }
                    }
                }
                
                // Full detection for cleanup and state refresh
                try? await Task.sleep(nanoseconds: 300_000_000)
                await self.detectDevice()
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
            Self.saveWirelessReconnectTarget(ip: ip, connectedTarget: connectedTarget)
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
            Self.saveWirelessReconnectTarget(ip: ip, connectedTarget: connectedTarget)
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
        await MainActor.run {
            self.userDisconnected = true
        }
        let _ = await ADBManager.disconnectAllWireless()
        // Clear all saved wireless devices
        UserDefaults.standard.removeObject(forKey: "connectedWirelessDevices")
        UserDefaults.standard.removeObject(forKey: "connectedWirelessSerials")
        UserDefaults.standard.removeObject(forKey: "wirelessDisplayNameBySerial")
        UserDefaults.standard.removeObject(forKey: Self.savedWirelessPortByIPKey)
        UserDefaults.standard.removeObject(forKey: Self.savedWirelessTargetByIPKey)
        await MainActor.run {
            self.lastWirelessIP = ""
            self.isConnected = false
            self.connectionType = .none
            self.deviceName = "No Device"
            self.statusMessage = "Disconnected. Connect a device to continue."
            self.sdCardPath = nil
            self.storageStats = [:]
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
    
    func listFiles(path: String = "/sdcard", onPageLoaded: (([UnifiedFile]) -> Void)? = nil) async throws -> [UnifiedFile] {
        guard adbAvailable else {
            throw NSError(
                domain: "DeviceManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No device connected"]
            )
        }
        
        // Convert the UnifiedFile callback to an ADBFile callback for ADBManager
        let adbCallback: (([ADBFile]) -> Void)? = onPageLoaded.map { callback in
            return { adbFiles in
                callback(adbFiles.map { UnifiedFile(from: $0) })
            }
        }
        
        let adbFiles = try await ADBManager.listFiles(path: path, onPageLoaded: adbCallback)
        return adbFiles.map { UnifiedFile(from: $0) }
    }
    
    func getRealStoragePath() async -> String {
        return "/storage/emulated/0" // Default fallback
    }
    
    /// Queries default port 5037 to check if there is an occupied physical USB device
    func isUSBDeviceOccupiedByDefaultServer() async -> Bool {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return false }
        let (_, defaultOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["devices", "-l"],
            timeoutSeconds: 2.0,
            environment: Shell.defaultADBEnvironment
        )
        return defaultOutput.contains(" usb:")
    }
}
