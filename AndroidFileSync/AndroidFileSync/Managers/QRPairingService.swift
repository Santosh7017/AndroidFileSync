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
        print("📷 [QRPairing] Service started. State set to .advertising. Starting poll task.")
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.pairWhenPhoneAppears()
        }
        regenerateTimer = Timer.scheduledTimer(withTimeInterval: qrLifetimeSecs, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.state == .advertising else { return }
                print("📷 [QRPairing] QR lifetime expired (60s). Regenerating...")
                self.start()
            }
        }
    }

    func stop() {
        print("📷 [QRPairing] Service stopped by user/caller.")
        stopInternal()
        state = .idle
    }

    func regenerate() {
        print("📷 [QRPairing] Manual regenerate requested.")
        start()
    }

    private func generateCredentials() {
        let hex = "0123456789abcdef"
        let suffix = String((0..<8).map { _ in hex.randomElement()! })
        serviceName = "afs-\(suffix)"
        password = String(format: "%06d", Int.random(in: 0..<1_000_000))
        qrPayload = "WIFI:T:ADB;S:\(serviceName);P:\(password);;"
        print("📷 [QRPairing] Generated credentials: serviceName=\(serviceName), code=\(password), payload=\(qrPayload)")
    }

    private func pairWhenPhoneAppears() async {
        let adbPath = ADBManager.getADBPath()
        guard !adbPath.isEmpty else {
            print("📷 [QRPairing] ERROR: ADB binary path is empty!")
            await MainActor.run { state = .failed("ADB not found.") }
            return
        }

        let code = await MainActor.run { password }
        let sName = await MainActor.run { serviceName }
        print("📷 [QRPairing] Starting mDNS poll loop for phone pairing service (serviceName: \(sName), code: \(code))...")

        // Snapshot pre-existing pairing endpoints to prevent false positives from stale mDNS
        let (_, initialOut, _) = await ADBManager.mdnsServicesWithRecovery(allowRecovery: false)
        var preExisting = Set<String>()
        for line in initialOut.split(separator: "\n") {
            let str = String(line)
            guard str.contains("_adb-tls-pairing._tcp") else { continue }
            let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            if let ipPort = parts.first(where: { p in
                let c = p.split(separator: ":")
                return c.count >= 2 && UInt16(c.last ?? "") != nil
            }) {
                preExisting.insert(ipPort)
            }
        }
        if !preExisting.isEmpty {
            print("📷 [QRPairing] Ignoring \(preExisting.count) pre-existing pairing endpoints: \(preExisting)")
            ignoredEndpoints.formUnion(preExisting)
        }

        for attempt in 1...60 {
            guard !Task.isCancelled else {
                print("📷 [QRPairing] Poll loop cancelled at attempt \(attempt)")
                return
            }
            if attempt > 1 { try? await Task.sleep(nanoseconds: 1_000_000_000) }

            // Check if DeviceManager already connected a device while we
            // were polling. This handles the case where pairing failed
            // (e.g. server restart failed) but DeviceManager reconnected
            // the device on its own via mDNS auto-discovery.
            if let activeSerial = ADBManager.activeDeviceSerial, !activeSerial.isEmpty {
                print("📷 [QRPairing] Device already connected by DeviceManager: \(activeSerial). Transitioning to .connected.")
                await MainActor.run {
                    state = .connected
                    onConnected?()
                }
                return
            }

            let (exitCode, output, stderr) = await ADBManager.mdnsServicesWithRecovery(allowRecovery: false)
            let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)

            if attempt == 1 || attempt % 5 == 0 || trimmedOut.contains("_adb-tls-pairing._tcp") {
                print("📷 [QRPairing] Poll \(attempt)/60: mdns exitCode=\(exitCode), output=\(trimmedOut.isEmpty ? "<empty>" : trimmedOut)")
            }

            guard exitCode == 0 else {
                if attempt % 10 == 0 {
                    print("📷 [QRPairing] adb mdns services returned non-zero code \(exitCode): \(stderr)")
                }
                continue
            }

            for line in output.split(separator: "\n") {
                let str = String(line)
                guard str.contains("_adb-tls-pairing._tcp") else { continue }

                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard let ipPortStr = parts.first(where: { part in
                    let c = part.split(separator: ":")
                    return c.count >= 2 && UInt16(c.last ?? "") != nil
                }) else { continue }

                if ignoredEndpoints.contains(ipPortStr) {
                    continue
                }

                let comps = ipPortStr.split(separator: ":")
                guard let portStr = comps.last, UInt16(portStr) != nil else { continue }
                let ip = comps.dropLast().joined(separator: ":")
                guard !ip.isEmpty else { continue }

                print("📷 [QRPairing] Found new pairing target: \(ipPortStr) (IP: \(ip), Port: \(portStr))")

                await MainActor.run {
                    if state == .advertising {
                        state = .pairing
                        regenerateTimer?.invalidate()
                        regenerateTimer = nil
                        print("📷 [QRPairing] State transitioned to .pairing")
                    }
                }

                print("📷 [QRPairing] Executing command: adb pair \(ipPortStr) \(code)")

                // Protect the TLS handshake from background ADB server restarts.
                // Without these flags, DeviceManager/mDNS recovery can kill the
                // daemon mid-handshake, causing "protocol fault" errors.
                ADBManager.isPairingInProgress = true
                ADBPairingBrowser.isPairingActive = true

                var (pairCode, pairOut, pairErr) = await Shell.runAsyncWithTimeout(
                    adbPath, args: ["pair", ipPortStr, code], timeoutSeconds: 12.0
                )
                var pairCombined = (pairOut + " " + pairErr).trimmingCharacters(in: .whitespacesAndNewlines)
                var pairSuccess = pairCode == 0 && pairCombined.lowercased().contains("successfully paired")
                print("📷 [QRPairing] adb pair exitCode=\(pairCode), success=\(pairSuccess), output='\(pairCombined)'")

                // Protocol fault = local ADB daemon failure; the phone never saw
                // the attempt so the pairing code is still valid.
                // Restart the daemon and retry once (mirrors ADBManager.pairDevice).
                if !pairSuccess && ADBManager.isProtocolError(pairCombined) {
                    print("📷 [QRPairing] Protocol fault detected — restarting ADB server and retrying...")
                    ADBManager.isPairingInProgress = false
                    var restarted = await ADBManager.restartServer()

                    // If the first restart failed (e.g. concurrent mDNS recovery
                    // interfered), wait briefly and try once more.
                    if !restarted {
                        print("📷 [QRPairing] First restart failed — retrying restart after 2s...")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        restarted = await ADBManager.restartServer()
                    }

                    ADBManager.isPairingInProgress = true

                    if restarted {
                        print("📷 [QRPairing] Retrying: adb pair \(ipPortStr) \(code)")
                        (pairCode, pairOut, pairErr) = await Shell.runAsyncWithTimeout(
                            adbPath, args: ["pair", ipPortStr, code], timeoutSeconds: 12.0
                        )
                        pairCombined = (pairOut + " " + pairErr).trimmingCharacters(in: .whitespacesAndNewlines)
                        pairSuccess = pairCode == 0 && pairCombined.lowercased().contains("successfully paired")
                        print("📷 [QRPairing] adb pair retry exitCode=\(pairCode), success=\(pairSuccess), output='\(pairCombined)'")
                    }
                }

                // The ADB daemon may be used again after the pair command, but keep
                // browser auto-connect suppressed until connectAfterPair completes.
                ADBManager.isPairingInProgress = false

                if pairSuccess {
                    await connectAfterPair(ip: ip, adbPath: adbPath)
                    ADBPairingBrowser.isPairingActive = false
                    return
                } else {
                    // Only permanently ignore this endpoint if it was NOT a
                    // protocol fault. Protocol faults are ADB daemon issues —
                    // the phone's pairing code is still valid and may succeed
                    // once the daemon stabilizes on the next poll iteration.
                    if !ADBManager.isProtocolError(pairCombined) {
                        print("📷 [QRPairing] Pairing to \(ipPortStr) failed (\(pairCombined)). Ignoring endpoint.")
                        ignoredEndpoints.insert(ipPortStr)
                    } else {
                        print("📷 [QRPairing] Pairing to \(ipPortStr) failed with protocol fault (\(pairCombined)). Will retry on next poll.")
                    }
                    await MainActor.run {
                        if state == .pairing {
                            state = .advertising
                            print("📷 [QRPairing] Reverted state to .advertising to keep QR code active for scan.")
                        }
                    }
                }
            }
        }

        await MainActor.run {
            if state == .advertising || state == .pairing {
                print("📷 [QRPairing] Poll loop finished (60s) without successful pairing.")
                state = .failed("Phone not detected within 60s. Make sure 'Pair device with QR code' was used and both devices are on the same Wi-Fi.")
            }
        }
    }

    private func connectAfterPair(ip: String, adbPath: String) async {
        print("📷 [QRPairing] Starting connectAfterPair for IP: \(ip)...")
        var connectPort: String?

        for attempt in 1...10 {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            let (code, output, _) = await ADBManager.mdnsServicesWithRecovery(allowRecovery: false)
            let trimmedOut = output.trimmingCharacters(in: .whitespacesAndNewlines)
            print("📷 [QRPairing] connectAfterPair poll \(attempt)/10: mdns output: '\(trimmedOut)'")
            guard code == 0 else { continue }

            for line in output.split(separator: "\n") {
                let str = String(line)
                guard str.contains("_adb-tls-connect._tcp"), str.contains(ip) else { continue }

                let parts = str.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
                guard let ipPortStr = parts.first(where: { part in
                    let c = part.split(separator: ":")
                    return c.count >= 2 && UInt16(c.last ?? "") != nil
                }) else { continue }

                let c = ipPortStr.split(separator: ":")
                if let p = c.last, UInt16(p) != nil {
                    connectPort = String(p)
                    print("📷 [QRPairing] Resolved connect port: \(p) for IP \(ip)")
                }
                break
            }
            if connectPort != nil { break }
        }

        let port = connectPort ?? "5555"
        let serial = "\(ip):\(port)"

        // Try connecting WITHOUT disconnecting first. DeviceManager may have
        // already established a healthy connection in parallel. If "adb connect"
        // says "already connected", we verify and accept it. Only if verification
        // fails (e.g. device offline from a stale TLS session) do we do the
        // heavier disconnect → reconnect cycle.
        print("📷 [QRPairing] Executing command: adb connect \(serial)")
        var (connectCode, connectOut, connectErr) = await Shell.runAsyncWithTimeout(
            adbPath, args: ["connect", serial], timeoutSeconds: 8.0
        )
        var combined = (connectOut + " " + connectErr).lowercased()
        var connectText = (connectOut + " " + connectErr).trimmingCharacters(in: .whitespacesAndNewlines)
        print("📷 [QRPairing] adb connect exitCode=\(connectCode), output='\(connectText)'")

        guard combined.contains("connected") || combined.contains("already") else {
            await MainActor.run {
                print("📷 [QRPairing] adb connect failed for \(serial)")
                state = .failed("Paired but could not connect to \(serial). Try the Auto-Discovery tab.")
            }
            return
        }

        // Verify the connection with retries. On "device offline", do a
        // disconnect → reconnect cycle to clear stale TLS state.
        var verified = false
        for verifyAttempt in 1...3 {
            guard !Task.isCancelled else { return }
            if verifyAttempt > 1 {
                print("📷 [QRPairing] Verification retry \(verifyAttempt)/3 after 2s delay...")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            print("📷 [QRPairing] Verifying connection (attempt \(verifyAttempt)/3): adb -s \(serial) shell echo ok")
            let (vCode, vOut, vErr) = await Shell.runAsyncWithTimeout(
                adbPath, args: ["-s", serial, "shell", "echo", "ok"], timeoutSeconds: 5.0
            )
            let vText = vOut.trimmingCharacters(in: .whitespacesAndNewlines)
            let vErrText = vErr.trimmingCharacters(in: .whitespacesAndNewlines)
            print("📷 [QRPairing] Verify exitCode=\(vCode), stdout='\(vText)', stderr='\(vErrText)'")

            if vCode == 0, vText.contains("ok") {
                verified = true
                break
            }

            // Device offline = stale TLS session. Disconnect and reconnect fresh.
            if vErrText.lowercased().contains("offline") && verifyAttempt < 3 {
                print("📷 [QRPairing] Device offline — disconnect and reconnect before retry...")
                let _ = await Shell.runAsyncWithTimeout(
                    adbPath, args: ["disconnect", serial], timeoutSeconds: 3.0
                )
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let _ = await Shell.runAsyncWithTimeout(
                    adbPath, args: ["connect", serial], timeoutSeconds: 8.0
                )
            }
        }

        guard verified else {
            await MainActor.run {
                print("📷 [QRPairing] Verification failed for \(serial) after retries")
                state = .failed("Paired but connection verification failed for \(serial). Try the Auto-Discovery tab.")
            }
            return
        }

        await MainActor.run {
            print("📷 [QRPairing] Connected & Verified ✅ \(serial)")
            ADBManager.switchToDevice(serial: serial)
            ADBManager.markAppManagedWirelessTarget(serial)
            var saved = UserDefaults.standard.stringArray(forKey: "connectedWirelessDevices") ?? []
            if !saved.contains(ip) { saved.append(ip) }
            UserDefaults.standard.set(saved, forKey: "connectedWirelessDevices")
            state = .connected
            onConnected?()
        }
    }

    private func stopInternal() {
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
