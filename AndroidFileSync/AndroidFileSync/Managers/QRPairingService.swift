import Foundation
internal import Combine

enum QRPairingState: Equatable {
    case idle
    case advertising
    case pairing
    case connected
    case failed(String)
}

@MainActor
final class QRPairingService: ObservableObject {
    @Published var state: QRPairingState = .idle
    @Published var qrPayload: String = ""
    @Published var serviceName: String = ""
    @Published var password: String = ""

    var onConnected: (() -> Void)?

    private var generation = UUID()
    private var pollTask: Task<Void, Never>?
    private var regenerateTimer: Timer?
    private let qrLifetimeSecs: TimeInterval = 60.0

    private var ignoredEndpoints = Set<String>()

    func start() {
        stopInternal()
        ignoredEndpoints.removeAll()
        generateCredentials()
        // Block background mDNS auto-connect attempts for the complete QR flow,
        // including the period before the phone opens its pairing service.
        ADBPairingBrowser.isPairingActive = true
        state = .advertising
        AppLogger.log("📷 [QRPairing] Service started. State set to .advertising. Starting poll task.")
        let id = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pairWhenPhoneAppears(generation: id)
        }
        regenerateTimer = Timer.scheduledTimer(withTimeInterval: qrLifetimeSecs, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == id, self.state == .advertising else { return }
                AppLogger.log("📷 [QRPairing] QR lifetime expired (60s). Regenerating...", level: .warning)
                self.start()
            }
        }
    }

    func stop() {
        AppLogger.log("📷 [QRPairing] Service stopped by user/caller.")
        stopInternal()
        state = .idle
    }

    func regenerate() {
        AppLogger.log("📷 [QRPairing] Manual regenerate requested.")
        start()
    }

    private func generateCredentials() {
        let hex = "0123456789abcdef"
        let suffix = String((0..<8).map { _ in hex.randomElement()! })
        serviceName = "afs-\(suffix)"
        password = String(format: "%06d", Int.random(in: 0..<1_000_000))
        qrPayload = "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
        // Do not write the one-time pairing password or full QR payload to an
        // exportable diagnostics file. The service name is sufficient to trace
        // discovery and correlate the matching Bonjour endpoint.
        AppLogger.log("📷 [QRPairing] Generated credentials for serviceName=\(serviceName) (pairing password redacted)")
    }

    private func pairWhenPhoneAppears(generation id: UUID) async {
        guard !Task.isCancelled, generation == id else { return }
        defer {
            // A cancelled generation must not release a newer QR session's guards.
            if generation == id {
                regenerateTimer?.invalidate()
                regenerateTimer = nil
                ADBManager.isPairingInProgress = false
                ADBPairingBrowser.isPairingActive = false
            }
        }
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            AppLogger.log("📷 [QRPairing] ERROR: ADB binary path is empty!", level: .error)
            state = .failed("ADB not found.")
            return
        }

        let code = password
        let sName = serviceName
        AppLogger.log("📷 [QRPairing] Starting mDNS poll loop for phone pairing service (serviceName: \(sName), pairing password redacted)...")

        // Match the generated service identity, not a newly active transport or
        // an IP/port that may have belonged to a previous pairing advertisement.
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(qrLifetimeSecs)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            guard !Task.isCancelled else {
                AppLogger.log("📷 [QRPairing] Poll loop cancelled at attempt \(attempt)")
                return
            }
            if attempt > 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled, generation == id else { return }

            let (exitCode, output, stderr) = await ADBManager.mdnsServicesWithRecovery(
                allowRecovery: false, requiredPairingService: sName)
            guard !Task.isCancelled, generation == id else { return }
            let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)

            if attempt == 1 || attempt % 5 == 0 || trimmedOut.contains("_adb-tls-pairing._tcp") {
                AppLogger.log("📷 [QRPairing] Poll \(attempt), elapsed=\(Int(Date().timeIntervalSince(startedAt)))s/\(Int(qrLifetimeSecs))s: mdns exitCode=\(exitCode), output=\(trimmedOut.isEmpty ? "<empty>" : trimmedOut)")
            }

            guard exitCode == 0 else {
                if attempt % 10 == 0 {
                    AppLogger.log("📷 [QRPairing] adb mdns services returned non-zero code \(exitCode): \(stderr)", level: .warning)
                }
                continue
            }

            for endpoint in WirelessEndpoint.parse(output) where
                endpoint.serviceType == "_adb-tls-pairing._tcp" && endpoint.serviceName == sName {
                let ipPortStr = endpoint.target
                if ignoredEndpoints.contains(ipPortStr) {
                    continue
                }
                let ip = endpoint.host
                AppLogger.log("📷 [QRPairing] Found matching service=\(sName), pairing target=\(ipPortStr)")

                if state == .advertising {
                    state = .pairing
                    regenerateTimer?.invalidate()
                    regenerateTimer = nil
                    AppLogger.log("📷 [QRPairing] State transitioned to .pairing")
                }

                AppLogger.log("📷 [QRPairing] Executing command: adb pair \(ipPortStr) <redacted>")

                // Protect the TLS handshake from background ADB server restarts.
                // Without these flags, DeviceManager/mDNS recovery can kill the
                // daemon mid-handshake, causing "protocol fault" errors.
                ADBManager.isPairingInProgress = true
                ADBPairingBrowser.isPairingActive = true

                var (pairCode, pairOut, pairErr) = await Shell.runAsyncWithTimeout(
                    adbPath, args: ["pair", ipPortStr, code], timeoutSeconds: 12.0
                )
                guard !Task.isCancelled, generation == id else { return }
                var pairCombined = (pairOut + " " + pairErr).trimmingCharacters(in: .whitespacesAndNewlines)
                var pairSuccess = pairCode == 0 && pairCombined.lowercased().contains("successfully paired")
                AppLogger.log("📷 [QRPairing] adb pair exitCode=\(pairCode), success=\(pairSuccess), output='\(pairCombined)'", level: pairSuccess ? .info : .warning)

                // Protocol fault = local ADB daemon failure; the phone never saw
                // the attempt so the pairing code is still valid.
                // Restart the daemon and retry once (mirrors ADBManager.pairDevice).
                if !pairSuccess && ADBManager.isProtocolError(pairCombined) {
                    AppLogger.log("📷 [QRPairing] Protocol fault detected — restarting ADB server and retrying...", level: .warning)
                    ADBManager.isPairingInProgress = false
                    var restarted = await ADBManager.restartServer()
                    guard !Task.isCancelled, generation == id else { return }

                    // If the first restart failed (e.g. concurrent mDNS recovery
                    // interfered), wait briefly and try once more.
                    if !restarted {
                        AppLogger.log("📷 [QRPairing] First restart failed — retrying restart after 2s...", level: .warning)
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        restarted = await ADBManager.restartServer()
                        guard !Task.isCancelled, generation == id else { return }
                    }

                    ADBManager.isPairingInProgress = true

                    if restarted {
                        AppLogger.log("📷 [QRPairing] Retrying: adb pair \(ipPortStr) <redacted>")
                        (pairCode, pairOut, pairErr) = await Shell.runAsyncWithTimeout(
                            adbPath, args: ["pair", ipPortStr, code], timeoutSeconds: 12.0
                        )
                        guard !Task.isCancelled, generation == id else { return }
                        pairCombined = (pairOut + " " + pairErr).trimmingCharacters(in: .whitespacesAndNewlines)
                        pairSuccess = pairCode == 0 && pairCombined.lowercased().contains("successfully paired")
                        AppLogger.log("📷 [QRPairing] adb pair retry exitCode=\(pairCode), success=\(pairSuccess), output='\(pairCombined)'", level: pairSuccess ? .info : .warning)
                    }
                }

                // The ADB daemon may be used again after the pair command, but keep
                // browser auto-connect suppressed until connectAfterPair completes.
                ADBManager.isPairingInProgress = false

                if pairSuccess {
                    await connectAfterPair(ip: ip)
                    guard !Task.isCancelled, generation == id else { return }
                    ADBPairingBrowser.isPairingActive = false
                    return
                } else {
                    // Only permanently ignore this endpoint if it was NOT a
                    // protocol fault. Protocol faults are ADB daemon issues —
                    // the phone's pairing code is still valid and may succeed
                    // once the daemon stabilizes on the next poll iteration.
                    if !ADBManager.isProtocolError(pairCombined) {
                        AppLogger.log("📷 [QRPairing] Pairing to \(ipPortStr) failed (\(pairCombined)). Ignoring endpoint.", level: .error)
                        ignoredEndpoints.insert(ipPortStr)
                    } else {
                        AppLogger.log("📷 [QRPairing] Pairing to \(ipPortStr) failed with protocol fault (\(pairCombined)). Will retry on next poll.", level: .warning)
                    }
                    if state == .pairing {
                        state = .advertising
                        AppLogger.log("📷 [QRPairing] Reverted state to .advertising to keep QR code active for scan.")
                    }
                }
            }
        }

        if state == .advertising || state == .pairing {
            AppLogger.log("📷 [QRPairing] Poll loop finished (60s) without successful pairing.", level: .error)
            state = .failed("Phone not detected within 60s. Make sure 'Pair device with QR code' was used and both devices are on the same Wi-Fi.")
        }
    }

    private func connectAfterPair(ip: String) async {
        let id = generation
        let endpoint = WirelessDiscovery.shared.endpoints.first { $0.isConnectService && $0.host == ip }
        let result = await ADBManager.connectWireless(ip: ip, port: endpoint.map { String($0.port) } ?? "5555",
            hostname: endpoint?.hostname)
        guard !Task.isCancelled, generation == id else { return }
        guard result.0, let target = result.2 else {
            state = .failed("Paired but could not connect. Keep Wireless debugging open and try Connect.")
            return
        }
        ADBManager.switchToDevice(serial: target)
        ADBManager.markAppManagedWirelessTarget(target)
        state = .connected
        onConnected?()
    }

    private func stopInternal() {
        generation = UUID()
        pollTask?.cancel()
        pollTask = nil
        regenerateTimer?.invalidate()
        regenerateTimer = nil
        // Clear protection flags in case we're stopped mid-handshake,
        // so they don't remain stuck and block future ADB restarts.
        ADBManager.isPairingInProgress = false
        ADBPairingBrowser.isPairingActive = false
    }

    deinit {
        pollTask?.cancel()
        regenerateTimer?.invalidate()
    }
}
