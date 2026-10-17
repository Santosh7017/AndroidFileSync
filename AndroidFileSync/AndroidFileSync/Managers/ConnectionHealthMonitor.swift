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
    /// The device's hardware serial for mDNS service matching (e.g. "RF8RC1L57RY")
    private var monitoredHWSerial: String?
    
    /// Background task running `adb wait-for-disconnect`
    private var disconnectWatchTask: Task<Void, Never>?
    /// Background task attempting reconnection
    private var reconnectTask: Task<Void, Never>?
    private var staleCleanupTask: Task<Void, Never>?
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
    private let maxReconnectAttempts = 30
    private var monitoringID = UUID()
    private var reconnectDeadline: Date?
    /// True when monitoring is active (prevents double-start)
    private var isMonitoring = false
    /// Prevent the polling task and NWBrowser callback from issuing overlapping
    /// connect/TLS verification commands for the same device.
    private var isConnectAttemptInProgress = false
    private var reconnectTargetsAttempted: [String: Int] = [:]
    
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
        if isMonitoring && monitoredSerial == serial && isHealthy { return }
        
        // Clean up any existing monitoring
        forceStop()
        
        self.deviceManager = deviceManager
        monitoredSerial = serial
        monitoredIP = ip
        monitoredHWSerial = hwSerial
        isMonitoring = true
        isHealthy = true
        isReconnecting = false
        reconnectAttempt = 0
        reconnectMessage = ""
        isConnectAttemptInProgress = false
        reconnectTargetsAttempted.removeAll()
        
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
        monitoringID = UUID()
        reconnectDeadline = nil
        disconnectWatchTask?.cancel()
        disconnectWatchTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        staleCleanupTask?.cancel()
        staleCleanupTask = nil
        stopReconnectBrowser()
        
        isMonitoring = false
        deviceManager = nil
        monitoredSerial = nil
        monitoredIP = nil
        monitoredHWSerial = nil
        isHealthy = true
        isReconnecting = false
        reconnectAttempt = 0
        reconnectMessage = ""
        isConnectAttemptInProgress = false
        reconnectTargetsAttempted.removeAll()
    }
    
    /// Update the monitored serial after a successful reconnection changes the port.
    func updateSerial(_ newSerial: String) {
        let oldSerial = monitoredSerial
        monitoredSerial = newSerial
        if let address = WirelessEndpoint.address(from: newSerial) { monitoredIP = address.host }
        print("💓 [HealthMonitor] Serial updated: \(oldSerial ?? "nil") → \(newSerial)")
    }
    
    // MARK: - Disconnect Watcher (Event-Driven)
    
    /// Runs `adb -s <serial> wait-for-disconnect` as a background process.
    /// This command blocks until the ADB server detects the device has disconnected.
    /// When the process exits, we know IMMEDIATELY that the device is gone.
    private func startDisconnectWatcher(serial: String) {
        disconnectWatchTask?.cancel()
        let id = monitoringID
        
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
            
            guard let self, self.monitoringID == id, self.monitoredSerial == serial else { return }
            
            print("💓 [HealthMonitor] ⚡ Device disconnected! (wait-for-disconnect exited with code \(exitCode))")
            
            // Verify the device is actually gone (guard against spurious exits)
            let stillAlive = await self.quickLivenessCheck(serial: serial)
            guard !Task.isCancelled, self.monitoringID == id, self.monitoredSerial == serial else { return }
            if stillAlive {
                print("💓 [HealthMonitor] False alarm — device still responds. Restarting watcher.")
                // Older/shared daemons can reject wait-for-disconnect immediately.
                // Avoid an unbounded process/shell loop in that case.
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, self.monitoringID == id else { return }
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
        reconnectDeadline = Date().addingTimeInterval(30)
        reconnectTargetsAttempted.removeAll()
        let id = monitoringID
        
        // Start NWBrowser to detect when the device re-advertises
        startReconnectBrowser()
        
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }
            
            // The physical identity selects a current service, independently of old addresses.
            let ip = await MainActor.run { self.monitoredIP ?? "" }
            let hwSerial = await MainActor.run { self.monitoredHWSerial }

            for attempt in 1...self.maxReconnectAttempts {
                guard !Task.isCancelled, self.monitoringID == id, self.isMonitoring, self.isReconnecting else { return }
                if let deadline = self.reconnectDeadline, Date() >= deadline { break }
                
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
                if !ip.isEmpty || hwSerial != nil {
                    if let newTarget = await self.findDeviceViaMdns(adbPath: adbPath, ip: ip, hwSerial: hwSerial) {
                        if await self.tryConnect(adbPath: adbPath, target: newTarget) {
                            await self.handleReconnected(newSerial: newTarget)
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
            guard !Task.isCancelled, self.monitoringID == id else { return }
            
            await MainActor.run {
                self.isReconnecting = false
                self.deviceManager?.isConnected = false
                self.deviceManager?.statusMessage = "Could not reconnect. Open connection settings to retry."
                self.reconnectMessage = "Could not reconnect. Please open connection settings."
                print("💓 [HealthMonitor] ❌ Reconnection failed after \(self.maxReconnectAttempts) attempts.")
            }
        }
    }
    
    /// Attempts `adb connect <target>`. Returns true if connection succeeded.
    private func tryConnect(adbPath: String, target: String) async -> Bool {
        let id = monitoringID
        let remaining = reconnectDeadline?.timeIntervalSinceNow ?? 1.5
        guard !Task.isCancelled, isMonitoring, isReconnecting, remaining > 0,
              !isConnectAttemptInProgress, (reconnectTargetsAttempted[target] ?? 0) < 2 else { return false }
        isConnectAttemptInProgress = true
        reconnectTargetsAttempted[target, default: 0] += 1
        defer { if monitoringID == id { isConnectAttemptInProgress = false } }

        let result = await ADBManager.connectAndVerifyWirelessTarget(
            target,
            connectTimeout: min(1.5, remaining),
            verificationAttempts: 1,
            expectedHardwareSerial: monitoredHWSerial
        )
        guard !Task.isCancelled, monitoringID == id, isMonitoring, isReconnecting else { return false }
        let success = result.success
        if success {
            print("💓 [HealthMonitor] ✅ Connected and verified \(target)")
        } else {
            let lower = result.output.lowercased()
            if lower.contains("refused") || lower.contains("host is down") || lower.contains("no route") ||
               ADBManager.wirelessConnectionRequiresRepair(result.output) {
                reconnectTargetsAttempted[target] = 2
            }
            let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                print("💓 [HealthMonitor] ❌ Failed to connect to \(target): \(trimmed)")
            }
        }
        return success
    }
    
    /// Resolve a currently advertised connect service for the exact hardware identity.
    /// Returns the new IP:port if found, nil otherwise.
    private func findDeviceViaMdns(adbPath: String, ip: String, hwSerial: String?) async -> String? {
        guard let hwSerial, !hwSerial.isEmpty else { return nil }
        let result = await ADBManager.discoverWirelessEndpoints(for: [hwSerial])
        guard !Task.isCancelled else { return nil }
        return result.endpoints.first { $0.hardwareSerial == hwSerial }?.target

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
        
        let id = monitoringID
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
                            guard self.isReconnecting, self.monitoringID == id else { return }
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
                                guard self.monitoringID == id, self.isReconnecting else { return }
                                
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
                                    guard self.monitoringID == id, self.isReconnecting else { return }
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
        // The polling task and NWBrowser can discover the same endpoint at nearly
        // the same time. Only the first verified result may complete recovery.
        guard isMonitoring, isReconnecting else { return }
        isReconnecting = false
        isHealthy = true
        reconnectMessage = ""
        
        stopReconnectBrowser()
        reconnectTask = nil
        reconnectDeadline = nil
        let id = monitoringID
        
        let oldSerial = monitoredSerial
        monitoredSerial = newSerial
        if let address = WirelessEndpoint.address(from: newSerial) { monitoredIP = address.host }
        
        print("💓 [HealthMonitor] ✅ Successfully reconnected! \(oldSerial ?? "?") → \(newSerial) (Waiting for DeviceManager confirmation)")

        if let hwSerial = monitoredHWSerial {
            ADBManager.rememberWirelessDevice(target: newSerial, hardwareSerial: hwSerial,
                hostname: WirelessDiscovery.shared.endpoints.first { $0.target == newSerial }?.hostname)
        }
        deviceManager?.markDeviceAsLive(newSerial)
        onReconnected?()
        startDisconnectWatcher(serial: newSerial)
        
        // Clean up only transports belonging to the same physical device.
        staleCleanupTask?.cancel()
        staleCleanupTask = Task { [weak self] in
            guard let self, let hwSerial = self.monitoredHWSerial else { return }
            let adbPath = ADBManager.getADBPath()
            let allConnected = await ADBManager.listAllConnectedDevices()
            guard !Task.isCancelled, monitoringID == id, isMonitoring else { return }
            for dev in allConnected {
                guard !Task.isCancelled, monitoringID == id, monitoredSerial == newSerial else { return }
                if dev.isWireless, dev.derivedHardwareSerial == hwSerial, dev.serial != newSerial {
                    print("💓 [HealthMonitor] Disconnecting stale target for serial=\(hwSerial): \(dev.serial)")
                    let _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect", dev.serial], timeoutSeconds: 2.0)
                    deviceManager?.clearLivenessCheck(for: dev.serial)
                }
            }
        }
    }
}
