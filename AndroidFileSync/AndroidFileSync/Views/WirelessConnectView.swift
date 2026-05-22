//
//  WirelessConnectView.swift
//  AndroidFileSync
//
//  Wireless ADB pairing and connection (Android 11+)
//  Supports QR code pairing and manual pairing
//

import SwiftUI
import Network
internal import Combine
import CoreImage.CIFilterBuiltins

// MARK: - mDNS Pairing Browser

enum AutoDiscoveryStatus: Equatable {
    case idle
    case searching
    case deviceFound
    case pairing
    case paired
    case failed(String)
}

struct DiscoveredDevice: Identifiable, Equatable {
    /// Stable identity: Bonjour service name (e.g. "adb-XXXX") when known, otherwise the IP.
    var id: String { serviceName ?? ip }
    let ip: String
    /// Bonjour service name, e.g. "adb-XXXX" — stable across IP changes (ADB 37+)
    let serviceName: String?
    /// mDNS hostname, e.g. "adb-XXXX.local" — preferred connect target (ADB 37+)
    let hostname: String?
    var pairingPort: UInt16?
    var connectPort: UInt16?
    var verifiedPaired: Bool?
}

/// Browses the local network for ADB pairing services via mDNS.
/// Uses NWBrowser and NWConnection for real-time resolution (bypasses mDNSResponder cache).
class ADBPairingBrowser: ObservableObject {
    @Published var status: AutoDiscoveryStatus = .idle
    /// Keyed by stable service name (e.g. "adb-XXXX") when available, otherwise by IP.
    @Published var discoveredDevices: [String: DiscoveredDevice] = [:]
    /// When true, skip all automatic `adb connect` calls (user explicitly disconnected)
    static var suppressAutoConnect = false
    /// Tracks IPs currently being auto-connected to prevent spamming adb commands
    @MainActor static var autoConnectingIPs = Set<String>()
    /// IPs where connection failed (authorization revoked) — need re-pairing.
    /// Prevents auto-reconnect and forces the pairing form in the UI.
    @MainActor static var needsRepairing = Set<String>()
    /// Called when connect services change — refresh the ADB device list
    var onDeviceListChanged: (() -> Void)?
    
    private var pairingBrowser: NWBrowser?
    private var connectBrowser: NWBrowser?
    private var isBrowsing = false
    private static var isBrowsingGlobally = false
    
    private var mdnsPollTimer: Timer?
    
    private let queue = DispatchQueue(label: "com.androidfilesync.adb.mdns")
    
    func startBrowsing() {
        if Self.isBrowsingGlobally {
            return
        }
        // Avoid tearing down and recreating browsers repeatedly from repeated onAppear events.
        if isBrowsing, pairingBrowser != nil || connectBrowser != nil {
            return
        }
        // Cancel any stale browser instances before starting.
        pairingBrowser?.cancel()
        connectBrowser?.cancel()
        pairingBrowser = nil
        connectBrowser = nil
        mdnsPollTimer?.invalidate()
        mdnsPollTimer = nil
        isBrowsing = true
        Self.isBrowsingGlobally = true
        
        print("📶 NWBrowser: Browsing for _adb-tls-pairing._tcp + _adb-tls-connect._tcp...")

        // ── ADB 37 approach ──────────────────────────────────────────────
        // NWBrowser gives us INSTANT event notifications (device appeared/disappeared).
        // `adb mdns services` gives us the actual IP:port resolution.
        // We do NOT create TCP connections (NWConnection) to the device at all,
        // avoiding TCP RSTs, auth prompts, and flickering.

        // 1. Pairing Browser — instant notification when pairing dialog opens/closes
        let pairParams = NWParameters.tcp
        if let ipOpts = pairParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }
        pairParams.includePeerToPeer = true
        pairingBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-pairing._tcp", domain: "local."), using: pairParams)

