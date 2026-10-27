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
    private let discoveryTimeout: TimeInterval

    init(discoveryTimeout: TimeInterval = 60) {
        self.discoveryTimeout = discoveryTimeout
    }

    func start() {
        stopInternal()
        generateCredentials()
        // Block background mDNS auto-connect attempts for the complete QR flow,
        // including the period before the phone opens its pairing service.
        ADBPairingBrowser.isPairingActive = true
        WirelessDiscovery.shared.watchPairingService(name: serviceName)
        AppLogger.log("📷 [QRPairing] Resolving exact QR service=\(serviceName) through Bonjour.")
        state = .advertising
        AppLogger.log("📷 [QRPairing] Service started. State set to .advertising. Starting poll task.")
        let id = generation
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pairWhenPhoneAppears(generation: id)
        }
        // Keep the displayed credentials until an explicit retry. Rotating them
        // on a separate timer can discard a QR the phone has just scanned while
        // its matching mDNS advertisement is still arriving.
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
                WirelessDiscovery.shared.stopWatchingPairingService(name: serviceName)
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
        let deadline = startedAt.addingTimeInterval(discoveryTimeout)
        var attempt = 0
        var sawWirelessDebugging = false
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
            let endpoints = WirelessEndpoint.parse(output)
            sawWirelessDebugging = sawWirelessDebugging || endpoints.contains { $0.isConnectService }

            if attempt == 1 || attempt % 5 == 0 || trimmedOut.contains("_adb-tls-pairing._tcp") {
                AppLogger.log("📷 [QRPairing] Poll \(attempt), elapsed=\(Int(Date().timeIntervalSince(startedAt)))s/\(Int(discoveryTimeout))s: mdns exitCode=\(exitCode), output=\(trimmedOut.isEmpty ? "<empty>" : trimmedOut)")
            }

            guard exitCode == 0 else {
                if attempt % 10 == 0 {
                    AppLogger.log("📷 [QRPairing] adb mdns services returned non-zero code \(exitCode): \(stderr)", level: .warning)
                }
                continue
            }

            // A live numeric address may arrive while the discovery command
            // returns its older hostname fallback. Recheck before invoking ADB.
            let currentEndpoints = WirelessDiscovery.shared.endpoints + endpoints
            guard let endpoint = currentEndpoints.first(where: {
                $0.serviceType == "_adb-tls-pairing._tcp" && $0.serviceName == sName
            }) else { continue }
            AppLogger.log("📷 [QRPairing] Found matching service=\(sName), pairing target=\(endpoint.target)")
            state = .pairing
            AppLogger.log("📷 [QRPairing] State transitioned to .pairing")

            let (pairCode, pairOut, pairErr) = await ADBManager.performPairing(
                target: endpoint.target, code: code, isCurrent: { self.generation == id })
            guard !Task.isCancelled, generation == id else { return }
            let combined = (pairOut + " " + pairErr).trimmingCharacters(in: .whitespacesAndNewlines)
            if pairCode == 0 && combined.lowercased().contains("successfully paired") {
                await connectAfterPair(endpoint: endpoint)
            } else {
                AppLogger.log("📷 [QRPairing] Pairing handshake failed for \(endpoint.target): \(combined)", level: .error)
                if combined.lowercased().contains("unable to start pairing client") {
                    state = .failed(ADBManager.pairingConnectionFailureMessage(combined, usingQRCode: true))
                } else if combined.lowercased().contains("wrong password or connection was dropped") {
                    state = .failed("Phone detected, but it rejected the pairing code or closed the connection. Re-open 'Pair device with QR code', click Try Again and scan the fresh QR. If it repeats, use pairing code in Advanced.")
                } else if ADBManager.isProtocolError(combined) {
                    state = .failed("Phone detected, but the pairing handshake could not complete. Re-open 'Pair device with QR code' on your phone, then click Try Again and scan the new QR. If it still fails, use pairing code.")
                } else {
                    state = .failed("Phone detected, but pairing failed. Re-open 'Pair device with QR code' on your phone, then click Try Again and scan the new QR." + (combined.isEmpty ? "" : " \(combined)"))
                }
            }
            // A detected phone gets one bounded pairing operation. Do not return
            // to discovery and re-attempt the same service on every poll.
            return
        }

        if state == .advertising || state == .pairing {
            AppLogger.log("📷 [QRPairing] Discovery finished (\(Int(discoveryTimeout))s) without a matching phone.", level: .error)
            state = .failed(sawWirelessDebugging
                ? "Wireless debugging was detected, but the QR pairing service did not respond. Re-open 'Pair device with QR code' and try again. If your phone stays on Pairing, use pairing code in Auto-Discovery."
                : "QR pairing service not detected within \(Int(discoveryTimeout))s. Make sure 'Pair device with QR code' was used and both devices are on the same Wi-Fi.")
        }
    }

    private func connectAfterPair(endpoint pairedEndpoint: WirelessEndpoint) async {
        let id = generation
        let ip = pairedEndpoint.host
        let endpoint = WirelessDiscovery.shared.endpoints.first {
            $0.isConnectService && ($0.host == ip || (pairedEndpoint.hostname != nil && $0.hostname == pairedEndpoint.hostname))
        }
        let result = await ADBManager.connectWireless(ip: ip, port: endpoint.map { String($0.port) } ?? "5555",
            hostname: endpoint?.hostname ?? pairedEndpoint.hostname)
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
        WirelessDiscovery.shared.stopWatchingPairingService(name: serviceName)
        generation = UUID()
        pollTask?.cancel()
        pollTask = nil
        // Clear protection flags in case we're stopped mid-handshake,
        // so they don't remain stuck and block future ADB restarts.
        ADBManager.isPairingInProgress = false
        ADBPairingBrowser.isPairingActive = false
    }

    deinit {
        pollTask?.cancel()
    }
}
