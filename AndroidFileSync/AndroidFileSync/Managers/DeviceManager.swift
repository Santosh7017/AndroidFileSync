//  DeviceManager.swift
//

import Foundation
internal import Combine

@MainActor
class DeviceManager: ObservableObject {
    
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
    /// True when there is an active file transfer — prevents false USB disconnects from ADB contention
    @Published var isTransferActive = false {
        didSet {
            if !isTransferActive, pendingUSBEvent {
                pendingUSBEvent = false
                Task { await detectDevice() }
            }
        }
    }
    
    /// Event-driven wireless connection health monitor.
    /// Uses `adb wait-for-disconnect` for instant disconnect detection and
    /// NWBrowser + targeted reconnect for automatic recovery.
    let connectionHealthMonitor = ConnectionHealthMonitor()

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
    private let adbMonitor = ADBDeviceMonitor()
    private var initializedSerial: String?
    private var usbDetectionTask: Task<Void, Never>?
    /// True when user explicitly disconnected — prevents auto-reconnect
    @Published var userDisconnected = false
    /// True when the background device diagnostics task has completed
    @Published var diagnosticsComplete = false
    /// Prevent overlapping detection runs that can flood ADB and mDNS queries.
    private var isDetectionInProgress = false
    private var detectionGeneration = UUID()
    private var pendingDetection = false
    private var pendingDetectionShowsProgress = false
    /// A short window after a physical USB event where a newly listed ADB USB
    /// serial should become active even if a wireless serial is already active.
    private var preferUSBUntil: Date? = nil
    /// Rate-limit default-server USB ownership recovery during normal detection.
    private var lastUSBTransportRecoveryAt: Date? = nil
    /// Single in-flight wireless hunt task to avoid spawning one per detect cycle.
    private var wirelessHuntTask: Task<Void, Never>? = nil
    private var wirelessHuntID = UUID()
    private var prewarmedSerials = Set<String>()
    private var pendingUSBEvent = false
    private var metadataTask: Task<Void, Never>?
    private enum ReconnectEvent {
        case tick
        case discovery([WirelessEndpoint], String)
        case serverRecovered
        case connected(WirelessReconnectCandidate, Bool, String)
    }
    var isWirelessReconnectHuntActive: Bool {
        guard let wirelessHuntTask else { return false }
        return !wirelessHuntTask.isCancelled
    }
    /// Background diagnostics task — cancelled on disconnect to avoid stale serial queries.
    private var diagnosticsTask: Task<Void, Never>? = nil
    private static let wirelessReconnectCooldown: TimeInterval = 30.0
    private var hasFinishedWirelessSearch = false
    private var attemptedWirelessEndpoints: [String: Date] = [:]
    private var discoveredWirelessEndpoints: [WirelessEndpoint] = []
    private var discoveredWirelessEndpointsAt = Date.distantPast
    private var freshDiscoveredWirelessEndpoints: [WirelessEndpoint] {
        Date().timeIntervalSince(discoveredWirelessEndpointsAt) < 6
            ? discoveredWirelessEndpoints.filter { WirelessDiscovery.shared.acceptsSnapshot($0) } : []
    }
    private var passiveDiscoveryTask: Task<Void, Never>?
    private var lastPassiveDiscoveryAt = Date.distantPast
    /// Cache last liveness check timestamp per wireless serial to prevent spamming adb shell commands.
    private var lastLivenessCheckAt: [String: Date] = [:]
    private var autoClaimUSB: Bool {
        UserDefaults.standard.bool(forKey: "autoClaimUSB")
    }

    enum ConnectionType: String {
        case none = "None"
        case usb = "USB"
        case wireless = "WiFi"
    }
    
    // MARK: - Core Logic