        pairingBrowser?.browseResultsChangedHandler = { [weak self] _, changes in
            // Any change (added/removed/changed) → rapid-poll adb mdns services
            // ADB's mDNS daemon may lag slightly behind NWBrowser, so poll multiple times
            if !changes.isEmpty {
                DispatchQueue.main.async {
                    self?.pollADBMdnsServices()
                }
                // Retry polls after short delays to catch services ADB hasn't indexed yet
                for delay in [1.0, 2.0] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        self?.pollADBMdnsServices()
                    }
                }
            }
        }

        // 2. Connect Browser — instant notification when wireless debugging toggled
        let connectParams = NWParameters.tcp
        if let ipOpts = connectParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }
        connectParams.includePeerToPeer = true
        connectBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."), using: connectParams)

        connectBrowser?.browseResultsChangedHandler = { [weak self] _, changes in
            for change in changes {
                switch change {
                case .removed(let result):
                    // Device turned off wireless debugging — remove from list instantly
                    if case let .service(name, _, _, _) = result.endpoint, name.hasPrefix("adb-") {
                        let ipToDisconnect = self?.discoveredDevices[name]?.ip
                        DispatchQueue.main.async {
                            // Don't remove devices that need re-pairing — keep them visible
                            // so the user can still see the pairing form
                            let keepForRepairing = ipToDisconnect.map { ADBPairingBrowser.needsRepairing.contains($0) } ?? false
                            if !keepForRepairing {
                                self?.discoveredDevices.removeValue(forKey: name)
                            }
                            self?.evaluateStatus()
                            
                            // Force adb disconnect, but NOT for devices needing re-pair
                            // (those are expected to be in a flaky connect state)
                            if let ip = ipToDisconnect,
                               !ADBPairingBrowser.needsRepairing.contains(ip) {
                                Task {
                                    let adbPath = ADBManager.getADBPath()
                                    if !adbPath.isEmpty {
                                        print("📡 NWBrowser: Device \(name) removed, forcing adb disconnect \(ip)")
                                        _ = await Shell.runAsyncWithTimeout(adbPath, args: ["disconnect", ip], timeoutSeconds: 3.0)
                                    }
                                    self?.onDeviceListChanged?()
                                }
                            }
                        }
                    }
                default:
                    break
                }
            }
            // Any change → instant poll for details + refresh device list
            if !changes.isEmpty {
                DispatchQueue.main.async {
                    self?.pollADBMdnsServices()
                    self?.onDeviceListChanged?()
                }
            }
        }

        pairingBrowser?.start(queue: queue)
        connectBrowser?.start(queue: queue)

        ADBPairingBrowser.suppressAutoConnect = false
        DispatchQueue.main.async {
            // Don't clear discoveredDevices — preserve existing data across restarts
            self.status = .searching
            self.startMdnsPolling()
        }
    }
    
    func stopBrowsing() {
        pairingBrowser?.cancel()
        pairingBrowser = nil
        connectBrowser?.cancel()
        connectBrowser = nil
        mdnsPollTimer?.invalidate()
        mdnsPollTimer = nil
        isBrowsing = false
        Self.isBrowsingGlobally = false
        
        DispatchQueue.main.async {
            if self.status == .searching {
                self.status = .idle
            }
            self.discoveredDevices.removeAll()
        }
    }
    
    private func startMdnsPolling() {
        mdnsPollTimer?.invalidate()
        // Rapid-fire polls in the first few seconds (catches devices that take time
        // to re-advertise after toggling wireless debugging off/on).
        // Schedule: t=0, t=1s, t=2s, t=4s, then every 6s.
        pollADBMdnsServices()  // immediate
        let delays: [TimeInterval] = [1, 2, 4]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.pollADBMdnsServices()
            }
        }
        mdnsPollTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            self?.pollADBMdnsServices()
        }
    }
    
    /// Uses `adb mdns services` to discover devices directly, bypassing macOS mDNS cache.
    /// Finds BOTH:
    ///   - _adb-tls-pairing._tcp  → device with pairing dialog open (needs code)
    ///   - _adb-tls-connect._tcp  → device with wireless debugging on (can direct-connect if already paired)
    /// ADB 37+ output format:
    ///   adb-XXXX  _adb-tls-pairing._tcp  192.168.1.69:41583  adb-XXXX.local
    private func pollADBMdnsServices() {
        Task {
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }

            // Read-only: get already-connected device IPs from adb devices
            let (_, devicesOutput, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: ["devices"], timeoutSeconds: 3.0
            )
            let connectedSerials = devicesOutput.split(separator: "\n").compactMap { line -> String? in
                let s = String(line)
                guard s.contains("\tdevice") || s.contains(" device") else { return nil }
                return s.components(separatedBy: "\t").first?.trimmingCharacters(in: .whitespaces)
                    ?? s.components(separatedBy: " ").first?.trimmingCharacters(in: .whitespaces)
            }

            let (code, output, _) = await ADBManager.mdnsServicesWithRecovery()
            guard code == 0 else {
                print("📶 NWBrowser: adb mdns services failed with code \(code)")
                return
            }
            let mdnsTrimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("📶 NWBrowser: adb mdns services output:\n\(mdnsTrimmed.isEmpty ? "<empty>" : mdnsTrimmed)")

            var discoveredCount = 0
            for line in output.split(separator: "\n") {
                let str = String(line)
                let isPairingService = str.contains("_adb-tls-pairing._tcp")
                let isConnectService = str.contains("_adb-tls-connect._tcp")
                guard isPairingService || isConnectService else { continue }
                discoveredCount += 1

                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)

                let serviceName: String? = parts.first.flatMap { p in
                    p.hasPrefix("adb-") ? p : nil
                }

                guard let ipPortString = parts.first(where: { part in
                    let comps = part.split(separator: ":")
                    return comps.count >= 2 && UInt16(comps.last!) != nil
                }) else { continue }

                let ipPort = ipPortString.split(separator: ":")
                guard let portString = ipPort.last, let port = UInt16(portString) else { continue }
                let ip = ipPort.dropLast().joined(separator: ":")

                let hostname: String? = parts.last.flatMap { p in
                    p.hasSuffix(".local") ? p : nil
                }

                let dictKey = serviceName ?? ip

                // Check if this IP is already connected by matching against adb devices
                let isPaired = isConnectService && connectedSerials.contains(where: { $0.contains(ip) })
                
                // Auto-reconnect to previously known devices that just reappeared on mDNS
                if isConnectService && !isPaired && !ADBPairingBrowser.suppressAutoConnect
                    && !ADBPairingBrowser.needsRepairing.contains(ip) {
                    let savedIPs = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
                    if savedIPs.contains(ip) {
                        let connectAddr = "\(ip):\(port)"
                        Task { @MainActor in
                            if !ADBPairingBrowser.autoConnectingIPs.contains(ip) {
                                ADBPairingBrowser.autoConnectingIPs.insert(ip)
                                print("📶 NWBrowser: Auto-reconnecting to known device \(connectAddr)")
                                let (exitCode, out, err) = await Shell.runAsyncWithTimeout(
                                    adbPath, args: ["connect", connectAddr], timeoutSeconds: 5.0
                                )
                                
                                let combined = (out + err).lowercased()
                                if combined.contains("failed") || combined.contains("cannot connect") || exitCode != 0 {
                                    // Connection failed (likely authorization revoked)
                                    // Remove from saved list to stop auto-reconnect loop and allow re-pairing
                                    var saved = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
                                    if let idx = saved.firstIndex(of: ip) {
                                        saved.remove(at: idx)
                                        UserDefaults.standard.set(saved, forKey: "connectedWirelessDevices")
                                        print("📶 NWBrowser: Auto-reconnect failed, removing \(ip) from known devices.")
                                    }
                                }
                                
                                ADBPairingBrowser.autoConnectingIPs.remove(ip)
                                self.onDeviceListChanged?()
                            }
                        }
                    }
                }

                await MainActor.run {
                    let existing = self.discoveredDevices[dictKey]
                    // Don't mark as paired if this IP needs re-pairing
                    let blocked = ADBPairingBrowser.needsRepairing.contains(ip)
                    let updatedDevice = DiscoveredDevice(
                        ip: ip,
                        serviceName: existing?.serviceName ?? serviceName,
                        hostname: existing?.hostname ?? hostname,
                        pairingPort: isPairingService ? port : existing?.pairingPort,
                        connectPort: isConnectService ? port : existing?.connectPort,
                        verifiedPaired: (isPaired && !blocked) ? true : existing?.verifiedPaired
                    )
                    self.discoveredDevices[dictKey] = updatedDevice
                    self.evaluateStatus()
                }
            }
            print("📶 NWBrowser: parsed \(discoveredCount) discoverable ADB service lines")
        }
    }
    
    private func evaluateStatus() {
        if discoveredDevices.isEmpty {
            if self.status == .deviceFound {
                self.status = .searching
            }
        } else {
            if self.status == .searching {
                self.status = .deviceFound
            }
        }
    }
}

