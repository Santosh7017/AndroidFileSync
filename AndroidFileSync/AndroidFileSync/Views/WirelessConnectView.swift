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
    var id: String { ip }
    let ip: String
    var pairingPort: UInt16?
    var connectPort: UInt16?
    var verifiedPaired: Bool?
}

/// Browses the local network for ADB pairing services via mDNS.
/// Uses NWBrowser and NWConnection for real-time resolution (bypasses mDNSResponder cache).
class ADBPairingBrowser: ObservableObject {
    @Published var status: AutoDiscoveryStatus = .idle
    @Published var discoveredDevices: [String: DiscoveredDevice] = [:]
    
    private var pairingBrowser: NWBrowser?
    private var connectBrowser: NWBrowser?
    
    // Map of endpoints to resolve details for accurate removal
    // We store Hashable Representation mapping instead of NWEndpoint directly,
    // as NWEndpoint is an enum and hashes correctly by its host/port values or service.
    private var endpointToIPAndType: [NWEndpoint: (ip: String, isPairing: Bool)] = [:]
    private var activeConnections: [NWEndpoint: NWConnection] = [:]
    private var mdnsPollTimer: Timer?
    
    private let queue = DispatchQueue(label: "com.androidfilesync.adb.mdns")
    
    func startBrowsing() {
        print("📶 NWBrowser: Browsing for _adb-tls-pairing._tcp and _adb-tls-connect._tcp...")

        // 1. Setup Pairing Browser
        let pairParams = NWParameters.tcp
        if let ipOpts = pairParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4 // Force IPv4 everywhere
        }
        pairParams.includePeerToPeer = true // Helps discover devices on direct WiFi links
        pairingBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-pairing._tcp", domain: "local."), using: pairParams)

        pairingBrowser?.browseResultsChangedHandler = { [weak self] results, changes in
            for change in changes {
                switch change {
                case .added(let result), .changed(_, let result, _):
                    self?.resolveEndpoint(result.endpoint, isPairing: true)
                case .removed(let result):
                    self?.handleRemoval(for: result.endpoint)
                default:
                    break
                }
            }
        }

