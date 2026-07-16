//
//  ConnectionHealthMonitor.swift
//  AndroidFileSync
//
//  Event-driven wireless connection health monitor.
//  Uses `adb wait-for-disconnect` for instant disconnect detection (zero polling)
//  and NWBrowser + targeted reconnect for automatic recovery.
//

import Foundation
import Network
internal import Combine

@MainActor
class ConnectionHealthMonitor: ObservableObject {
    
    // MARK: - Published State (drives UI)
    
    /// True when the device is connected and healthy
    @Published var isHealthy: Bool = true
    /// True when we've detected a disconnect and are actively trying to reconnect
    @Published var isReconnecting: Bool = false
    /// Human-readable status for the reconnection banner
    @Published var reconnectMessage: String = ""
    /// Current reconnect attempt number (for UI display)
    @Published var reconnectAttempt: Int = 0
    
    // MARK: - Internal State
    
    /// The wireless serial we're monitoring (e.g. "192.168.1.5:38101")
    private(set) var monitoredSerial: String?
    /// The IP address of the monitored device
    private(set) var monitoredIP: String?
    /// The last known ADB connect target (serial or ip:port)
    private var lastKnownTarget: String?
    /// The device's hardware serial for mDNS service matching (e.g. "RF8RC1L57RY")
    private var monitoredHWSerial: String?
    
    /// Background task running `adb wait-for-disconnect`
    private var disconnectWatchTask: Task<Void, Never>?
    /// Background task attempting reconnection
    private var reconnectTask: Task<Void, Never>?
    /// NWBrowser for detecting when the device re-advertises its connect service
    private var reconnectBrowser: NWBrowser?
    /// Queue for NWBrowser events
    private let browserQueue = DispatchQueue(label: "com.androidfilesync.healthmonitor.mdns")
    
    /// Weak reference to the parent DeviceManager
    weak var deviceManager: DeviceManager?
    
    /// Callback invoked on the MainActor when reconnection succeeds.
    /// DeviceManager sets this to trigger `detectDevice()`.
    var onReconnected: (() -> Void)?
    /// Callback when disconnect is first detected.
    var onDisconnected: (() -> Void)?
    
    /// Maximum number of reconnection attempts before giving up
    private let maxReconnectAttempts = 30 // ~60 seconds of trying
    /// True when monitoring is active (prevents double-start)
    private var isMonitoring = false
    
    // MARK: - Public API
    
    /// Start monitoring a wireless device for disconnection.
    /// Call this when a wireless device is confirmed connected and authorized.
    /// - Parameters:
    ///   - serial: The ADB serial of the wireless device (e.g. "192.168.1.5:38101")
    ///   - ip: The IP address of the device
    ///   - hwSerial: The hardware serial (e.g. "RXXXXXXXXX") for mDNS matching
    ///   - deviceManager: The DeviceManager instance
    func startMonitoring(serial: String, ip: String, hwSerial: String? = nil, deviceManager: DeviceManager) {
        // Don't restart if we're already monitoring the same device
        if isMonitoring && monitoredSerial == serial { return }
        
        // Clean up any existing monitoring
        forceStop()
        
        self.deviceManager = deviceManager
        monitoredSerial = serial
        monitoredIP = ip
        lastKnownTarget = serial
        monitoredHWSerial = hwSerial
        isMonitoring = true
        isHealthy = true
        isReconnecting = false
        reconnectAttempt = 0
        reconnectMessage = ""
        
        // Save the wireless target for reconnect fallback (in case port changes)
        if !ip.isEmpty {
            var targetMap = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownTargetByIP") as? [String: String] ?? [:]
            targetMap[ip] = serial
            UserDefaults.standard.set(targetMap, forKey: "wirelessLastKnownTargetByIP")
            
            if let port = serial.split(separator: ":").last {
                var portMap = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownPortByIP") as? [String: String] ?? [:]
                portMap[ip] = String(port)
                UserDefaults.standard.set(portMap, forKey: "wirelessLastKnownPortByIP")
            }
        }
        
        print("💓 [HealthMonitor] Started monitoring wireless device: \(serial) (IP: \(ip), HW: \(hwSerial ?? "unknown"))")
        
        startDisconnectWatcher(serial: serial)
    }
    