// MARK: - QR Code Generator

struct QRCodeView: View {
    let data: String
    
    var body: some View {
        if let image = generateQRCode() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
        } else {
            Image(systemName: "qrcode")
                .font(.system(size: 100))
                .foregroundColor(.secondary)
        }
    }
    
    private func generateQRCode() -> NSImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        
        guard let data = data.data(using: .utf8) else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        
        guard let ciImage = filter.outputImage else { return nil }
        
        // Scale up for sharp rendering
        let scale = 10.0
        let transformed = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        guard let cgImage = context.createCGImage(transformed, from: transformed.extent) else { return nil }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: transformed.extent.width, height: transformed.extent.height))
    }
}

// MARK: - Main View

struct WirelessConnectView: View {
    @ObservedObject var deviceManager: DeviceManager
    var onConnected: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    // Tab selection
    @State private var selectedTab: PairingTab = .autoDiscovery
    
    // QR Code pairing state
    @StateObject private var pairingBrowser = ADBPairingBrowser()
    @State private var autoPairingCode = ""
    @State private var visiblePairingPort = ""
    @State private var selectedDeviceIP = ""
    @AppStorage("hidePairingSteps") private var hidePairingSteps = false
    @AppStorage("hasSeenWifiSetup") private var hasSeenWifiSetup = false
    @State private var showSetupPopup = false
    
    // Manual pairing fields
    @State private var ipAddress = ""
    @State private var pairingPort = ""
    @State private var pairingCode = ""
    @State private var connectPort = ""
    
    // Shared state
    @State private var isPairing = false
    @State private var statusMessage = ""
    @State private var isError = false
    @State private var isSuccess = false
    @State private var showConnectOnly = false
    /// True when user taps "Re-scan" from the connected banner — shows scan UI below the card
    @State private var showRescanWhileConnected = false
    
    enum PairingTab: String, CaseIterable {
        case autoDiscovery = "Auto-Discovery"
        case manual = "Advanced"
    }
    

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()
            
            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(PairingTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)
            .onChange(of: selectedTab) { _ in
                // Stop browsing when switching tabs
                pairingBrowser.stopBrowsing()
                pairingBrowser.status = .idle
                statusMessage = ""
                isError = false
                isSuccess = false
                visiblePairingPort = ""
                autoPairingCode = ""
            }
            