    private func startWirelessReconnectIfNeeded(connectedDevices: [ADBManager.ConnectedDevice]) {
        guard !AppProcessLifecycle.isTerminating, !userDisconnected, !ADBPairingBrowser.suppressAutoConnect,
              !ADBPairingBrowser.isPairingActive, !ADBManager.isPairingInProgress,
              wirelessHuntTask == nil, !connectionHealthMonitor.isReconnecting,
              !ADBManager.getADBPath().isEmpty else { return }
        let knownIDs = Set(ADBManager.rememberedWirelessSerials)
        guard !knownIDs.isEmpty else { return }
        let connectedIDs = Set(connectedDevices.filter {
            $0.status == "device" && $0.isWireless && lastLivenessCheckAt[$0.serial] != nil
        }.compactMap(\.derivedHardwareSerial))
        let missing = knownIDs.subtracting(connectedIDs)
        guard !missing.isEmpty else { return }
        let candidates = WirelessReconnectPolicy.candidates(
            endpoints: WirelessDiscovery.shared.endpoints + freshDiscoveredWirelessEndpoints, rememberedSerials: missing)
        let hasNewEndpoint = candidates.contains {
            attemptedWirelessEndpoints[$0.target].map { Date().timeIntervalSince($0) >= Self.wirelessReconnectCooldown } ?? true
        }
        if hasFinishedWirelessSearch && !hasNewEndpoint {
            // Continue discovery quietly; do not reopen a loading/retry loop for old addresses.
            refreshPassiveWirelessDiscovery(serials: missing)
            return
        }
        let id = UUID()
        wirelessHuntID = id
        wirelessHuntTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.wirelessHuntID == id {
                    self.wirelessHuntTask = nil
                    self.hasFinishedWirelessSearch = true
                    if !self.isConnected, !self.isDetectionInProgress, !self.pendingDetection {
                        self.isDetecting = false
                        if self.availableDevices.isEmpty {
                            self.statusMessage = "No matching device discovered. Enable Wireless debugging and keep the phone on the same Wi-Fi."
                        }
                    }
                }
            }
            await self.reconnectRememberedDevices(id: id, serials: missing)
        }
        if !hasFinishedWirelessSearch, !isConnected,
           !connectedDevices.contains(where: { $0.status == "unauthorized" }) {
            isDetecting = true
            statusMessage = "Looking for your paired device..."
        }
    }

    private func refreshPassiveWirelessDiscovery(serials: Set<String>) {
        guard passiveDiscoveryTask == nil, Date().timeIntervalSince(lastPassiveDiscoveryAt) >= 10 else { return }
        lastPassiveDiscoveryAt = Date()
        passiveDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { self.passiveDiscoveryTask = nil }
            let result = await ADBManager.discoverWirelessEndpoints(for: serials)
            guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return }
            self.discoveredWirelessEndpoints = result.endpoints
            self.discoveredWirelessEndpointsAt = Date()
            self.startWirelessReconnectIfNeeded(connectedDevices: self.availableDevices)
        }
    }

    private func reconnectRememberedDevices(id: UUID, serials: Set<String>) async {
        let deadline = Date().addingTimeInterval(20)
        var connectedIDs = Set<String>()
        var active = Set<String>()
        var attempts: [String: Int] = [:]
        var lastAttempts: [String: Date] = [:]
        var discoveryInFlight = false
        var lastDiscovery = Date.distantPast
        var tickInFlight = false
        var recoveryNeeded = false
        var recoveryAttempted = false
        var recoveringServer = false
        AppLogger.log("📱 [StartupReconnect] Resolving current connect services for serials=\(serials.sorted())")
        await withTaskGroup(of: ReconnectEvent.self) { group in
            while Date() < deadline, !Task.isCancelled, wirelessHuntID == id,
                  !userDisconnected, !ADBPairingBrowser.isPairingActive, !ADBManager.isPairingInProgress {
                // Detection/metadata may confirm a phone while this hunt is
                // waiting on discovery for another identity. Retire that phone
                // instead of connecting it again when its next SRV update arrives.
                connectedIDs.formUnion(availableDevices.filter {
                    $0.status == "device" && $0.isWireless && lastLivenessCheckAt[$0.serial] != nil
                }.compactMap(\.derivedHardwareSerial))
                if serials.isSubset(of: connectedIDs) { group.cancelAll(); return }
                let missing = serials.subtracting(connectedIDs)
                let candidates = WirelessReconnectPolicy.candidates(
                    endpoints: WirelessDiscovery.shared.endpoints + freshDiscoveredWirelessEndpoints, rememberedSerials: missing)
                let shouldRecover = recoveryNeeded && !recoveryAttempted && active.isEmpty &&
                    !isConnected && ADBManager.activeDeviceSerial == nil && !Shell.useDefaultServer
                for candidate in candidates where !shouldRecover && !recoveringServer && active.count < 2 {
                    guard !active.contains(candidate.target), (attempts[candidate.target] ?? 0) < 2,
                          lastAttempts[candidate.target].map({ Date().timeIntervalSince($0) >= 3 }) ?? true else { continue }
                    let isRetry = attempts[candidate.target] != nil
                    attempts[candidate.target, default: 0] += 1
                    lastAttempts[candidate.target] = Date()
                    attemptedWirelessEndpoints[candidate.target] = Date()
                    active.insert(candidate.target)
                    group.addTask {
                        let result = await ADBManager.connectAndVerifyWirelessTarget(candidate.target,
                            connectTimeout: 2.5, verificationAttempts: 1,
                            expectedHardwareSerial: candidate.hardwareSerial, refreshStaleTransport: isRetry)
                        return .connected(candidate, result.success, result.output)
                    }
                }
                if !discoveryInFlight, Date().timeIntervalSince(lastDiscovery) >= 1 {
                    discoveryInFlight = true
                    lastDiscovery = Date()
                    group.addTask { [weak self] in
                        let result = await ADBManager.discoverWirelessEndpoints(for: missing) { [weak self] endpoint in
                            guard let self, self.wirelessHuntID == id, !Task.isCancelled,
                                  WirelessDiscovery.shared.acceptsSnapshot(endpoint) else { return }
                            self.discoveredWirelessEndpoints.removeAll { $0.serviceName == endpoint.serviceName }
                            self.discoveredWirelessEndpoints.append(endpoint)
                            self.discoveredWirelessEndpointsAt = Date()
                        }
                        return .discovery(result.endpoints, result.error)
                    }
                }
                if shouldRecover {
                    recoveryAttempted = true
                    recoveringServer = true
                    group.addTask {
                        _ = await ADBManager.restartServer()
                        return .serverRecovered
                    }
                }
                if !tickInFlight {
                    tickInFlight = true
                    group.addTask {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        return .tick
                    }
                }
                guard let event = await group.next(), !Task.isCancelled, wirelessHuntID == id else { break }
                switch event {
                case .tick: tickInFlight = false
                case .discovery(let endpoints, let error):
                    discoveryInFlight = false
                    discoveredWirelessEndpoints = endpoints
                    discoveredWirelessEndpointsAt = Date()
                    if ADBManager.isProtocolError(error) { recoveryNeeded = true }
                case .serverRecovered:
                    recoveringServer = false
                    attempts.removeAll()
                    lastAttempts.removeAll()
                case .connected(let candidate, let success, let output):
                    active.remove(candidate.target)
                    AppLogger.log("📱 [StartupReconnect] serial=\(candidate.hardwareSerial ?? "unknown"), target=\(candidate.target), result=\(success ? "connected" : output)")
                    if ADBManager.isProtocolError(output) { recoveryNeeded = true }
                    if success {
                        if let hw = candidate.hardwareSerial { connectedIDs.insert(hw) }
                        markDeviceAsLive(candidate.target)
                        await detectDevice()
                        if serials.isSubset(of: connectedIDs) { group.cancelAll(); return }
                    } else {
                        let lower = output.lowercased()
                        if lower.contains("refused") || lower.contains("host is down") || lower.contains("no route") ||
                           ADBManager.wirelessConnectionRequiresRepair(output) || lower.contains("identity did not match") {
                            // A closed port is obsolete. Wait for a different resolved endpoint.
                            attempts[candidate.target] = 2
                        }
                    }
                }
            }
            group.cancelAll()
        }
    }

    func detectDevice(showProgress: Bool = false) async {
        guard !AppProcessLifecycle.isTerminating else { return }
        if showProgress {
            isDetecting = true
            statusMessage = "Scanning for devices..."
        }

        if isDetectionInProgress {
            pendingDetection = true
            pendingDetectionShowsProgress = pendingDetectionShowsProgress || showProgress
            return
        }
        isDetectionInProgress = true
        let generation = detectionGeneration
        defer {
            if detectionGeneration == generation {
                isDetectionInProgress = false
                if pendingDetection {
                    let showPendingProgress = pendingDetectionShowsProgress
                    pendingDetection = false
                    pendingDetectionShowsProgress = false
                    Task {
                        guard self.detectionGeneration == generation else { return }
                        await self.detectDevice(showProgress: showPendingProgress)
                    }
                }
            }
        }

        AppLogger.log("📱 [DeviceDetection] Starting device detection...")

        // Fast path: Check for already-connected devices (USB or existing wireless session)
        var allDevices = await ADBManager.listAllConnectedDevices { [weak self] devices, completedPorts in
            guard let self, self.detectionGeneration == generation,
                  !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return }
            // An unfinished daemon query says nothing about its existing devices.
            let pendingDevices = self.availableDevices.filter { existing in
                !completedPorts.contains(Shell.serverPortBySerial[existing.serial] ?? Shell.appADBServerPort) &&
                !devices.contains(where: { $0.serial == existing.serial })
            }
            await self.applyDeviceSnapshot(devices + pendingDevices, generation: generation)
        }
        guard detectionGeneration == generation else { return }
        guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else { isDetecting = false; return }

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
        
        await applyDeviceSnapshot(allDevices, generation: generation)
    }

    private func applyDeviceSnapshot(_ snapshot: [ADBManager.ConnectedDevice], generation: UUID) async {
        guard detectionGeneration == generation, !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return }
        var allDevices = snapshot
        lastLivenessCheckAt = lastLivenessCheckAt.filter { serial, _ in
            snapshot.contains { $0.serial == serial && $0.status == "device" }
        }
        // Derive active device from the list (same logic as isDeviceConnected but without a second adb call)
        if !allDevices.isEmpty {
            let ready = allDevices.filter { $0.status == "device" }
            let selected = ready.first { $0.serial == ADBManager.activeDeviceSerial }
                ?? ready.first { !$0.isWireless } ?? ready.first
            if let selected, selected.isWireless {
                let now = Date()
                let monitoredAndHealthy = isConnected && connectionHealthMonitor.monitoredSerial == selected.serial &&
                    connectionHealthMonitor.isHealthy
                if !monitoredAndHealthy, lastLivenessCheckAt[selected.serial].map({ now.timeIntervalSince($0) < 15 }) != true {
                    let (code, output, _) = await Shell.runAsyncWithTimeout(ADBManager.getADBPath(),
                        args: ["-s", selected.serial, "shell", "echo", "ok"], timeoutSeconds: 1.5)
                    guard detectionGeneration == generation, !Task.isCancelled else { return }
                    if code == 0, output.trimmingCharacters(in: .whitespacesAndNewlines) == "ok" {
                        lastLivenessCheckAt[selected.serial] = now
                    } else {
                        allDevices.removeAll { $0.serial == selected.serial }
                        lastLivenessCheckAt.removeValue(forKey: selected.serial)
                        // Clear stale transport asynchronously; no saved identity is removed.
                        Task {
                            _ = await Shell.runAsyncWithTimeout(ADBManager.getADBPath(),
                                args: ["disconnect", selected.serial], timeoutSeconds: 1)
                        }
                    }
                }
            }

            let readyDevices = allDevices.filter { $0.status == "device" }
            let usbSerial = readyDevices.first(where: { !$0.isWireless })?.serial
            let wirelessSerial = readyDevices.first(where: { $0.isWireless })?.serial
            
            let isWirelessActive = isConnected && connectionType == .wireless
            let shouldPreferUSB = (preferUSBUntil.map { Date() <= $0 } ?? false) && !isWirelessActive

            if shouldPreferUSB, let usbSerial {
                ADBManager.activeDeviceSerial = usbSerial
                preferUSBUntil = nil
                print("📱 DeviceManager: USB attach detected, switching to USB device: \(usbSerial)")
            } else if let current = ADBManager.activeDeviceSerial, readyDevices.contains(where: { $0.serial == current }) {
                // Keep current active device
                print("📱 DeviceManager: Keeping active device: \(current)")
            } else if let usbSerial {
                ADBManager.activeDeviceSerial = usbSerial
                print("📱 DeviceManager: Using USB device: \(usbSerial)")
            } else if let wirelessSerial {
                ADBManager.activeDeviceSerial = wirelessSerial
                print("📱 DeviceManager: Using wireless device: \(wirelessSerial)")
            } else {
                ADBManager.activeDeviceSerial = allDevices.first?.serial
            }
            adbAvailable = !allDevices.isEmpty
        } else {
            adbAvailable = false
            ADBManager.activeDeviceSerial = nil
        }
        
        startWirelessReconnectIfNeeded(connectedDevices: allDevices)

        // If user explicitly disconnected, don't auto-pick wireless devices
        if userDisconnected, let serial = ADBManager.activeDeviceSerial, ADBManager.isWirelessSerial(serial) {
            adbAvailable = false
            ADBManager.activeDeviceSerial = nil
        }
        AppLogger.log("📱 [DeviceDetection] ADB available=\(adbAvailable), active=\(ADBManager.activeDeviceSerial ?? "nil")")
        
        // Determine connection type from the active serial
        let activeSerial = ADBManager.activeDeviceSerial
        if let activeSerial, let port = Shell.serverPortBySerial[activeSerial] {
            Shell.useDefaultServer = port == 5037
        }
        let isWireless = adbAvailable && (activeSerial.map { ADBManager.isWirelessSerial($0) } ?? false)
        
        // Update the state on the main thread
        await MainActor.run {
            guard self.detectionGeneration == generation, !Task.isCancelled else { return }
            // Update availableDevices atomically with isConnected to prevent
            // the UI from briefly seeing devices while isConnected is still false,
            // which causes the "Connection Blocked" screen to flash.
            self.availableDevices = allDevices

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
                        if let serial = activeSerial, let address = WirelessEndpoint.address(from: serial) {
                            self.lastWirelessIP = address.host
                        } else {
                            self.lastWirelessIP = ""
                        }
                    } else {
                        self.connectionType = .usb
                        // Reflect coexistence mode in the status so user knows the device is shared
                        self.statusMessage = Shell.useDefaultServer
                            ? "Connected via USB · Shared with Android Studio"
                            : "Connected via USB"
                    }
                    self.isConnected = true

                    
                    // task and silently kill the upload popup. It resets only on disconnect.
                    AppLogger.log("📱 [DeviceDetection] Device connected (\(self.connectionType.rawValue))!")
                    
                    // If the health monitor was reconnecting, dismiss the banner
                    // (detectDevice is called by the health monitor on reconnect success)
                    if self.connectionHealthMonitor.isReconnecting {
                        self.connectionHealthMonitor.isReconnecting = false
                        self.connectionHealthMonitor.isHealthy = true
                        self.connectionHealthMonitor.reconnectMessage = ""
                    }
                }
            } else {
                // Don't mark as disconnected if the health monitor is actively reconnecting —
                // let it handle the state so the reconnection banner stays visible.
                if !self.connectionHealthMonitor.isReconnecting {
                    self.connectionType = .none
                    self.deviceName = "No Device"
                    self.statusMessage = self.isWirelessReconnectHuntActive
                        ? "Reconnecting to your device..." : "No device detected. Please connect your device."
                    self.isConnected = false
                    self.availableDevices = []
                    self.diagnosticsComplete = false
                    self.initializedSerial = nil
                    self.metadataTask?.cancel()
                    self.diagnosticsTask?.cancel()
                    self.sdCardPath = nil
                    self.storageStats = [:]
                    // Only clear lastWirelessIP if no wireless device is available at all
                    if !allDevices.contains(where: { $0.isWireless }) {
                        self.lastWirelessIP = ""
                    }
                    AppLogger.log(self.isWirelessReconnectHuntActive
                        ? "📱 [DeviceDetection] Waiting for wireless recovery"
                        : "📱 [DeviceDetection] No device found")
                } else {
                    AppLogger.log("📱 [DeviceDetection] Health monitor is reconnecting — keeping state for banner.")
                }
            }
            
            // An empty snapshot during startup is provisional until the hunt
            // finishes. Keep authorization prompts visible when action is needed.
            let needsAuthorization = allDevices.contains { $0.serial == activeSerial && $0.status == "unauthorized" }
            self.isDetecting = !self.isConnected && !needsAuthorization &&
                ((self.isWirelessReconnectHuntActive && !self.hasFinishedWirelessSearch) || self.pendingDetection)
        }
        guard detectionGeneration == generation, !Task.isCancelled else { return }

        // If connected and authorized, fetch non-critical metadata concurrently so we don't block the UI
        let isAuthorized = allDevices.first(where: { $0.serial == ADBManager.activeDeviceSerial })?.status == "device"
        if !isAuthorized {
            initializedSerial = nil
            metadataTask?.cancel()
            diagnosticsTask?.cancel()
        }
        if adbAvailable && isAuthorized {
            guard initializedSerial != activeSerial else { return }
            initializedSerial = activeSerial
            
            // Warm shared storage once per transport, without recursive media scans.
            if let serial = activeSerial, prewarmedSerials.insert(serial).inserted {
                Task {
                    let adbPath = ADBManager.getADBPath()
                    guard !adbPath.isEmpty else { return }
                    for path in ["/storage/emulated/0/DCIM/Camera", "/storage/emulated/0/DCIM", "/storage/emulated/0/Pictures"] {
                        let escaped = FileNameHelper.escapeForSingleQuotedShell(path)
                        _ = await Shell.runAsyncWithTimeout(adbPath,
                            args: ["-s", serial, "shell", "ls '\(escaped)' >/dev/null 2>&1"],
                            timeoutSeconds: 5)
                    }
                }
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
            
            metadataTask?.cancel()
            metadataTask = Task {
                guard let target = activeSerial, !Task.isCancelled else { return }
                if isWireless {
                    let currentIP = await MainActor.run { self.lastWirelessIP }
                    if currentIP.isEmpty, let resolvedIP = await ADBManager.getWirelessIP() {
                        guard !Task.isCancelled, ADBManager.activeDeviceSerial == target else { return }
                        await MainActor.run { self.lastWirelessIP = resolvedIP }
                    }
                    
                    if ADBManager.activeDeviceSerial == target {
                        // Resolve hardware serial for mDNS matching
                        let hwSerial = await ADBManager.getHardwareSerial(for: target)
                        
                        guard !Task.isCancelled, ADBManager.activeDeviceSerial == target else { return }
                        if let hwSerial {
                            // Discovery callbacks use this published snapshot. Keep
                            // its identity in sync with the newly resolved cache so
                            // an already connected IP transport isn't considered missing.
                            if let index = self.availableDevices.firstIndex(where: { $0.serial == target }) {
                                self.availableDevices[index].hardwareSerial = hwSerial
                            }
                            ADBManager.rememberWirelessDevice(target: target, hardwareSerial: hwSerial,
                                hostname: WirelessDiscovery.shared.endpoints.first { $0.target == target }?.hostname)

                        }
                        
                        // ── Start event-driven wireless connection health monitor ──
                        let monitorIP = await MainActor.run { self.lastWirelessIP }
                        await MainActor.run {
                            guard self.detectionGeneration == generation, !Task.isCancelled,
                                  ADBManager.activeDeviceSerial == target else { return }
                            self.connectionHealthMonitor.startMonitoring(
                                serial: target,
                                ip: monitorIP,
                                hwSerial: hwSerial,
                                deviceManager: self
                            )
                        }
                    }
                } else {
                    // USB connection — stop wireless health monitoring
                    await MainActor.run {
                        self.connectionHealthMonitor.stopMonitoring()
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
        initializedSerial = nil
        if isConnected {
            Task { await detectDevice() }
        }
    }

    // MARK: - Device Switching

    func cancelWirelessReconnectHunt() {
        wirelessHuntID = UUID()
        wirelessHuntTask?.cancel()
        wirelessHuntTask = nil
    }

    /// Runs a fresh, user-visible connection attempt from the empty state.
    /// Unlike periodic background detection, this keeps `isDetecting` true for
    /// the complete wireless discovery window so the UI reflects the work.
    func retryDeviceDetection() async {
        AppLogger.log("📱 [DeviceDetection] User requested a connection retry.")
        isDetecting = true
        statusMessage = "Scanning for devices..."

        let previousHunt = wirelessHuntTask
        cancelWirelessReconnectHunt()
        if let previousHunt {
            await previousHunt.value
        }

        hasFinishedWirelessSearch = false
        attemptedWirelessEndpoints.removeAll()
        discoveredWirelessEndpoints.removeAll()
        WirelessDiscovery.shared.refresh()
        userDisconnected = false
        ADBPairingBrowser.suppressAutoConnect = false

        await detectDevice(showProgress: true)

        // detectDevice starts wireless discovery as a managed background task.
        // Wait for that task so callers and accessibility state reflect the full retry.
        if let activeHunt = wirelessHuntTask {
            await activeHunt.value
        }

        if !isConnected {
            isDetecting = false
        }
        AppLogger.log("📱 [DeviceDetection] User retry finished. connected=\(isConnected), status='\(statusMessage)'")
    }

    /// Switch the active ADB device (e.g. from wireless -> USB or between two devices)
    /// and re-detect all state.
    func switchToDevice(serial: String) async {
        connectionHealthMonitor.stopMonitoring()
        metadataTask?.cancel()
        initializedSerial = nil
        cancelWirelessReconnectHunt()
        userDisconnected = false
        ADBPairingBrowser.suppressAutoConnect = false
        ADBManager.switchToDevice(serial: serial)
        await detectDevice()
    }

    /// Switch using an already listed device snapshot so the UI responds immediately.
    /// A full detect still runs in the background to refresh metadata and storage state.
    func switchToDevice(_ device: ADBManager.ConnectedDevice) {
        connectionHealthMonitor.stopMonitoring()
        metadataTask?.cancel()
        initializedSerial = nil
        cancelWirelessReconnectHunt()
        // User is explicitly switching — allow the new wireless device to be picked up
        userDisconnected = false
        ADBPairingBrowser.suppressAutoConnect = false
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
        // ContentView can appear more than once during window/view lifecycle
        // changes. Keep the existing IOKit monitor instead of replacing it.
        guard usbMonitor == nil, !AppProcessLifecycle.isTerminating else { return }
        adbMonitor.onChange = { [weak self] in
            guard let self else { return }
            Task { await self.detectDevice() }
        }
        adbMonitor.start()
        WirelessDiscovery.shared.onChange = { [weak self] in
            guard let self else { return }
            self.startWirelessReconnectIfNeeded(connectedDevices: self.availableDevices)
        }
        WirelessDiscovery.shared.start()
        startWirelessReconnectIfNeeded(connectedDevices: availableDevices)

        // ── Wire up ConnectionHealthMonitor callbacks ──
        connectionHealthMonitor.onReconnected = { [weak self] in
            guard let self else { return }
            print("📱 DeviceManager: Health monitor reconnected! Refreshing device state...")
            // Update the active device serial to the reconnected target
            if let newSerial = self.connectionHealthMonitor.monitoredSerial {
                ADBManager.switchToDevice(serial: newSerial)
            }
            Task {
                await self.detectDevice()
            }
        }
        connectionHealthMonitor.onDisconnected = { [weak self] in
            guard let self else { return }
            print("📱 DeviceManager: Health monitor detected disconnect!")
            // Don't clear isConnected here — the health monitor is handling reconnection.
            // Just update the status message to show the reconnection banner.
            self.statusMessage = "Device disconnected. Reconnecting..."
        }
        
        let monitor = USBDeviceMonitor()
        
        // USB device plugged in — poll for ADB to register the new device
        monitor.onDeviceAdded = { [weak self] in
            guard let self else { return }
            guard !self.isTransferActive else {
                self.pendingUSBEvent = true
                return
            }
            self.usbDetectionTask?.cancel()
            self.usbDetectionTask = Task {
                await MainActor.run {
                    self.preferUSBUntil = Date().addingTimeInterval(6.0)
                }

                let previousDeviceCount = await MainActor.run { self.availableDevices.count }
                await self.detectDevice()
                
                var attemptedUSBTransportRecovery = false
                for _ in 1...4 {
                    guard !Task.isCancelled else { return }
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
            guard !self.isTransferActive else {
                self.pendingUSBEvent = true
                return
            }
            Task {
                let wasUSB = await MainActor.run {
                    self.isConnected && self.connectionType == .usb
                }
                
                if wasUSB {
                    // IOKit fires for ALL USB devices (mouse, keyboard, etc.).
                    // Quick `adb devices` check to confirm our Android device is actually gone.
                    let adbPath = ADBManager.getADBPath()
                    let activeSerial = ADBManager.activeDeviceSerial
                    let (code, devOutput, _) = await Shell.runAsyncWithTimeout(
                        adbPath, args: ["devices"], timeoutSeconds: 2.0
                    )
                    // A failed query after an unrelated accessory is removed is
                    // not evidence that the phone disconnected.
                    guard code == 0, ADBManager.activeDeviceSerial == activeSerial else { return }
                    let stillListed = devOutput.split(separator: "\n").contains { line in
                        let fields = line.split(whereSeparator: { $0.isWhitespace })
                        return fields.count >= 2 && String(fields[0]) == activeSerial && fields[1] == "device"
                    }
                    
                    if !stillListed {
                        // Preserve wireless entries — only remove USB device from the list
                        let wirelessDevices = await MainActor.run {
                            self.availableDevices.filter { $0.isWireless && $0.status == "device" }
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
                await self.detectDevice()
            }
        }
        
        monitor.start()
        usbMonitor = monitor
        print("📡 IOKit USB monitor started")
    }

    func stopMonitoring() {
        detectionGeneration = UUID()
        isDetectionInProgress = false
        adbMonitor.stop()
        adbMonitor.onChange = nil
        usbDetectionTask?.cancel()
        usbDetectionTask = nil
        initializedSerial = nil
        cancelWirelessReconnectHunt()
        passiveDiscoveryTask?.cancel()
        passiveDiscoveryTask = nil
        metadataTask?.cancel()
        metadataTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        pendingDetection = false
        pendingDetectionShowsProgress = false
        pendingUSBEvent = false
        connectionHealthMonitor.stopMonitoring()
        connectionHealthMonitor.onReconnected = nil
        connectionHealthMonitor.onDisconnected = nil
        WirelessDiscovery.shared.onChange = nil
        usbMonitor?.onDeviceAdded = nil
        usbMonitor?.onDeviceRemoved = nil
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

        // Flush filesystem buffers so df reports accurate values after deletes
        let _ = await Shell.runAsync(adbPath, args: ADBManager.deviceArgs(["shell", "sync"]))

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
        cancelWirelessReconnectHunt()
        ADBPairingBrowser.isPairingActive = true
        defer { ADBPairingBrowser.isPairingActive = false }

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
        cancelWirelessReconnectHunt()
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
            await detectDevice()
            return (true, message)
        } else {
            // A route failure or sleeping phone does not invalidate Android's saved
            // pairing. Preserve the reconnect record; only flag an explicit ADB
            // authentication rejection as requiring a new pairing handshake.
            if ADBManager.wirelessConnectionRequiresRepair(message) {
                ADBPairingBrowser.needsRepairing.insert(ip)
            }
            
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = message
            }
            return (false, message)
        }
    }
    
    
    /// Mark a device as live in the liveness check cache to prevent detectDevice from querying it again immediately.
    func markDeviceAsLive(_ serial: String) {
        lastLivenessCheckAt[serial] = Date()
    }
    
    /// Clear a device from the liveness check cache so it will be queried again.
    func clearLivenessCheck(for serial: String) {
        lastLivenessCheckAt.removeValue(forKey: serial)
    }

    /// Disconnects the currently active wireless device only.
    /// Other connected devices (USB or additional WiFi) are left intact.
    func disconnectWireless() async {
        cancelWirelessReconnectHunt()
        metadataTask?.cancel()
        userDisconnected = true
        ADBPairingBrowser.suppressAutoConnect = true
        // Stop health monitor — this is an intentional disconnect, not a transient one.
        connectionHealthMonitor.stopMonitoring()
        
        let activeSerial = ADBManager.activeDeviceSerial
        let hardwareSerial = availableDevices.first { $0.serial == activeSerial }?.derivedHardwareSerial
            ?? ADBManager.rememberedWirelessDevices.first { $0.target == activeSerial }?.hardwareSerial

        // Disconnect only the active wireless ADB connection using its exact serial.
        // Works for both IP:port ("192.168.1.5:38101") and mDNS ("adb-XXX._adb-tls-connect._tcp") serials.
        if let serial = activeSerial, ADBManager.isWirelessSerial(serial) {
            let adbPath = ADBManager.getADBPath()
            if !adbPath.isEmpty {
                let _ = await Shell.runAsyncWithTimeout(
                    adbPath, args: ["disconnect", serial], timeoutSeconds: 5.0
                )
            }
        }

        // Clear only this device's saved reconnect data
        if let hardwareSerial { ADBManager.forgetWirelessDevice(hardwareSerial: hardwareSerial) }
        // Only block wireless auto-reconnect if no other wireless devices remain.
        // Otherwise detectDevice's userDisconnected guard would kill them too.
        let remaining = await ADBManager.listAllConnectedDevices()
        let otherWirelessStillConnected = remaining.contains { $0.isWireless }

        await MainActor.run {
            if otherWirelessStillConnected {
                self.userDisconnected = false
                ADBPairingBrowser.suppressAutoConnect = false
                // Another wireless device is still connected — don't block it
                self.lastWirelessIP = ""
            } else {
                self.userDisconnected = true
                self.lastWirelessIP = ""
                ADBPairingBrowser.suppressAutoConnect = true
            }
        }
        ADBManager.invalidateFolderSizeCache()
        // Re-detect: picks up remaining connected devices (USB, other WiFi)
        await detectDevice()
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
    
    /// Queries default port 5037 to check if there is a physical USB device occupied by another server.
    /// Returns false if we are already in shared/coexistence mode — because in that state the device
    /// is accessible to this app and there is nothing to "claim".
    func isUSBDeviceOccupiedByDefaultServer() async -> Bool {
        // If we are already piggybacking on the default server, the device is accessible — not "occupied".
        if Shell.useDefaultServer { return false }
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return false }
        let (_, defaultOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["devices", "-l"],
            timeoutSeconds: 2.0,
            environment: Shell.defaultADBEnvironment
        )
        // Only report as occupied if the default server has USB AND our private server does not
        guard defaultOutput.contains(" usb:") else { return false }
        // Double-check that our private server does NOT already have it
        let (_, privateOutput, _) = await Shell.runAsyncWithTimeout(
            adbPath,
            args: ["devices", "-l"],
            timeoutSeconds: 2.0,
            environment: Shell.adbEnvironment
        )
        return !privateOutput.contains(" usb:")
    }
}