        // 2. Setup Connect Browser
        let connectParams = NWParameters.tcp
        if let ipOpts = connectParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }
        connectParams.includePeerToPeer = true
        connectBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-connect._tcp", domain: "local."), using: connectParams)

        connectBrowser?.browseResultsChangedHandler = { [weak self] results, changes in
            for change in changes {
                switch change {
                case .added(let result), .changed(_, let result, _):
                    self?.resolveEndpoint(result.endpoint, isPairing: false)
                case .removed(let result):
                    self?.handleRemoval(for: result.endpoint)
                default:
                    break
                }
            }
        }

        pairingBrowser?.start(queue: queue)
        connectBrowser?.start(queue: queue)

        // Reset state and start polling AFTER clear — on the main thread so we don’t
        // wipe results that the immediate poll already wrote.
        DispatchQueue.main.async {
            self.discoveredDevices.removeAll()
            self.endpointToIPAndType.removeAll()
            self.status = .searching
            // Fallback: poll ADB’s own mDNS (bypasses macOS mDNS cache)
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
        
        for (_, connection) in activeConnections {
            connection.cancel()
        }
        activeConnections.removeAll()
        
        DispatchQueue.main.async {
            if self.status == .searching {
                self.status = .idle
            }
            self.discoveredDevices.removeAll()
            self.endpointToIPAndType.removeAll()
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
    private func pollADBMdnsServices() {
        Task {
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }
            
            let (code, output, _) = await Shell.runAsyncWithTimeout(
                adbPath, args: ["mdns", "services"], timeoutSeconds: 3.0
            )
            guard code == 0 else { return }
            
            // Parse lines like:
            //   adb-XXXX  _adb-tls-pairing._tcp  192.168.1.69:41583
            //   adb-YYYY  _adb-tls-connect._tcp   192.168.1.69:35921
            for line in output.split(separator: "\n") {
                let str = String(line)
                let isPairingService = str.contains("_adb-tls-pairing._tcp")
                let isConnectService = str.contains("_adb-tls-connect._tcp")
                guard isPairingService || isConnectService else { continue }
                
                // Extract IP:port from the end of the line
                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard let last = parts.last, last.contains(":") else { continue }
                
                let ipPort = last.split(separator: ":")
                guard ipPort.count == 2,
                      let port = UInt16(ipPort[1]) else { continue }
                let ip = String(ipPort[0])
                
                await MainActor.run {
                    var device = self.discoveredDevices[ip] ?? DiscoveredDevice(ip: ip)
                    if isPairingService {
                        if device.pairingPort != port { device.pairingPort = port }
                    } else {
                        // Connect service found — device has wireless debugging on.
                        // Try direct adb connect (works if already paired).
                        if device.connectPort != port { device.connectPort = port }
                    }
                    self.discoveredDevices[ip] = device
                    self.evaluateStatus()
                }

                // For connect-service devices, verify/attempt direct connection
                if isConnectService {
                    let port = port
                    let ip = ip
                    Task.detached(priority: .utility) {
                        let adb = ADBManager.getADBPath()
                        guard !adb.isEmpty else { return }
                        let target = "\(ip):\(port)"
                        let (_, out, err) = await Shell.runAsyncWithTimeout(
                            adb, args: ["connect", target], timeoutSeconds: 4.0
                        )
                        let combined = (out + err).lowercased()
                        let connected = combined.contains("connected to") || combined.contains("already connected")
                        print("📶 mdns connect-service \(target): \(connected ? "✅ connected" : "❌ not paired yet")")
                        if connected {
                            await MainActor.run { [weak self] in
                                if var dev = self?.discoveredDevices[ip] {
                                    dev.verifiedPaired = true
                                    self?.discoveredDevices[ip] = dev
                                    self?.evaluateStatus()
                                }
                            }
                        } else {
                            // Not paired yet — disconnect cleanly
                            _ = await Shell.runAsyncWithTimeout(adb, args: ["disconnect", target], timeoutSeconds: 3.0)
                        }
                    }
                }
            }
        }
    }
    
    private func resolveEndpoint(_ endpoint: NWEndpoint, isPairing: Bool) {
        activeConnections[endpoint]?.cancel()
        
        let connectionParams = NWParameters.tcp
        if let ipOpts = connectionParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ipOpts.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: connectionParams)
        activeConnections[endpoint] = connection
        
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let path = connection.currentPath,
                   case let .hostPort(host, port) = path.remoteEndpoint {
                    
                    let ipString = "\(host)"
                    let cleanIp = ipString.components(separatedBy: "%").first ?? ipString
                    let portNumber = port.rawValue
                    
                    print("📶 NWBrowser: \(isPairing ? "Pairing" : "Connect") -> \(cleanIp):\(portNumber)")
                    
                    DispatchQueue.main.async {
                        self?.endpointToIPAndType[endpoint] = (cleanIp, isPairing)
                        
                        var device = self?.discoveredDevices[cleanIp] ?? DiscoveredDevice(ip: cleanIp)
                        if isPairing {
                            device.pairingPort = portNumber
                        } else {
                            device.connectPort = portNumber
                        }
                        
                        self?.discoveredDevices[cleanIp] = device
                        self?.evaluateStatus()
                        
                        // Verify actual pairing status via adb connect
                        if !isPairing, device.verifiedPaired == nil {
                            self?.verifyPairing(ip: cleanIp, port: portNumber)
                        }
                    }
                    
                    // Critical: Close connection so Android doesn't get flooded
                    connection.cancel()
                    DispatchQueue.main.async {
                        self?.activeConnections.removeValue(forKey: endpoint)
                    }
                }
            case .failed(let error):
                print("📶 NWBrowser: Endpoint resolution failed: \(error)")
                connection.cancel()
                DispatchQueue.main.async {
                    self?.activeConnections.removeValue(forKey: endpoint)
                }
            case .cancelled:
                DispatchQueue.main.async {
                    self?.activeConnections.removeValue(forKey: endpoint)
                }
            default:
                break
            }
        }
        
        connection.start(queue: queue)
    }
    
    private func handleRemoval(for endpoint: NWEndpoint) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            if let info = self.endpointToIPAndType[endpoint] {
                let wasPairing = info.isPairing
                
                if var device = self.discoveredDevices[info.ip] {
                    if info.isPairing {
                        device.pairingPort = nil
                    } else {
                        device.connectPort = nil
                    }
                    
                    if device.pairingPort == nil && device.connectPort == nil {
                        self.discoveredDevices.removeValue(forKey: info.ip)
                    } else {
                        self.discoveredDevices[info.ip] = device
                    }
                }
                self.endpointToIPAndType.removeValue(forKey: endpoint)
                
                // Restart pairing browser to clear mDNS cache for faster rediscovery
                if wasPairing {
                    self.restartPairingBrowser()
                }
            }
            self.evaluateStatus()
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
    
    /// Restarts just the pairing browser to clear mDNS cache.
    /// Called when a pairing service disappears (user closed the dialog on phone).
    private func restartPairingBrowser() {
        pairingBrowser?.cancel()
        
        // Short delay so macOS flushes the old mDNS entry
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self = self else { return }
            
            let pairParams = NWParameters.tcp
            if let ipOpts = pairParams.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ipOpts.version = .v4
            }
            pairParams.includePeerToPeer = true
            self.pairingBrowser = NWBrowser(for: .bonjour(type: "_adb-tls-pairing._tcp", domain: "local."), using: pairParams)
            
            self.pairingBrowser?.browseResultsChangedHandler = { [weak self] results, changes in
                for change in changes {
                    switch change {
                    case .added(let result), .changed(_, let result, _):
                        self?.resolveEndpoint(result.endpoint, isPairing: true)
                    case .removed(let result):
                        self?.handleRemoval(for: result.endpoint)
                    default:
                        break
                    }
                }
            }
            
            self.pairingBrowser?.start(queue: self.queue)
            print("📶 Pairing browser restarted for fresh discovery")
        }
    }
    
    /// Attempts a quick `adb connect` to check if the device is actually paired.
    private func verifyPairing(ip: String, port: UInt16) {
        Task.detached(priority: .userInitiated) {
            let adbPath = ADBManager.getADBPath()
            guard !adbPath.isEmpty else { return }
            
            let target = "\(ip):\(port)"
            print("📶 Verifying pairing for \(target)...")
            
            let (_, output, error) = await Shell.runAsyncWithTimeout(
                adbPath,
                args: ["connect", target],
                timeoutSeconds: 4.0
            )
            
            let combined = (output + error).lowercased()
            let isActuallyPaired = combined.contains("connected to") || combined.contains("already connected")
            
            // Always disconnect — this was just a test, not an actual user-initiated connect
            _ = await Shell.runAsyncWithTimeout(
                adbPath,
                args: ["disconnect", target],
                timeoutSeconds: 3.0
            )
            
            print("📶 Pairing verification for \(target): \(isActuallyPaired ? "✅ PAIRED" : "❌ NOT PAIRED")")
            
            await MainActor.run { [weak self] in
                if var device = self?.discoveredDevices[ip] {
                    device.verifiedPaired = isActuallyPaired
                    self?.discoveredDevices[ip] = device
                }
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
                            HStack(spacing: 8) {
                                if isSearching {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Image(systemName: "wifi.circle")
                                        .foregroundColor(.blue)
                                }
                                Text(isSearching ? "Scanning for other devices…" : "Other devices on network")
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
                            }
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

                    // Action buttons — always below the info cards and any rescan results
                    VStack(spacing: 10) {
                        Button(action: { showRescanWhileConnected = true; startAutoDiscovery() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle")
                                Text("Connect Another Device / Re-scan")
                            }
                            .font(.subheadline.weight(.medium)).foregroundColor(.blue)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 8).fill(Color.blue.opacity(0.08))
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.2)))
                            )
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            if deviceManager.connectionType == .wireless {
                                Button(action: { Task { await deviceManager.disconnectWireless() } }) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "xmark.circle")
                                        Text("Disconnect")
                                    }
                                    .font(.subheadline.weight(.medium)).foregroundColor(.white)
                                    .frame(maxWidth: .infinity).padding(.vertical, 9)
                                    .background(Color.red.opacity(0.75)).cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                            Button("Close") { dismiss() }
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .background(.ultraThinMaterial).cornerRadius(8).buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
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
            // Only auto-start discovery if nothing is connected at all.
            // When a device is connected (USB or wireless), show the banner instead.
            if !deviceManager.isConnected && status == .idle {
                startAutoDiscovery()
            }
        }
    }

    // MARK: - Discovered Devices Panel

    /// All discovered devices as selectable rows + action panel for the selected one.
    @ViewBuilder
    private var discoveredDevicesPanel: some View {
        // IPs already connected wirelessly to ADB (shown in the switch section above)
        let alreadyConnectedIPs = Set(
            deviceManager.availableDevices
                .filter { $0.isWireless }
                .compactMap { $0.ipAddress }
        )
        // Also exclude the active wireless IP if WiFi is the current connection
        let activeWirelessIP = (deviceManager.isConnected && deviceManager.connectionType == .wireless)
            ? deviceManager.lastWirelessIP : ""
        let sortedIPs = pairingBrowser.discoveredDevices.keys
            .filter { !alreadyConnectedIPs.contains($0) && $0 != activeWirelessIP }
            .sorted()
        let activeIP: String = {
            if !selectedDeviceIP.isEmpty && sortedIPs.contains(selectedDeviceIP) {
                return selectedDeviceIP
            }
            return sortedIPs.first ?? ""
        }()

        Group {
            if !sortedIPs.isEmpty {
                VStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(sortedIPs.count > 1 ? "\(sortedIPs.count) Devices Found" : "Device Found")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            if sortedIPs.count > 1 {
                                Text("Tap to select")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        ForEach(sortedIPs, id: \.self) { ip in
                            discoveredDeviceRow(ip: ip, isSelected: ip == activeIP)
                        }
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    )

                    discoveredDeviceActionPanel(for: activeIP)
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
    private func discoveredDeviceRow(ip: String, isSelected: Bool) -> some View {
        let dev = pairingBrowser.discoveredDevices[ip]
        let isAlreadyPaired = dev?.verifiedPaired == true

        return Button(action: {
            selectedDeviceIP = ip
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
                    Text(ip)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .foregroundColor(.primary)
                    Group {
                        if isAlreadyPaired {
                            Text("Already paired · tap to connect")
                                .foregroundColor(.green)
                        } else if dev?.verifiedPaired == nil && dev?.connectPort != nil {
                            Text("Verifying pairing…")
                                .foregroundColor(.secondary)
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

    /// Action panel shown below the device list for the currently selected IP.
    @ViewBuilder
    private func discoveredDeviceActionPanel(for activeIP: String) -> some View {
        let isCurrentlyConnected = deviceManager.isConnected
            && deviceManager.connectionType == .wireless
            && deviceManager.lastWirelessIP == activeIP
            && !activeIP.isEmpty
        let deviceObj = pairingBrowser.discoveredDevices[activeIP]
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

        } else if deviceObj?.verifiedPaired == nil && deviceObj?.connectPort != nil {
            // Still verifying — show a brief spinner
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Verifying pairing…")
                        .font(.subheadline.weight(.medium)).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))

        } else if isAlreadyPaired, let cPort = deviceObj?.connectPort {
            // Paired but not connected — just needs adb connect
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill").foregroundColor(.blue)
                    Text("Device is already paired")
                        .font(.subheadline.weight(.semibold)).foregroundColor(.blue)
                }
                Button(action: {
                    pairingBrowser.status = .pairing
                    Task {
                        let (success, _) = await deviceManager.connectWirelessly(ip: activeIP, port: String(cPort))
                        await MainActor.run {
                            if success {
                                pairingBrowser.status = .paired
                                onConnected?()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { dismiss() }
                            } else {
                                pairingBrowser.status = .failed("Connection failed. Re-pair on your phone.")
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
                   let port = pairingBrowser.discoveredDevices[activeIP]?.pairingPort {
                    visiblePairingPort = String(port)
                }
            }
            .onChange(of: pairingBrowser.discoveredDevices[activeIP]?.pairingPort) { newPort in
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
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.green.opacity(0.4), lineWidth: 3).scaleEffect(1.6))
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

            // ── WiFi devices available while USB is active ────────────────────
            if isUSBActive && !wirelessDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "wifi").font(.system(size: 12)).foregroundColor(.secondary)
                        Text("Also Available via WiFi").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    ForEach(wirelessDevices, id: \.serial) { dev in
                        Button(action: {
                            Task { await deviceManager.switchToDevice(serial: dev.serial); dismiss() }
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.green.opacity(0.1)).frame(width: 36, height: 36)
                                    Image(systemName: "wifi")
                                        .font(.system(size: 15, weight: .medium)).foregroundColor(.green)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.displayName).font(.subheadline.weight(.medium))
                                    Text(dev.ipAddress ?? dev.serial)
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("Switch").font(.caption.weight(.semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.green))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.green.opacity(0.15), lineWidth: 1))
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            // ── USB devices available while WiFi is active ────────────────────
            if isWirelessActive && !usbDevices.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "cable.connector").font(.system(size: 12)).foregroundColor(.secondary)
                        Text("Also Connected via USB").font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16).padding(.top, 12)
                    ForEach(usbDevices, id: \.serial) { dev in
                        Button(action: {
                            Task { await deviceManager.switchToDevice(serial: dev.serial); dismiss() }
                        }) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.blue.opacity(0.1)).frame(width: 36, height: 36)
                                    Image(systemName: "cable.connector")
                                        .font(.system(size: 15, weight: .medium)).foregroundColor(.blue)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(dev.displayName).font(.subheadline.weight(.medium))
                                    Text(dev.serial)
                                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("Switch").font(.caption.weight(.semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Capsule().fill(Color.blue))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(Color.blue.opacity(0.05))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.blue.opacity(0.15), lineWidth: 1))
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
            
            // Give Android a moment to update internal state
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            
            // Try connecting with the discovered Connect Port, falling back to discovered Pairing Port if none
            var targetConnectPort = device.connectPort != nil ? String(device.connectPort!) : "5555"
            var fallbackPorts = [targetConnectPort]
            if targetConnectPort != "5555" { fallbackPorts.append("5555") }
            if let pPort = device.pairingPort {
                fallbackPorts.append(String(pPort))
            }
            
            for tryPort in fallbackPorts {
                let (s, _) = await deviceManager.connectWirelessly(ip: device.ip, port: tryPort)
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
            
            // Connected successfully but couldn't auto-connect the daemon, which is common
            await MainActor.run {
                pairingBrowser.status = .paired
                onConnected?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    dismiss()
                }
            }
        }
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