            // Tab content
            switch selectedTab {
            case .autoDiscovery:
                autoDiscoveryTab
            case .manual:
                manualTab
            }
        }
        .frame(width: 500, height: 620)
        .onAppear {
            // Refresh availableDevices when NWBrowser detects device changes
            let dm = deviceManager
            pairingBrowser.onDeviceListChanged = {
                Task { await dm.detectDevice() }
            }

            if !hasSeenWifiSetup {
                showSetupPopup = true
            }
        }
        .onDisappear {
            pairingBrowser.stopBrowsing()
        }
        .sheet(isPresented: $showSetupPopup, onDismiss: {
            if selectedTab == .autoDiscovery && pairingBrowser.status == .idle {
                startAutoDiscovery()
            }
        }) {
            wifiSetupPopup
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack {
            Image(systemName: "wifi")
                .font(.title2)
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Connect via WiFi")
                    .font(.headline)
                Text("Android 11+ Wireless Debugging")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Auto-Discovery Tab

    private var autoDiscoveryTab: some View {
        let wirelessDeviceAvailable = deviceManager.availableDevices.contains(where: { $0.isWireless })
        // Show the connected banner whenever any device is connected (USB or wireless).
        // The banner itself handles both cases and shows the appropriate switch options.
        let alreadyConnected = deviceManager.isConnected
        let status = pairingBrowser.status
        let isSearching = status == .searching
        let deviceFound = status != .idle && status != .searching && status != .pairing && status != .paired

        return ScrollView {
            VStack(spacing: 0) {

                // ╔══════════════════════════════════════════════════════╗
                // ║  STATE 1 — Already connected                         ║
                // ╚══════════════════════════════════════════════════════╝
                if alreadyConnected {
                    connectedBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    if showRescanWhileConnected {
                        VStack(spacing: 0) {
                            // Collapsible header — tap to hide
                            Button(action: {
                                showRescanWhileConnected = false
                            }) {
                                HStack(spacing: 8) {
                                    if isSearching {
                                        ProgressView().scaleEffect(0.7)
                                    } else {
                                        Image(systemName: "wifi.circle")
                                            .foregroundColor(.blue)
                                    }
                                    Text(isSearching ? "Scanning…" : "Other devices on network")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(isSearching ? .secondary : .primary)
                                    Spacer()
                                    if !isSearching {
                                        Button(action: startAutoDiscovery) {
                                            Image(systemName: "arrow.clockwise")
                                                .font(.subheadline)
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundColor(.blue)
                                    }
                                    Image(systemName: "chevron.up")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, isSearching ? 12 : 8)

                            if deviceFound {
                                discoveredDevicesPanel
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 8)
                            }
                        }
                    }

                    // Toggle button for "Other devices" section
                    if !showRescanWhileConnected {
                        Button(action: { showRescanWhileConnected = true; startAutoDiscovery() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "wifi.circle")
                                    .foregroundColor(.blue)
                                Text("Other devices on network")
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.down")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                    }
                }

                // ╔══════════════════════════════════════════════════════╗
                // ║  STATE 2 — Not connected / scanning                  ║
                // ╚══════════════════════════════════════════════════════╝
                if !alreadyConnected {
                    VStack(spacing: 16) {

                        if status == .idle {
                            // Setup instructions (only shown when idle, not during scan)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "info.circle")
                                        .foregroundColor(.blue)
                                    Text("How to pair your Android device")
                                        .font(.subheadline.weight(.semibold))
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    qrStepRow(number: 1, text: "Open Settings → Developer Options")
                                    qrStepRow(number: 2, text: "Enable Wireless Debugging")
                                    qrStepRow(number: 3, text: "Tap 'Pair device with pairing code'")
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.blue.opacity(0.05))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.blue.opacity(0.15), lineWidth: 1)
                                    )
                            )

                            // Start button
                            Button(action: startAutoDiscovery) {
                                HStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                    Text("Start Auto-Discovery")
                                }
                                .font(.body.weight(.semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    LinearGradient(colors: [.blue, .indigo],
                                                   startPoint: .leading, endPoint: .trailing)
                                )
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)

                        } else if isSearching {
                            // ── Searching state ──
                            VStack(spacing: 14) {
                                ProgressView()
                                    .scaleEffect(1.3)
                                    .padding(.top, 8)
                                Text("Scanning for devices on your network…")
                                    .font(.headline)
                                Text("Make sure Wireless Debugging is turned on\nand 'Pair device with pairing code' is open on your phone.")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .padding()

                        } else if status == .pairing {
                            // ── Pairing in progress ──
                            VStack(spacing: 12) {
                                ProgressView().scaleEffect(1.2)
                                Text("Pairing…").font(.headline)
                            }
                            .frame(maxWidth: .infinity, minHeight: 120)

                        } else if status == .paired {
                            // ── Paired / connected success ──
                            autoDiscoveryStatusView

                        } else if deviceFound {
                            // ── Device(s) found ──
                            pairingStepsHint
                            autoDiscoveryStatusView
                            discoveredDevicesPanel
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)

                    if status != .idle {
                        // Bottom: Cancel + Search Again
                        HStack {
                            Button("Cancel") { dismiss() }
                                .keyboardShortcut(.cancelAction)
                                .foregroundColor(.secondary)
                            Spacer()
                            if deviceFound || status == .searching {
                                Button(action: startAutoDiscovery) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.clockwise")
                                        Text("Search Again")
                                    }
                                    .font(.subheadline)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .onAppear {
            showRescanWhileConnected = false
            // Re-validate connection state (catches stale wireless connections)
            Task { await deviceManager.detectDevice() }
        }
    }

    // MARK: - Discovered Devices Panel

    /// All discovered devices as selectable rows + action panel for the selected one.
    @ViewBuilder
    private var discoveredDevicesPanel: some View {
        // Exclude devices already displayed elsewhere in this dialog:
        // 1. The active WiFi device (shown in the Connected card)
        // 2. Any wireless device already present in availableDevices
        //    (shown in "Other available devices"), so we don't show duplicates.
        let availableWireless = deviceManager.availableDevices.filter { $0.isWireless }
        let excludedIPs: Set<String> = {
            var ips = Set<String>()
            if deviceManager.isConnected {
                // Always exclude the active wireless device IP
                let wip = deviceManager.lastWirelessIP
                if !wip.isEmpty { ips.insert(wip) }
                if let serial = ADBManager.activeDeviceSerial,
                   ADBManager.isWirelessSerial(serial),
                   let ip = serial.components(separatedBy: ":").first, ip.contains(".") {
                    ips.insert(ip)
                }
            }
            // Exclude any discovered IP already represented in available wireless devices
            for dev in availableWireless {
                if let ip = dev.ipAddress, !ip.isEmpty {
                    ips.insert(ip)
                }
            }
            return ips
        }()
        let sortedKeys = pairingBrowser.discoveredDevices.keys
            .filter { key in
                guard let device = pairingBrowser.discoveredDevices[key] else { return false }
                if excludedIPs.contains(device.ip) { return false }
                // For ADB 37+ mDNS serials, availableDevices may not embed IP.
                // Match by stable service name where possible.
                if let svc = device.serviceName, !svc.isEmpty {
                    if availableWireless.contains(where: { $0.serial.hasPrefix(svc + "._adb-tls-connect._tcp") || $0.serial.hasPrefix(svc + "._adb-tls-pairing._tcp") }) {
                        return false
                    }
                }
                return true
            }
            .sorted()
        let activeKey: String = {
            if !selectedDeviceIP.isEmpty && sortedKeys.contains(selectedDeviceIP) {
                return selectedDeviceIP
            }
            return sortedKeys.first ?? ""
        }()

        Group {
            if !sortedKeys.isEmpty {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(sortedKeys.count > 1 ? "\(sortedKeys.count) Devices Found" : "Device Found")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if sortedKeys.count > 1 {
                                Text("Tap to select")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        ForEach(sortedKeys, id: \.self) { key in
                            discoveredDeviceRow(deviceKey: key, isSelected: key == activeKey)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    )

                    discoveredDeviceActionPanel(for: activeKey)
                }
            }
        }
        .onAppear {
            if selectedDeviceIP.isEmpty, let first = pairingBrowser.discoveredDevices.keys.first {
                selectedDeviceIP = first
            }
            if let dev = pairingBrowser.discoveredDevices[selectedDeviceIP],
               let port = dev.pairingPort, visiblePairingPort.isEmpty {
                visiblePairingPort = String(port)
            }
        }
        .onChange(of: pairingBrowser.discoveredDevices) { devices in
            if selectedDeviceIP.isEmpty, let first = devices.keys.first {
                selectedDeviceIP = first
            } else if !selectedDeviceIP.isEmpty, devices[selectedDeviceIP] == nil,
                      let first = devices.keys.first {
                selectedDeviceIP = first
            }
            if let dev = devices[selectedDeviceIP], let port = dev.pairingPort {
                visiblePairingPort = String(port)
            } else if devices[selectedDeviceIP]?.pairingPort == nil {
                visiblePairingPort = ""
            }
        }
    }

    /// A single selectable device row for the discovered list.
    /// `deviceKey` is the dictionary key (service name or IP).
    private func discoveredDeviceRow(deviceKey: String, isSelected: Bool) -> some View {
        let dev = pairingBrowser.discoveredDevices[deviceKey]
        let isAlreadyPaired = dev?.verifiedPaired == true
        let displayIP = dev?.ip ?? deviceKey

        return Button(action: {
            selectedDeviceIP = deviceKey
            visiblePairingPort = ""
            if let port = dev?.pairingPort { visiblePairingPort = String(port) }
        }) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.1))
                        .frame(width: 36, height: 36)
                    Image(systemName: "iphone")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(isSelected ? .blue : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayIP)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundColor(.primary)
                    Group {
                        if isAlreadyPaired {
                            Text("Already paired · tap to connect")
                                .foregroundColor(.green)
                        } else if dev?.connectPort != nil {
                            // Device has wireless debugging on — may be paired or not.
                            // We can't check without calling adb connect (triggers phone notification).
                            // Show neutral prompt — user taps to connect.
                            Text("Tap to connect")
                                .foregroundColor(.blue)
                        } else {
                            Text("Needs pairing")
                                .foregroundColor(.orange)
                        }
                    }
                    .font(.caption)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.4))
                    .font(.system(size: 18))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            // Use a non-zero fill so the entire row is a valid hit target on macOS
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected
                          ? Color.blue.opacity(0.07)
                          : Color.primary.opacity(0.0001))  // invisible but hittable
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.blue.opacity(0.3) : Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))  // hit area = full row
        }
        .buttonStyle(.plain)
    }

    /// Action panel shown below the device list for the currently selected device key.
    /// `activeKey` is the dictionary key (service name or IP).
    @ViewBuilder
    private func discoveredDeviceActionPanel(for activeKey: String) -> some View {
        let deviceObj = pairingBrowser.discoveredDevices[activeKey]
        let deviceIP = deviceObj?.ip ?? activeKey
        let isCurrentlyConnected = deviceManager.isConnected
            && deviceManager.connectionType == .wireless
            && deviceManager.lastWirelessIP == deviceIP
            && !deviceIP.isEmpty
        let isAlreadyPaired = deviceObj?.verifiedPaired == true

        if isCurrentlyConnected {
            // Already connected to this specific device
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("Currently Connected")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.green)
                }
                Button(action: { Task { await deviceManager.disconnectWireless() } }) {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.red.opacity(0.8))
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.06)))

        } else if let cPort = deviceObj?.connectPort,
                  !ADBPairingBrowser.needsRepairing.contains(deviceIP) {
            // Device has wireless debugging on AND is not flagged as needing re-pair.
            // If already paired: connect succeeds immediately.
            // If not paired: connect fails → flag as needsRepairing → shows pairing form.
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: isAlreadyPaired ? "checkmark.shield.fill" : "wifi")
                        .foregroundColor(isAlreadyPaired ? .green : .blue)
                    Text(isAlreadyPaired ? "Already paired" : "Tap to connect")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isAlreadyPaired ? .green : .blue)
                }
                Button(action: {
                    pairingBrowser.status = .pairing
                    Task {
                        let (success, _) = await deviceManager.connectWirelessly(
                            ip: deviceIP,
                            port: String(cPort),
                            hostname: deviceObj?.hostname
                        )
                        await MainActor.run {
                            if success {
                                // Connection succeeded — clear any repairing flag
                                ADBPairingBrowser.needsRepairing.remove(deviceIP)
                                pairingBrowser.status = .paired
                                onConnected?()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                            } else {
                                // Mark as needing re-pairing — this is stable and won't be
                                // overwritten by mDNS polls. The UI will show pairing form.
                                ADBPairingBrowser.needsRepairing.insert(deviceIP)
                                if var dev = pairingBrowser.discoveredDevices[activeKey] {
                                    dev.verifiedPaired = false
                                    pairingBrowser.discoveredDevices[activeKey] = dev
                                }
                                pairingBrowser.status = .failed("Connection refused. Please re-pair the device.")
                            }
                        }
                    }
                }) {
                    Label("Connect Wirelessly", systemImage: "wifi")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.06)))

        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing Port").font(.subheadline.weight(.medium))
                        TextField("e.g. 41583", text: $visiblePairingPort)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("6-Digit Code").font(.subheadline.weight(.medium))
                        TextField("000000", text: $autoPairingCode)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospacedDigit())
                    }
                }
                Button(action: pairWithAutoDiscovery) {
                    Label("Pair & Connect", systemImage: "link")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background((autoPairingCode.count == 6 && !visiblePairingPort.isEmpty) ? Color.blue : Color.gray)
                        .cornerRadius(8)
                }
                .buttonStyle(.plain)
                .disabled(autoPairingCode.count != 6 || visiblePairingPort.isEmpty)
                
                if visiblePairingPort.isEmpty {
                    Text("Enter the pairing port and code shown on your phone's 'Pair device' screen")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
            .onAppear {
                if visiblePairingPort.isEmpty,
                   let port = pairingBrowser.discoveredDevices[activeKey]?.pairingPort {
                    visiblePairingPort = String(port)
                }
            }
            .onChange(of: pairingBrowser.discoveredDevices[activeKey]?.pairingPort) { newPort in
                if let port = newPort {
                    visiblePairingPort = String(port)
                } else {
                    visiblePairingPort = ""
                }
            }
        }
    }

    /// Rich info card. Symmetric for both active-WiFi and active-USB scenarios.
    /// Always shows the full connection details for the active device, plus
    /// a "switch" row for any other available device.
    @ViewBuilder
    private var connectedBanner: some View {
        let isWirelessActive = deviceManager.connectionType == .wireless
        let isUSBActive      = deviceManager.connectionType == .usb
        let wirelessDevices  = deviceManager.availableDevices.filter { $0.isWireless }

        let usbDevices = deviceManager.availableDevices.filter { !$0.isWireless }

        VStack(spacing: 16) {

            // ── Primary connection status card ────────────────────────────────
            if isWirelessActive {
                // WiFi is active → full green WiFi card
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.green.opacity(0.15)).frame(width: 52, height: 52)
                            Image(systemName: "wifi")
                                .font(.system(size: 22, weight: .semibold)).foregroundColor(.green)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Connected").font(.headline)
                                Text("WiFi")
                                    .font(.caption.weight(.semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.green))
                            }
                            Text(deviceManager.deviceName)
                                .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        // Disconnect link — subtle, inside the card
                        Button(action: { Task { await deviceManager.disconnectWireless() } }) {
                            Text("Disconnect")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.red.opacity(0.8))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(16)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color.green.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.green.opacity(0.18), lineWidth: 1))
                )

                // WiFi detail grid
                VStack(spacing: 1) {
                    infoRow(icon: "network", label: "IP Address",
                            value: deviceManager.lastWirelessIP.isEmpty ? "Unknown" : deviceManager.lastWirelessIP,
                            valueFont: .system(.subheadline, design: .monospaced))
                    Divider().padding(.horizontal, 16)
                    infoRow(icon: "memorychip", label: "Device", value: deviceManager.deviceName)
                    if let info = deviceManager.storageStats["/storage/emulated/0"] {
                        Divider().padding(.horizontal, 16)
                        infoRow(icon: "internaldrive", label: "Internal Storage", value: info.usedText)
                    }
                    if let sdPath = deviceManager.sdCardPath, let sdInfo = deviceManager.storageStats[sdPath] {
                        Divider().padding(.horizontal, 16)
                        infoRow(icon: "sdcard", label: "SD Card", value: sdInfo.usedText)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            } else if isUSBActive {
                // USB is active → full blue USB card
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill(Color.blue.opacity(0.15)).frame(width: 52, height: 52)
                            Image(systemName: "cable.connector")
                                .font(.system(size: 22, weight: .semibold)).foregroundColor(.blue)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("Connected").font(.headline)
                                Text("USB")
                                    .font(.caption.weight(.semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.blue))
                            }
                            Text(deviceManager.deviceName)
                                .font(.subheadline).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Circle().fill(Color.blue).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.blue.opacity(0.4), lineWidth: 3).scaleEffect(1.6))
                    }
                    .padding(16)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12).fill(Color.blue.opacity(0.07))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.18), lineWidth: 1))
                )

                // USB detail grid
                VStack(spacing: 1) {
                    infoRow(icon: "memorychip", label: "Device", value: deviceManager.deviceName)
                    if let info = deviceManager.storageStats["/storage/emulated/0"] {
                        Divider().padding(.horizontal, 16)
                        infoRow(icon: "internaldrive", label: "Internal Storage", value: info.usedText)
                    }
                    if let sdPath = deviceManager.sdCardPath, let sdInfo = deviceManager.storageStats[sdPath] {
                        Divider().padding(.horizontal, 16)
                        infoRow(icon: "sdcard", label: "SD Card", value: sdInfo.usedText)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // ── Other available devices (unified — USB + WiFi) ────────────────
            // Show ALL connected devices except the active one, with appropriate icons.
            // Also exclude wireless devices that resolve to the same IP as the
            // active connection (the same device can appear with both an IP:port
            // serial and an mDNS serial like "adb-XXXX._adb-tls-connect._tcp").
            let activeIP: String? = {
                if deviceManager.connectionType == .wireless {
                    let wip = deviceManager.lastWirelessIP
                    if !wip.isEmpty { return wip }
                    if let serial = ADBManager.activeDeviceSerial,
                       serial.contains(":"), serial.contains(".") {
                        return serial.components(separatedBy: ":").first
                    }
                }
                return nil
            }()
            let otherDevices = deviceManager.availableDevices.filter { dev in
                guard dev.serial != ADBManager.activeDeviceSerial else { return false }
                // Exclude wireless devices that are the same as the active wireless device
                if let activeIP = activeIP, dev.isWireless {
                    // IP:port serial — compare IP directly
                    if let devIP = dev.ipAddress, devIP == activeIP { return false }
                    // mDNS serial (no embedded IP) — match by device name
                    if dev.ipAddress == nil && dev.displayName == deviceManager.deviceName {
                        return false
                    }
                }
                return true
            }
            if !otherDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.stack").font(.system(size: 12)).foregroundColor(.secondary)
                        Text("Other available devices").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    ForEach(otherDevices, id: \.serial) { dev in
                        let devIsWireless = dev.isWireless
                        let devColor: Color = devIsWireless ? .green : .blue
                        let devIcon = devIsWireless ? "wifi" : "cable.connector"
                        let secondaryText: String = {
                            if let ip = dev.ipAddress, !ip.isEmpty {
                                return ip
                            }
                            return devIsWireless ? "Wireless Debugging" : "USB Device"
                        }()
                        Button(action: {
                            Task { await deviceManager.switchToDevice(serial: dev.serial); dismiss() }
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(devColor.opacity(0.1)).frame(width: 36, height: 36)
                                    Image(systemName: devIcon)
                                        .font(.system(size: 15, weight: .medium)).foregroundColor(devColor)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.displayName).font(.subheadline.weight(.medium))
                                    Text(secondaryText)
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("Switch").font(.caption.weight(.semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(devColor))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

        }
        .padding(.top, 4)
    }


    /// Reusable detail row for the connection info grid.
    private func infoRow(icon: String, label: String, value: String,
                         valueFont: Font = .subheadline) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 20)

            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Text(value)
                .font(valueFont.weight(.medium))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var autoDiscoveryStatusView: some View {
        switch pairingBrowser.status {
        case .idle, .searching:
            EmptyView()
        case .deviceFound:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Device found! Ready to pair.")
                    .font(.subheadline)
                    .foregroundColor(.green)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
        case .pairing:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Pairing with device...")
                    .font(.subheadline)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.1)))
        case .paired:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("Paired & Connected!")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.green)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.green.opacity(0.1)))
        case .failed(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.orange)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        }
    }
    
    private var wifiSetupPopup: some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi")
                .font(.system(size: 36))
                .foregroundColor(.blue)
                .padding(.top, 8)
            
            Text("Before You Start")
                .font(.title3.weight(.bold))
            
            Text("Make sure you've done these on your Android phone:")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 10) {
                setupStepRow(number: 1, text: "Go to Settings → Developer Options")
                setupStepRow(number: 2, text: "Enable Wireless Debugging")
                setupStepRow(number: 3, text: "Tap 'Pair device with pairing code'")
                setupStepRow(number: 4, text: "Keep the pairing dialog open on your phone")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            
            Text("Both devices must be on the same WiFi network")
                .font(.caption)
                .foregroundColor(.orange)
            
            Button(action: {
                hasSeenWifiSetup = true
                showSetupPopup = false
            }) {
                Text("Got it, let's connect")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .cornerRadius(10)
            }
            .buttonStyle(.plain)
        }
        .padding(24)
        .frame(width: 380)
    }
    
    private func setupStepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.blue))
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }

    @ViewBuilder
    private var pairingStepsHint: some View {
        if hidePairingSteps {
            Button(action: { hidePairingSteps = false }) {
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle")
                    Text("Show setup steps")
                }
                .font(.caption)
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("On your phone:")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    stepRow("Settings → Developer Options")
                    stepRow("Turn on Wireless Debugging")
                    stepRow("Tap 'Pair device with pairing code'")
                }
                Button(action: { hidePairingSteps = true }) {
                    Text("Got it, don't show again")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.blue.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }
    
    private func qrStepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(Color.blue))
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
    
    private func stepRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundColor(.blue.opacity(0.6))
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Auto-Discovery Logic
    
    private func startAutoDiscovery() {
        autoPairingCode = ""
        visiblePairingPort = ""
        selectedDeviceIP = ""
        pairingBrowser.stopBrowsing()
        // Start discovering _adb-tls-pairing._tcp and _adb-tls-connect._tcp
        pairingBrowser.startBrowsing()
    }
    
    private func pairWithAutoDiscovery() {
        guard !selectedDeviceIP.isEmpty, !visiblePairingPort.isEmpty, !autoPairingCode.isEmpty else { return }
        
        guard let device = pairingBrowser.discoveredDevices[selectedDeviceIP] else { return }
        
        pairingBrowser.status = .pairing
        
        Task {
            // Pair using the user-verified port and the 6 digit code
            let (pairSuccess, pairMessage) = await ADBManager.pairDevice(
                ip: device.ip,
                port: visiblePairingPort,
                code: autoPairingCode
            )
            
            guard pairSuccess else {
                await MainActor.run {
                    pairingBrowser.status = .failed(pairMessage)
                }
                return
            }
            
            // Pairing succeeded — clear the "needs repairing" flag
            await MainActor.run {
                ADBPairingBrowser.needsRepairing.remove(device.ip)
            }
            
            // After pairing, _adb-tls-connect may appear after a delay.
            // Poll for the actual connect port instead of immediately jumping to 5555.
            let resolvedConnectPort = await waitForConnectPort(ip: device.ip, hostname: device.hostname)
            var fallbackPorts: [String] = []
            if let resolvedConnectPort {
                fallbackPorts.append(String(resolvedConnectPort))
            }
            if let currentKnown = pairingBrowser.discoveredDevices[selectedDeviceIP]?.connectPort {
                let s = String(currentKnown)
                if !fallbackPorts.contains(s) { fallbackPorts.append(s) }
            }
            if !fallbackPorts.contains("5555") { fallbackPorts.append("5555") }
            
            for tryPort in fallbackPorts {
                let (s, _) = await deviceManager.connectWirelessly(
                    ip: device.ip,
                    port: tryPort,
                    hostname: device.hostname
                )
                if s {
                    await MainActor.run {
                        pairingBrowser.status = .paired
                        onConnected?()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            dismiss()
                        }
                    }
                    return
                }
            }
            
            // Pairing succeeded, but connection failed on all candidate ports.
            // Keep the dialog open and show a clear action path instead of false success.
            await MainActor.run {
                ADBPairingBrowser.needsRepairing.insert(device.ip)
                if var dev = pairingBrowser.discoveredDevices[selectedDeviceIP] {
                    dev.verifiedPaired = false
                    pairingBrowser.discoveredDevices[selectedDeviceIP] = dev
                }
                pairingBrowser.status = .failed("Paired, but connection could not be established. Verify the current connect port in Wireless Debugging and tap Connect.")
            }
        }
    }

    /// Waits briefly for `_adb-tls-connect._tcp` to appear after successful pairing.
    /// Returns discovered connect port for this device, or nil if not seen.
    private func waitForConnectPort(ip: String, hostname: String?) async -> UInt16? {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else { return nil }

        for _ in 1...20 {
            let (code, output, _) = await ADBManager.mdnsServicesWithRecovery(allowRecovery: false)
            if code == 0 {
                for line in output.split(separator: "\n") {
                    let str = String(line)
                    guard str.contains("_adb-tls-connect._tcp") else { continue }
                    let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                    let lineHost = parts.last.flatMap { $0.hasSuffix(".local") ? $0 : nil }
                    guard let ipPortString = parts.first(where: { part in
                        let comps = part.split(separator: ":")
                        return comps.count >= 2 && UInt16(comps.last ?? "") != nil
                    }) else { continue }
                    let comps = ipPortString.split(separator: ":")
                    guard let last = comps.last, let port = UInt16(last) else { continue }
                    let lineIP = comps.dropLast().joined(separator: ":")
                    let hostMatch = (hostname != nil && lineHost == hostname)
                    let ipMatch = lineIP == ip
                    if hostMatch || ipMatch {
                        return port
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 750_000_000)
        }
        return nil
    }
    
    // MARK: - Manual Tab
    
    private var manualTab: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Instructions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Setup Instructions")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.secondary)
                    
                    stepRow(number: 1, text: "Open Settings → Developer Options on your phone")
                    stepRow(number: 2, text: "Enable Wireless Debugging")
                    stepRow(number: 3, text: "Tap Pair device with pairing code")
                    stepRow(number: 4, text: "Enter the IP, port, and pairing code shown below")
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                )
                
                // Input fields
                manualInputFields
                
                // Status message
                if !statusMessage.isEmpty {
                    statusBanner
                }
                
                // Action buttons
                manualActionButtons
            }
            .padding(24)
        }
    }
    
    // MARK: - Manual Input Fields
    
    private var manualInputFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Device IP Address")
                    .font(.subheadline.weight(.medium))
                TextField("e.g. 192.168.1.100", text: $ipAddress)
                    .textFieldStyle(.roundedBorder)
            }
            
            if !showConnectOnly {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing Port")
                            .font(.subheadline.weight(.medium))
                        TextField("e.g. 37215", text: $pairingPort)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Pairing Code")
                            .font(.subheadline.weight(.medium))
                        TextField("e.g. 482604", text: $pairingCode)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Connection Port")
                    .font(.subheadline.weight(.medium))
                HStack {
                    TextField("e.g. 41235", text: $connectPort)
                        .textFieldStyle(.roundedBorder)
                    Text("(shown under Wireless Debugging)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Toggle(isOn: $showConnectOnly) {
                Text("Already paired — just connect")
                    .font(.subheadline)
            }
            .toggleStyle(.checkbox)
        }
    }
    
    // MARK: - Status Banner
    
    private var statusBanner: some View {
        HStack(spacing: 8) {
            if isPairing {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundColor(isError ? .orange : .green)
            }
            
            Text(statusMessage)
                .font(.subheadline)
                .foregroundColor(isError ? .orange : (isSuccess ? .green : .primary))
            
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isError ? Color.orange.opacity(0.1) : (isSuccess ? Color.green.opacity(0.1) : Color.blue.opacity(0.1)))
        )
    }
    
    // MARK: - Manual Action Buttons
    
    private var manualActionButtons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            
            Spacer()
            
            if deviceManager.connectionType == .wireless {
                Button(action: {
                    Task { await deviceManager.disconnectWireless() }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi.slash")
                        Text("Disconnect")
                    }
                }
                .tint(.red)
            }
            
            Button(action: performManualConnection) {
                HStack(spacing: 6) {
                    if isPairing {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else {
                        Image(systemName: "wifi")
                    }
                    Text(showConnectOnly ? "Connect" : "Pair & Connect")
                }
                .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isPairing || !isManualInputValid)
            .keyboardShortcut(.defaultAction)
        }
    }
    
    // MARK: - Helper Methods
    
    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.blue))
            
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var isManualInputValid: Bool {
        if ipAddress.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if connectPort.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if !showConnectOnly {
            if pairingPort.trimmingCharacters(in: .whitespaces).isEmpty { return false }
            if pairingCode.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        }
        return true
    }
    
    private func performManualConnection() {
        let ip = ipAddress.trimmingCharacters(in: .whitespaces)
        let cPort = connectPort.trimmingCharacters(in: .whitespaces)
        
        isPairing = true
        isError = false
        isSuccess = false
        statusMessage = showConnectOnly ? "Connecting..." : "Pairing..."
        
        Task {
            let (success, message): (Bool, String)
            
            if showConnectOnly {
                (success, message) = await deviceManager.connectWirelessly(ip: ip, port: cPort)
            } else {
                let pPort = pairingPort.trimmingCharacters(in: .whitespaces)
                let code = pairingCode.trimmingCharacters(in: .whitespaces)
                (success, message) = await deviceManager.pairAndConnect(
                    ip: ip,
                    pairingPort: pPort,
                    pairingCode: code,
                    connectPort: cPort
                )
            }
            
            await MainActor.run {
                isPairing = false
                statusMessage = message
                isError = !success
                isSuccess = success
                
                if success {
                    onConnected?()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        dismiss()
                    }
                }
            }
        }
    }
}