    /// Stop all monitoring and cleanup.
    /// Call this when the device is intentionally disconnected or switches to USB.
    func stopMonitoring() {
        forceStop()
        print("💓 [HealthMonitor] Stopped monitoring.")
    }
    
    /// Internal: cancel all tasks and reset state.
    private func forceStop() {
        disconnectWatchTask?.cancel()
        disconnectWatchTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        stopReconnectBrowser()
        
        isMonitoring = false
        deviceManager = nil
        monitoredSerial = nil
        monitoredIP = nil
        lastKnownTarget = nil
        monitoredHWSerial = nil
        isHealthy = true
        isReconnecting = false
        reconnectAttempt = 0
        reconnectMessage = ""
    }
    
    /// Update the monitored serial after a successful reconnection changes the port.
    func updateSerial(_ newSerial: String) {
        let oldSerial = monitoredSerial
        monitoredSerial = newSerial
        lastKnownTarget = newSerial
        if let ip = newSerial.components(separatedBy: ":").first,
           ip.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            monitoredIP = ip
        }
        print("💓 [HealthMonitor] Serial updated: \(oldSerial ?? "nil") → \(newSerial)")
    }
    
    // MARK: - Disconnect Watcher (Event-Driven)
    
    /// Runs `adb -s <serial> wait-for-disconnect` as a background process.
    /// This command blocks until the ADB server detects the device has disconnected.
    /// When the process exits, we know IMMEDIATELY that the device is gone.
    private func startDisconnectWatcher(serial: String) {
        disconnectWatchTask?.cancel()
        
        disconnectWatchTask = Task { [weak self] in
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }
            
            print("💓 [HealthMonitor] Starting wait-for-disconnect watcher for: \(serial)")
            
            // This blocks until the device disconnects — that's the whole point.
            // When it returns, the device is gone.
            let (exitCode, _, _) = await Shell.runAsync(
                adbPath,
                args: ["-s", serial, "wait-for-disconnect"]
            )
            
            // Check if we were cancelled (user-initiated disconnect or app cleanup)
            guard !Task.isCancelled else {
                print("💓 [HealthMonitor] wait-for-disconnect cancelled (intentional stop)")
                return
            }
            
            guard let self else { return }
            
            print("💓 [HealthMonitor] ⚡ Device disconnected! (wait-for-disconnect exited with code \(exitCode))")
            
            // Verify the device is actually gone (guard against spurious exits)
            let stillAlive = await self.quickLivenessCheck(serial: serial)
            if stillAlive {
                print("💓 [HealthMonitor] False alarm — device still responds. Restarting watcher.")
                self.startDisconnectWatcher(serial: serial)
                return
            }
            
            // Device is truly disconnected — start reconnection
            await self.handleDisconnect()
        }
    }
    
    /// Quick liveness check — returns true if the device responds to `echo ok`
    private func quickLivenessCheck(serial: String) async -> Bool {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return false }
        
        let (code, out, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["-s", serial, "shell", "echo", "ok"],
            timeoutSeconds: 2.0
        )
        return code == 0 && out.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ok")
    }
    
    // MARK: - Disconnect Handling
    
    private func handleDisconnect() async {
        guard isMonitoring else { return }
        
        isHealthy = false
        isReconnecting = true
        reconnectAttempt = 0
        reconnectMessage = "Device disconnected. Reconnecting..."
        
        print("💓 [HealthMonitor] 📡 Starting reconnection sequence...")
        
        // Notify DeviceManager so UI updates immediately
        onDisconnected?()
        
        // Start reconnection
        startReconnection()
    }
    
    // MARK: - Reconnection Logic
    
    /// Starts both event-driven (NWBrowser) and targeted (adb connect) reconnection.
    private func startReconnection() {
        reconnectTask?.cancel()
        
        // Start NWBrowser to detect when the device re-advertises
        startReconnectBrowser()
        
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }
            
            // Snapshot IP/targets at start of reconnect (safe to read; only set on main actor before this point)
            let ip = await MainActor.run { self.monitoredIP ?? "" }
            let lastTarget = await MainActor.run { self.lastKnownTarget ?? "" }
            let hwSerial = await MainActor.run { self.monitoredHWSerial }
            
            // Load saved targets for this IP (same keys as DeviceManager)
            let savedTarget = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownTargetByIP")?[ip] as? String
            let savedPort = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownPortByIP")?[ip] as? String
            
            for attempt in 1...self.maxReconnectAttempts {
                guard !Task.isCancelled else { return }
                guard await MainActor.run(body: { self.isMonitoring }) else { return }
                
                await MainActor.run {
                    self.reconnectAttempt = attempt
                    self.reconnectMessage = attempt == 1
                        ? "Device disconnected. Reconnecting..."
                        : "Reconnecting... (attempt \(attempt))"
                }
                
                print("💓 [HealthMonitor] Reconnect attempt \(attempt)/\(self.maxReconnectAttempts)")
                
                // ── Strategy 1: mDNS lookup FIRST (port always changes on toggle) ──
                // Android assigns a new port every time wireless debugging is toggled.
                // We query mDNS immediately in every attempt — it's the most reliable signal.
                if !ip.isEmpty {
                    if let newTarget = await self.findDeviceViaMdns(adbPath: adbPath, ip: ip, hwSerial: hwSerial) {
                        if await self.tryConnect(adbPath: adbPath, target: newTarget) {
                            await self.handleReconnected(newSerial: newTarget)
                            return
                        }
                    }
                }
                
                // ── Strategy 2: Try last known target (only useful if port didn't change) ──
                if !lastTarget.isEmpty, lastTarget != "\(ip):0" {
                    if await self.tryConnect(adbPath: adbPath, target: lastTarget) {
                        await self.handleReconnected(newSerial: lastTarget)
                        return
                    }
                }
                
                // ── Strategy 3: Try saved target from UserDefaults ──
                if let savedTarget, savedTarget != lastTarget {
                    if await self.tryConnect(adbPath: adbPath, target: savedTarget) {
                        await self.handleReconnected(newSerial: savedTarget)
                        return
                    }
                }
                
                // ── Strategy 4: Try saved port with IP ──
                if let savedPort, !ip.isEmpty {
                    let portTarget = "\(ip):\(savedPort)"
                    if portTarget != lastTarget && portTarget != savedTarget {
                        if await self.tryConnect(adbPath: adbPath, target: portTarget) {
                            await self.handleReconnected(newSerial: portTarget)
                            return
                        }
                    }
                }
                
                // Wait before next attempt — rapid initial retries (mDNS takes time to index new service)
                let delay: UInt64
                switch attempt {
                case 1...5:  delay = 500_000_000      // 0.5s — mDNS may not have indexed yet
                case 6...15: delay = 1_500_000_000    // 1.5s
                default:     delay = 3_000_000_000    // 3.0s
                }
                try? await Task.sleep(nanoseconds: delay)
            }
            
            // Exhausted all attempts
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                self.isReconnecting = false
                self.reconnectMessage = "Could not reconnect. Please open connection settings."
                print("💓 [HealthMonitor] ❌ Reconnection failed after \(self.maxReconnectAttempts) attempts.")
            }
        }
    }
    
    /// Attempts `adb connect <target>`. Returns true if connection succeeded.
    private func tryConnect(adbPath: String, target: String) async -> Bool {
        let (_, out, err) = await Shell.runAsyncWithTimeout(
            adbPath, args: ["connect", target], timeoutSeconds: 4.0
        )
        let combined = (out + err).lowercased()
        let success = combined.contains("connected to") || combined.contains("already connected")
        if success {
            print("💓 [HealthMonitor] ✅ Connected to \(target)")
        } else {
            let trimmed = (out + err).trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("💓 [HealthMonitor] ❌ Failed to connect to \(target): \(trimmed)")
            }
        }
        return success
    }
    
    /// Queries `adb mdns services` for the device's connect service.
    /// Matches by IP address first, then by hardware serial as fallback.
    /// Returns the new IP:port if found, nil otherwise.
    private func findDeviceViaMdns(adbPath: String, ip: String, hwSerial: String?) async -> String? {
        let (code, output, _) = await ADBManager.mdnsServicesWithRecovery()
        guard code == 0, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        
        // Pass 1: Match by IP (most reliable — same IP unless device changed network)
        for line in output.split(separator: "\n") {
            let str = String(line)
            guard str.contains("_adb-tls-connect._tcp"),
                  str.contains(ip) else { continue }
            
            let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if let ipPort = parts.first(where: { $0.hasPrefix(ip + ":") }) {
                print("💓 [HealthMonitor] 📡 mDNS found device by IP at: \(ipPort)")
                return ipPort
            }
        }
        
        // Pass 2: Match by hardware serial (handles IP change edge case)
        if let hwSerial {
            for line in output.split(separator: "\n") {
                let str = String(line)
                guard str.contains("_adb-tls-connect._tcp") else { continue }
                
                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard let serviceName = parts.first,
                      let extractedSerial = ADBManager.extractHardwareSerial(from: serviceName),
                      extractedSerial == hwSerial else { continue }
                
                // Find the ip:port in this line
                if let ipPort = parts.first(where: { part in
                    let comps = part.split(separator: ":")
                    return comps.count >= 2 && UInt16(comps.last ?? "") != nil
                }) {
                    print("💓 [HealthMonitor] 📡 mDNS found device by HW serial at: \(ipPort)")
                    return ipPort
                }
            }
        }
        
        return nil
    }
    
    // MARK: - NWBrowser for Reconnection (Event-Driven)
    
    /// Starts an NWBrowser specifically for detecting when our device
    /// re-advertises its `_adb-tls-connect._tcp` service.
    /// This fires as soon as the service appears — acts as an interrupt
    /// to the retry loop, triggering an immediate reconnect attempt.
    private func startReconnectBrowser() {
        stopReconnectBrowser()
        
        let params = NWParameters.tcp
        if let ipOpts = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }
        params.includePeerToPeer = true
        
        let browser = NWBrowser(
            for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."),
            using: params
        )
        
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            
            for change in changes {
                switch change {
                case .added(let result):
                    // A connect service appeared — check if it belongs to our device
                    if case let .service(name, _, _, _) = result.endpoint {
                        Task { @MainActor in
                            guard self.isReconnecting else { return }
                            print("💓 [HealthMonitor] 📡 NWBrowser: connect service appeared: \(name)")
                            
                            let ip = self.monitoredIP ?? ""
                            let hwSerial = self.monitoredHWSerial
                            
                            // ── Match by hardware serial (primary — most reliable) ──
                            // mDNS service name is "adb-<hwSerial>" — e.g. "adb-RF8RC1L57RY-1234"
                            let matchedBySerial: Bool = {
                                guard let hwSerial,
                                      let extracted = ADBManager.extractHardwareSerial(from: name) else { return false }
                                return extracted == hwSerial
                            }()
                            
                            // ── Match by IP fallback (when hwSerial is unknown) ──
                            // This requires querying mDNS to resolve the service to an IP:port,
                            // so we always do the mDNS lookup regardless.
                            let isOurDevice = matchedBySerial || (!ip.isEmpty && hwSerial == nil)
                            
                            if isOurDevice || matchedBySerial {
                                print("💓 [HealthMonitor] 📡 NWBrowser: Our device is back! Triggering immediate reconnect.")
                                
                                let adbPath = ADBManager.getADBPath()
                                guard !adbPath.isEmpty else { return }
                                
                                // Small delay — give ADB's mDNS daemon time to index
                                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                                
                                if let newTarget = await self.findDeviceViaMdns(adbPath: adbPath, ip: ip, hwSerial: hwSerial) {
                                    if await self.tryConnect(adbPath: adbPath, target: newTarget) {
                                        await self.handleReconnected(newSerial: newTarget)
                                    }
                                }
                            } else {
                                // Unknown device appeared — still try if we have no IP context
                                // (handles case where monitoredIP is empty)
                                if ip.isEmpty {
                                    print("💓 [HealthMonitor] 📡 NWBrowser: service appeared, no IP context — trying mDNS lookup.")
                                    let adbPath = ADBManager.getADBPath()
                                    guard !adbPath.isEmpty else { return }
                                    try? await Task.sleep(nanoseconds: 300_000_000)
                                    if let newTarget = await self.findDeviceViaMdns(adbPath: adbPath, ip: "", hwSerial: hwSerial) {
                                        if await self.tryConnect(adbPath: adbPath, target: newTarget) {
                                            await self.handleReconnected(newSerial: newTarget)
                                        }
                                    }
                                }
                            }
                        }
                    }
                default:
                    break
                }
            }
        }
        
        browser.start(queue: browserQueue)
        reconnectBrowser = browser
        print("💓 [HealthMonitor] NWBrowser started for reconnection detection.")
    }
    
    private func stopReconnectBrowser() {
        reconnectBrowser?.cancel()
        reconnectBrowser = nil
    }
    
    // MARK: - Reconnection Success
    
    private func handleReconnected(newSerial: String) async {
        guard isMonitoring else { return }
        
        stopReconnectBrowser()
        reconnectTask?.cancel()
        reconnectTask = nil
        
        let oldSerial = monitoredSerial
        monitoredSerial = newSerial
        lastKnownTarget = newSerial
        if let ip = newSerial.components(separatedBy: ":").first,
           ip.range(of: #"^\d{1,3}(\.\d{1,3}){3}$"#, options: .regularExpression) != nil {
            monitoredIP = ip
        }
        
        print("💓 [HealthMonitor] ✅ Successfully reconnected! \(oldSerial ?? "?") → \(newSerial) (Waiting for DeviceManager confirmation)")
        
        // ── Clean up other stale ports on the same IP ──
        if let ip = monitoredIP {
            let adbPath = ADBManager.getADBPath()
            let allConnected = await ADBManager.listAllConnectedDevices()
            for dev in allConnected {
                if dev.isWireless, dev.serial.hasPrefix(ip + ":"), dev.serial != newSerial {
                    print("💓 [HealthMonitor] Disconnecting stale wireless target on same IP: \(dev.serial)")
                    let _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect", dev.serial], timeoutSeconds: 2.0)
                    deviceManager?.clearLivenessCheck(for: dev.serial)
                }
            }
        }
        
        // Persist the new target (port may have changed)
        if let ip = monitoredIP {
            var targetMap = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownTargetByIP") as? [String: String] ?? [:]
            targetMap[ip] = newSerial
            UserDefaults.standard.set(targetMap, forKey: "wirelessLastKnownTargetByIP")
            
            if let port = newSerial.split(separator: ":").last {
                var portMap = UserDefaults.standard.dictionary(forKey: "wirelessLastKnownPortByIP") as? [String: String] ?? [:]
                portMap[ip] = String(port)
                UserDefaults.standard.set(portMap, forKey: "wirelessLastKnownPortByIP")
            }
        }
        
        // Mark the device as live in DeviceManager's cache to skip initial liveness check in detectDevice()
        deviceManager?.markDeviceAsLive(newSerial)
        
        // Notify DeviceManager to refresh state
        onReconnected?()
        
        // Restart the disconnect watcher for the new serial
        startDisconnectWatcher(serial: newSerial)
    }
}
