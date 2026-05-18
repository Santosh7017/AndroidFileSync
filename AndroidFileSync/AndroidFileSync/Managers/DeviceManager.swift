//  DeviceManager.swift
//  (DEFINITIVE DETECTION FIX)
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
    
    enum ConnectionType: String {
        case none = "None"
        case usb = "USB"
        case wireless = "WiFi"
    }
    
    // MARK: - Core Logic
    
    func detectDevice() async {
        print("📱 DeviceManager: Starting device detection...")
        
        // Ensure UI shows "detecting" state
        if !isDetecting {
            await MainActor.run { 
                self.isDetecting = true 
                self.statusMessage = "Scanning for devices..."
            }
        }
        
        // Enumerate ALL connected devices first (for the device picker)
        let allDevices = await ADBManager.listAllConnectedDevices()
        await MainActor.run { self.availableDevices = allDevices }

        // Check for ADB devices (with timeout to prevent hanging)
        adbAvailable = await ADBManager.isDeviceConnected()
        print("📱 DeviceManager: ADB available = \(adbAvailable)")
        
        // Check if it's a wireless connection
        let isWireless = adbAvailable ? await ADBManager.isWirelessConnection() : false
        
        // Update the state on the main thread
        await MainActor.run {
            if adbAvailable {
                if isWireless {
                    self.connectionType = .wireless
                    self.deviceName = "Android Device"
                    self.statusMessage = "Connected via WiFi"
                } else {
                    self.connectionType = .usb
                    self.deviceName = "Android Device"
                    self.statusMessage = "Connected via USB"
                    self.lastWirelessIP = ""  // clear stale IP when on USB
                }
                self.isConnected = true
                print("📱 DeviceManager: Device connected (\(self.connectionType.rawValue))!")
            } else {
                self.connectionType = .none
                self.deviceName = "No Device"
                self.statusMessage = "No device detected. Please connect your device."
                self.isConnected = false
                self.sdCardPath = nil
                print("📱 DeviceManager: No device found")
            }
            
            // Detection is complete, hide the initial loading screen
            self.isDetecting = false
        }

        // If wireless, also populate the IP (parses `adb devices` serial like 192.168.x.x:5555)
        if adbAvailable && isWireless {
            if let ip = await ADBManager.getWirelessIP(), !ip.isEmpty {
                await MainActor.run { self.lastWirelessIP = ip }
                print("📱 DeviceManager: Wireless IP = \(ip)")
            }
        }

        // If connected, also probe for device name, SD card + storage stats
        if adbAvailable {
            await fetchDeviceName()
            await detectSDCard()
            await fetchStorageInfo()
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
                // Give ADB ~1.5 s to recognize the newly attached device
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                // Clear stale serial — detectDevice will pick the correct one
                ADBManager.activeDeviceSerial = nil
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

    // MARK: - Device Name

    /// Reads the real device name via `adb shell getprop ro.product.model`
    /// (e.g. "Redmi Note 13") and updates deviceName.
    func fetchDeviceName() async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return }
        let (_, output, _) = await Shell.runAsync(
            adbPath,
            args: ADBManager.deviceArgs(["shell", "getprop", "ro.product.model"])
        )
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            await MainActor.run { self.deviceName = name }
            print("📱 DeviceManager: Device name = \(name)")
        }
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
    func pairAndConnect(ip: String, pairingPort: String, pairingCode: String, connectPort: String) async -> (Bool, String) {
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
        
        // Step 2: Connect
        let (connectSuccess, connectMessage) = await ADBManager.connectWireless(ip: ip, port: connectPort)
        
        if connectSuccess {
            await MainActor.run {
                self.lastWirelessIP = ip
            }
            // Re-detect to update all state properly
            await detectDevice()
            return (true, "Connected wirelessly to \(ip)")
        } else {
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = connectMessage
            }
            return (false, connectMessage)
        }
    }
    
    /// Connect to a previously paired device
    func connectWirelessly(ip: String, port: String = "5555") async -> (Bool, String) {
        await MainActor.run {
            self.isDetecting = true
            self.statusMessage = "Connecting to \(ip)..."
        }
        
        let (success, message) = await ADBManager.connectWireless(ip: ip, port: port)
        
        if success {
            await MainActor.run {
                self.lastWirelessIP = ip
            }
            await detectDevice()
            return (true, message)
        } else {
            await MainActor.run {
                self.isDetecting = false
                self.statusMessage = message
            }
            return (false, message)
        }
    }
    
    /// Disconnect wireless device
    func disconnectWireless() async {
        let _ = await ADBManager.disconnectAllWireless()
        await MainActor.run {
            self.lastWirelessIP = ""
        }
        await detectDevice()
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

