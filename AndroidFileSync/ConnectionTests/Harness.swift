import Foundation
internal import Combine

// Only preferences and the discovery UI are substituted. Connection logic and process execution are production sources.
final class ConnectionTestDefaults {
    static let shared = ConnectionTestDefaults()
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func reset() { values.removeAll() }
}

/// A controlled SRV resolver: the name stays constant while its port changes.
/// The production discovery cache and delegates are used without publishing on the LAN.
final class FixtureNetService: NetService {
    let fixturePort: Int
    init(name: String, port: Int, type: String = "_adb-tls-connect._tcp.") {
        fixturePort = port
        super.init(domain: "local.", type: type, name: name, port: Int32(port))
    }
    override var port: Int { fixturePort }
    override var hostName: String? { "phone.local." }
    override var addresses: [Data]? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("192.168.1.42")
        return [withUnsafeBytes(of: &address) { Data($0) }]
    }
    override func resolve(withTimeout timeout: TimeInterval) {
        delegate?.netServiceDidResolveAddress?(self)
    }
    override func stop() {}
}

@main
struct ConnectionTests {
    nonisolated static let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    static var assertions = 0
    static var pairingProbeHosts: [[String]] = []
    static var pairingNetworkResult: PairingNetworkAccess.Result = .allowed
    static var pairingNetworkDelay: TimeInterval = 0
    static var pairingNetworkHosts: [String] = []
    static func checkPairingNetworkAccess(host: String) async -> PairingNetworkAccess.Result {
        pairingNetworkHosts.append(host)
        let result = pairingNetworkResult
        do { try await Task.sleep(nanoseconds: UInt64(pairingNetworkDelay * 1_000_000_000)) }
        catch { return .cancelled }
        return result
    }
    static func readPairingResponse(serverPort: Int, target: String, code: String,
                                    timeout: TimeInterval) async -> (Int32, String, String) {
        await Shell.runAsyncWithTimeout(ADBManager.getADBPath(),
            args: ["-P", String(serverPort), "pair", target, code, "--fixture-response-reader"],
            timeoutSeconds: timeout, environment: Shell.serverEnvironment(port: serverPort))
    }

    static func fixtureReachability(target: String) async -> String { "reachable" }

    static func discoverPairing(serviceName: String, knownHosts: [String]) async -> [WirelessEndpoint] {
        pairingProbeHosts.append(knownHosts)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("state.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lines = state["directPairingServices"] as? [String] else { return [] }
        return WirelessEndpoint.parse(lines.joined(separator: "\n")).filter { $0.serviceName == serviceName }
    }

    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        assertions += 1
    }

    static func fixture(_ values: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: values).write(to: root.appendingPathComponent("state.json"), options: .atomic)
        try Data().write(to: root.appendingPathComponent("commands.jsonl"))
        try Data().write(to: root.appendingPathComponent("dns-commands.jsonl"))
    }

    static func commands() throws -> [[String: Any]] {
        try String(contentsOf: root.appendingPathComponent("commands.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    nonisolated static func isFixtureServerRunning(port: Int) -> Bool {
        let url = root.appendingPathComponent("state.json")
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        flock(descriptor, LOCK_SH)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return (state["runningServers"] as? [String: Bool])?[String(port)] ?? true
    }

    static func testPairing() async throws {
        check(!AppCodeSigning.hasAppleIdentity && AppCodeSigning.diagnosticDescription.contains("signing="),
              "The unsealed test executable reports its actual non-Apple signing identity")
        try fixture([:])
        ADBManager.activeDeviceSerial = nil
        Shell.useDefaultServer = false
        WirelessDiscovery.shared.stop()
        // Start with an empty fallback cache, as in the user's fresh app session.
        _ = await ADBManager.connectAndVerifyWirelessTarget("192.168.1.42:1")
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-qr-race", port: 44695))
        let qrRace = QRPairingService()
        qrRace.start()
        let fallbackHost = "Android_QR_RACE.local:33473"
        try fixture([
            "services": ["adb-PHONE-A-qr-race _adb-tls-connect._tcp 192.168.1.42:44695"],
            "dnsServices": [["name": qrRace.serviceName, "type": "_adb-tls-pairing._tcp",
                             "host": "Android_QR_RACE.local", "port": 33473]],
            "pairErrorsByTarget": [fallbackHost: "error: protocol fault (couldn't read status message): Undefined error: 0"],
            "pairFailureReasonsByTarget": [fallbackHost: "Failed: Unable to start pairing client. No route to host"],
            "pairingCodes": ["192.168.1.42:33473": qrRace.password],
            "live": ["192.168.1.42:44695": "PHONE-A"]
        ])
        // Inject the numeric native resolution only after the slower command-line
        // lookup starts, so its caller has already captured an incomplete snapshot.
        let lookupDeadline = Date().addingTimeInterval(5)
        var lookupStarted = false
        while Date() < lookupDeadline {
            let dnsCommands = (try? String(contentsOf: root.appendingPathComponent("dns-commands.jsonl"), encoding: .utf8)) ?? ""
            lookupStarted = dnsCommands.split(separator: "\n").contains {
                $0.contains("\"-L\"") && $0.contains(qrRace.serviceName)
            }
            if lookupStarted { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(lookupStarted, "The QR race must exercise a pending fallback hostname lookup")
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: qrRace.serviceName, port: 33473,
                                                                  type: "_adb-tls-pairing._tcp."))
        let raceDeadline = Date().addingTimeInterval(5)
        while qrRace.state != .connected, Date() < raceDeadline {
            if case .failed = qrRace.state { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if qrRace.state != .connected {
            let observed = try commands().map { command in
                "\(command["command"] ?? ""):\((command["args"] as? [String])?.dropFirst().first ?? "")"
            }
            Swift.print("QR race state: \(qrRace.state); native: \(WirelessDiscovery.shared.endpoints.map(\.target)); commands: \(observed)")
            fflush(stdout)
        }
        check(qrRace.state == .connected,
              "QR pairing uses the numeric native address arriving during fallback instead of the unroutable hostname")
        let racePairs = try commands().filter { $0["command"] as? String == "pair" }
        check(racePairs.count == 1 && (racePairs.first?["args"] as? [String])?[1] == "192.168.1.42:33473",
              "A late native QR address pairs once on its advertised pairing port")
        qrRace.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        // A QR session must never consume another phone's pairing-code endpoint.
        try fixture(["services": ["adb-OTHER-random\t_adb-tls-pairing._tcp\t192.168.1.55:49000"]])
        let qr = QRPairingService()
        qr.start()
        try await Task.sleep(nanoseconds: 500_000_000)
        check(!(try commands()).contains { $0["command"] as? String == "pair" }, "QR flow ignores unrelated pairing services")
        qr.stop()

        // Reproduce the QR hang: native discovery sees a connect service, while
        // only ADB sees the phone's QR pairing advertisement.
        WirelessDiscovery.shared.stop()
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-qr", port: 49200))
        ADBManager.activeDeviceSerial = nil
        let qrFallback = QRPairingService()
        var qrCallbacks = 0
        qrFallback.onConnected = { qrCallbacks += 1 }
        try fixture(["services": ["adb-OTHER-random\t_adb-tls-pairing._tcp\t192.168.1.42:49100"]])
        qrFallback.start()
        try await Task.sleep(nanoseconds: 400_000_000)
        check((try commands()).contains { $0["command"] as? String == "mdns" },
              "An existing native connect service must not hide QR services from ADB discovery")
        ADBManager.activeDeviceSerial = "UNRELATED-USB"
        try await Task.sleep(nanoseconds: 1_200_000_000)
        check(qrFallback.state == .advertising && qrCallbacks == 0,
              "An unrelated device becoming active must not report successful QR pairing")
        try fixture([
            "services": ["\(qrFallback.serviceName)\t_adb-tls-pairing._tcp.\t192.168.1.42:49100"],
            "pairingCodes": ["192.168.1.42:49100": qrFallback.password],
            "live": ["192.168.1.42:49200": "PHONE-A"]
        ])
        let qrDeadline = Date().addingTimeInterval(4)
        while qrFallback.state != .connected, Date() < qrDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(qrFallback.state == .connected && qrCallbacks == 1,
              "QR discovery pairs the matching service even when it reuses a previously unrelated endpoint")
        let qrCommands = try commands()
        check(qrCommands.filter { $0["command"] as? String == "pair" }.count == 1,
              "QR pairing performs exactly one matching handshake")
        check(qrCommands.contains { $0["command"] as? String == "shell" && $0["serial"] as? String == "192.168.1.42:49200" },
              "QR success verifies the connect port instead of using the pairing port")
        check(!ADBPairingBrowser.isPairingActive && !ADBManager.isPairingInProgress,
              "Successful QR pairing releases background recovery protection")
        qrFallback.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        // ADB can also have only a partial snapshot. An unrelated connect/pairing
        // service must not suppress the command-line Bonjour fallback for this QR.
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-fallback", port: 49400))
        try fixture([
            "services": ["adb-OTHER-random\t_adb-tls-pairing._tcp\t192.168.1.55:49000"],
            "dnsServices": [["name": "afs-dns-fallback", "type": "_adb-tls-pairing._tcp",
                             "host": "192.168.1.42", "port": 49500]]
        ])
        var fallbackEndpoints: [WirelessEndpoint] = []
        let fallbackDeadline = Date().addingTimeInterval(8)
        repeat {
            let result = await ADBManager.mdnsServicesWithRecovery(allowRecovery: false,
                                                                  requiredPairingService: "afs-dns-fallback")
            fallbackEndpoints = WirelessEndpoint.parse(result.1)
            if fallbackEndpoints.contains(where: { $0.serviceName == "afs-dns-fallback" }) { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        } while Date() < fallbackDeadline
        check(fallbackEndpoints.contains { $0.serviceName == "afs-dns-fallback" && $0.target == "192.168.1.42:49500" },
              "Partial native and ADB snapshots still resolve the current QR through DNS-SD fallback")
        WirelessDiscovery.shared.stop()

        // The phone can answer direct mDNS queries while both system discovery
        // sources miss its multicast advertisement (the physical QR regression).
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-direct", port: 49600))
        let qrDirect = QRPairingService()
        qrDirect.start()
        try fixture([
            "directPairingServices": ["\(qrDirect.serviceName)\t_adb-tls-pairing._tcp\t192.168.1.42:49700"],
            "pairingCodes": ["192.168.1.42:49700": qrDirect.password],
            "live": ["192.168.1.42:49600": "PHONE-A"]
        ])
        let directDeadline = Date().addingTimeInterval(4)
        while qrDirect.state != .connected, Date() < directDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(qrDirect.state == .connected,
              "QR pairing completes via direct mDNS replies when Bonjour and ADB miss the pairing advertisement")
        check((try commands()).contains { $0["command"] as? String == "pair" && ($0["args"] as? [String])?[1] == "192.168.1.42:49700" },
              "Direct discovery uses the matching QR pairing port")
        qrDirect.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        // Reproduce the new recording: ADB sees nothing, native discovery sees
        // only the phone's connect service. Query that phone for the exact QR.
        let hiddenQR = QRPairingService()
        hiddenQR.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-unicast", port: 49702))
        pairingProbeHosts.removeAll()
        try fixture([
            "directPairingServices": ["\(hiddenQR.serviceName) _adb-tls-pairing._tcp 192.168.1.42:49701"],
            "pairingCodes": ["192.168.1.42:49701": hiddenQR.password],
            "live": ["192.168.1.42:49702": "PHONE-A"]
        ])
        let hiddenDeadline = Date().addingTimeInterval(4)
        while hiddenQR.state != .connected, Date() < hiddenDeadline {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        check(hiddenQR.state == .connected && pairingProbeHosts.contains { $0.contains("192.168.1.42") },
              "QR discovery queries the native connect host when ADB and pairing browsing are empty")
        hiddenQR.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        let missingQR = QRPairingService(discoveryTimeout: 0.4)
        missingQR.start()
        try fixture(["services": ["adb-PHONE-A-missing _adb-tls-connect._tcp 192.168.1.42:49702"]])
        let missingDeadline = Date().addingTimeInterval(3)
        while Date() < missingDeadline {
            if case .failed = missingQR.state { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if case .failed(let message) = missingQR.state {
            check(message.contains("Wireless debugging was detected") && message.contains("Auto-Discovery"),
                  "A visible connect service with no QR response explains the discovery failure accurately")
        } else { check(false, "A missing QR pairing service must reach its deadline") }
        check(!(try commands()).contains { $0["command"] as? String == "pair" },
              "A connect port is never used for a missing QR pairing handshake")
        missingQR.stop()
        WirelessDiscovery.shared.stop()

        // The user's exact pairing status error occurs even with a responsive
        // daemon. It must not trigger a restart storm or endless handshakes.
        let statusError = "error: protocol fault (couldn't read status message): Undefined error: 0"
        WirelessDiscovery.shared.start()
        let qrStatusFailure = QRPairingService()
        var failureStates: [QRPairingState] = []
        let failureObserver = qrStatusFailure.$state.removeDuplicates().sink { failureStates.append($0) }
        qrStatusFailure.start()
        try fixture(["services": ["\(qrStatusFailure.serviceName) _adb-tls-pairing._tcp 192.168.1.42:40789"],
                     "pairError": statusError])
        let qrFailureDeadline = Date().addingTimeInterval(5)
        while Date() < qrFailureDeadline {
            if case .failed = qrStatusFailure.state { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if case .failed(let message) = qrStatusFailure.state {
            check(message.contains("Phone detected") && message.contains("pairing code") && !message.contains("not detected"),
                  "A detected phone's handshake failure explains how to retry and use pairing code")
        }
        else { check(false, "QR status failures must stop instead of looping until QR expiration") }
        check(failureStates.filter { $0 == .pairing }.count == 1 &&
              failureStates.filter { $0 == .advertising }.count == 1,
              "Pairing retries keep the progress card stable without returning to the QR")
        // A hostname/IP alias for the same service must not start another operation.
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: qrStatusFailure.serviceName, port: 40789,
                                                                  type: "_adb-tls-pairing._tcp."))
        try await Task.sleep(nanoseconds: 400_000_000)
        let qrFailureCommands = try commands()
        check(qrFailureCommands.filter { $0["command"] as? String == "pair" }.count == 2,
              "A QR endpoint receives at most two handshakes")
        check(!qrFailureCommands.contains { $0["command"] as? String == "kill-server" },
              "A pairing protocol status error never restarts a responsive daemon")
        check(qrFailureCommands.contains { $0["command"] as? String == "devices" } &&
              qrFailureCommands.allSatisfy { $0["port"] as? Int == Shell.appADBServerPort },
              "Pairing checks the same daemon independently before considering recovery")
        check(!ADBPairingBrowser.isPairingActive && !ADBManager.isPairingInProgress,
              "Failed QR pairing releases connection recovery protection")
        qrStatusFailure.stop()
        failureObserver.cancel()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil
        try fixture(["pairError": statusError])
        let manualStatusFailure = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        let manualFailureCommands = try commands()
        check(!manualStatusFailure.0 && !manualFailureCommands.contains { $0["command"] as? String == "kill-server" },
              "Manual pairing also preserves a healthy daemon after a remote status error")

        try fixture(["pairError": statusError, "pairFailureReason": "Failed: Unable to start pairing client."])
        let refusedPair = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(!refusedPair.0 && refusedPair.1.contains("Unable to start pairing client"),
              "The second operation exposes the daemon's rejection hidden by the CLI protocol fault")
        let refusedCommands = try commands()
        check(refusedCommands.filter { $0["command"] as? String == "pair" }.count == 2 &&
              !refusedCommands.contains { $0["command"] as? String == "kill-server" },
              "Decoding the actual rejection retains two operations and preserves the healthy daemon")

        try fixture(["pairError": statusError, "pairFailureReason": "Failed: Unable to start pairing client.",
                     "pairSocketError": "Connection refused"])
        let closedPort = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(!closedPort.0 && closedPort.1.contains("pairing port is closed") && closedPort.1.contains("Connection refused"),
              "Manual pairing reports the current socket error instead of suggesting a wrong pairing code")
        check(!(try commands()).contains { $0["command"] as? String == "kill-server" },
              "An unreachable pairing port does not restart the daemon")

        let blockedQR = QRPairingService()
        blockedQR.start()
        try fixture(["services": ["\(blockedQR.serviceName) _adb-tls-pairing._tcp 192.168.1.42:40789"],
                     "pairError": statusError, "pairFailureReason": "Failed: Unable to start pairing client.",
                     "pairSocketError": "Operation not permitted"])
        let blockedDeadline = Date().addingTimeInterval(5)
        while Date() < blockedDeadline {
            if case .failed = blockedQR.state { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if case .failed(let message) = blockedQR.state {
            check(message.contains("Local Network") && message.contains("macOS blocked") && !message.contains("pairing code"),
                  "A blocked QR connection explains macOS Local Network access")
        } else { check(false, "Blocked QR pairing must finish with actionable feedback") }
        blockedQR.stop()
        WirelessDiscovery.shared.stop()

        // Reproduce the new logs: UDP reports denial even with the Settings
        // toggle enabled. UDP must not veto the actual ADB TCP handshake.
        pairingNetworkResult = .denied("state=waiting, path=unsatisfied, reason=localNetworkDenied")
        pairingNetworkHosts.removeAll()
        try fixture(["pairingCodes": ["192.168.1.42:40789": "123456"]])
        let udpDeniedManual = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(udpDeniedManual.0, "Working TCP pairing isn't blocked by a UDP privacy check")
        let udpDeniedManualCommands = try commands()
        check(pairingNetworkHosts.isEmpty && udpDeniedManualCommands.filter { $0["command"] as? String == "pair" }.count == 1,
              "ADB gets the first handshake immediately; successful pairing needs no UDP diagnostic")

        try fixture(["pairError": statusError, "pairResponseSuccess": true])
        let udpDeniedRetry = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(udpDeniedRetry.0 && pairingNetworkHosts == ["192.168.1.42"],
              "Even a diagnosed denied UDP path cannot block the second TCP handshake")
        let udpDeniedRetryCommands = try commands()
        check(udpDeniedRetryCommands.filter { $0["command"] as? String == "pair" }.count == 2 &&
              !udpDeniedRetryCommands.contains { $0["command"] as? String == "kill-server" },
              "UDP denial preserves bounded pairing retries and the healthy daemon")

        let nativeDeniedQR = QRPairingService()
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-udp-denied", port: 40790))
        nativeDeniedQR.start()
        try fixture(["services": ["\(nativeDeniedQR.serviceName) _adb-tls-pairing._tcp 192.168.1.42:40789"],
                     "pairError": statusError, "pairResponseSuccess": true,
                     "live": ["192.168.1.42:40790": "PHONE-A"]])
        let nativeDeniedDeadline = Date().addingTimeInterval(3)
        while Date() < nativeDeniedDeadline {
            if nativeDeniedQR.state == .connected { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(nativeDeniedQR.state == .connected,
              "The real QR flow completes despite the UDP diagnostic reporting denial")
        check(!(try commands()).contains { $0["command"] as? String == "kill-server" } &&
              !ADBManager.isPairingInProgress && !ADBPairingBrowser.isPairingActive,
              "QR success releases guards without restarting the healthy daemon")
        nativeDeniedQR.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        pairingNetworkResult = .allowed
        pairingNetworkDelay = 0.3
        pairingNetworkHosts.removeAll()
        try fixture(["pairError": statusError, "pairResponseSuccess": true])
        let pendingPermission = Task { await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456") }
        let permissionDeadline = Date().addingTimeInterval(1)
        while pairingNetworkHosts.isEmpty, Date() < permissionDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let pendingPermissionCommands = try commands()
        check(ADBManager.isPairingInProgress && pendingPermissionCommands.filter { $0["command"] as? String == "pair" }.count == 1,
              "UDP diagnosis follows a real ADB attempt and protects the retry from concurrent recovery")
        let grantedPermission = await pendingPermission.value
        let grantedPermissionCommands = try commands()
        check(grantedPermission.0 && grantedPermissionCommands.filter { $0["command"] as? String == "pair" }.count == 2,
              "Finishing the UDP diagnostic continues the bounded TCP retry")

        pairingNetworkDelay = 3
        pairingNetworkHosts.removeAll()
        try fixture(["pairError": statusError])
        let cancelledPermission = Task { await ADBManager.performPairing(target: "192.168.1.42:40789", code: "123456") }
        let cancellationDeadline = Date().addingTimeInterval(1)
        while pairingNetworkHosts.isEmpty, Date() < cancellationDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        cancelledPermission.cancel()
        let cancelledAccess = await cancelledPermission.value
        let cancelledPermissionCommands = try commands()
        check(cancelledAccess.0 == -999 && cancelledPermissionCommands.filter { $0["command"] as? String == "pair" }.count == 1 && !ADBManager.isPairingInProgress,
              "Cancelling a pending diagnostic never launches the second handshake")
        pairingNetworkDelay = 0

        pairingNetworkResult = .unavailable("mDNS filtered")
        try fixture(["pairError": statusError, "pairResponseSuccess": true])
        let filteredMDNS = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(filteredMDNS.0, "A filtered UDP permission question doesn't block manual TCP pairing")
        pairingNetworkResult = .allowed

        try fixture(["pairError": statusError, "pairFailureReason": "Failed: Unable to start pairing client.",
                     "pairSocketError": "No route to host"])
        let noRoute = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(!noRoute.0 && noRoute.1.contains("Local Network") && noRoute.1.contains("VPN") &&
              noRoute.1.contains("No route to host"),
              "The reported macOS 27 error explains both privacy denial and real routing failures")
        check(!(try commands()).contains { $0["command"] as? String == "kill-server" },
              "No route to host preserves the healthy daemon")

        try fixture(["pairError": statusError, "pairResponseSuccess": true])
        let successfulResponse = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40789", code: "123456")
        check(successfulResponse.0, "An explicit success from the response reader completes pairing")

        // An independent failed devices query does justify one daemon recovery.
        try await Task.sleep(nanoseconds: 200_000_000)
        try fixture(["pairDaemonFault": true, "pairingCodes": ["192.168.1.42:40790": "123456"]])
        let recoveredPair = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40790", code: "123456")
        let recoveredPairCommands = try commands()
        check(recoveredPair.0 && recoveredPairCommands.filter { $0["command"] as? String == "kill-server" }.count == 1,
              "A confirmed broken pairing daemon receives one recovery and succeeds")

        // The shared Android Studio daemon must survive even a confirmed fault.
        Shell.useDefaultServer = true
        try fixture(["pairDaemonFault": true])
        let sharedFailure = await ADBManager.pairDevice(ip: "192.168.1.42", port: "40790", code: "123456")
        let sharedCommands = try commands()
        check(!sharedFailure.0 && !sharedCommands.contains { $0["command"] as? String == "kill-server" },
              "Pairing never restarts a shared daemon")
        check(sharedCommands.allSatisfy { $0["port"] as? Int == 5037 },
              "Shared pairing and its health query use the same server")
        Shell.useDefaultServer = false

        // Invalid credentials stop promptly rather than ignoring the endpoint
        // until a misleading discovery timeout.
        let rejectedQR = QRPairingService()
        rejectedQR.start()
        WirelessDiscovery.shared.start()
        try fixture(["services": ["\(rejectedQR.serviceName) _adb-tls-pairing._tcp 192.168.1.42:40791"]])
        let rejectionDeadline = Date().addingTimeInterval(3)
        while Date() < rejectionDeadline {
            if case .failed = rejectedQR.state { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        if case .failed(let message) = rejectedQR.state {
            check(message.contains("Phone detected"), "Credential rejection reports pairing failure promptly")
        } else { check(false, "Credential rejection must finish the QR operation") }
        check((try commands()).filter { $0["command"] as? String == "pair" }.count == 1,
              "A rejected password is never retried automatically")
        rejectedQR.stop()
        WirelessDiscovery.shared.stop()

        // Discovery timing must not rotate credentials while the phone's
        // advertisement or its handshake is delayed near the deadline.
        let lateQR = QRPairingService(discoveryTimeout: 0.35)
        lateQR.start()
        let lateName = lateQR.serviceName
        let latePayload = lateQR.qrPayload
        try fixture([:])
        let lateDeadline = Date().addingTimeInterval(3)
        while Date() < lateDeadline {
            if case .failed = lateQR.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if case .failed(let message) = lateQR.state {
            check(message.contains("QR pairing service not detected"), "An absent phone still reports discovery failure")
        } else { check(false, "An absent phone must reach the discovery deadline") }
        check(lateQR.serviceName == lateName && lateQR.qrPayload == latePayload,
              "Discovery expiry never silently replaces a QR already scanned by the phone")
        lateQR.stop()

        let delayedQR = QRPairingService(discoveryTimeout: 0.1)
        delayedQR.start()
        let delayedName = delayedQR.serviceName
        WirelessDiscovery.shared.start()
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: delayedName, port: 40792,
                                                                  type: "_adb-tls-pairing._tcp."))
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-delayed-qr", port: 40793))
        try fixture(["pairDelay": 0.3, "pairingCodes": ["192.168.1.42:40792": delayedQR.password],
                     "live": ["192.168.1.42:40793": "PHONE-A"]])
        let delayedDeadline = Date().addingTimeInterval(3)
        while delayedQR.state != .connected, Date() < delayedDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(delayedQR.state == .connected && delayedQR.serviceName == delayedName,
              "A detected phone's handshake can finish after the discovery deadline with the same QR")
        delayedQR.stop()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil

        // Native-only pairing must still start immediately, and regenerating
        // during its handshake must not let the old task complete the new QR.
        WirelessDiscovery.shared.start()
        qrFallback.start()
        let cancelledServiceName = qrFallback.serviceName
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: cancelledServiceName, port: 49300,
                                                                  type: "_adb-tls-pairing._tcp."))
        try fixture(["pairingCodes": ["192.168.1.42:49300": qrFallback.password], "pairDelay": 3])
        let handshakeDeadline = Date().addingTimeInterval(2)
        while !(try commands()).contains(where: { $0["command"] as? String == "pair" }), Date() < handshakeDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(qrFallback.state == .pairing && ADBManager.isPairingInProgress,
              "A native QR service starts its handshake without waiting for ADB discovery")
        check(!(try commands()).contains { $0["command"] as? String == "mdns" },
              "An exact native pairing match retains the fast discovery path")
        qrFallback.regenerate()
        try await Task.sleep(nanoseconds: 400_000_000)
        check(qrFallback.serviceName != cancelledServiceName && qrFallback.state == .advertising && qrCallbacks == 1,
              "Regenerating cancels the old handshake without reporting success for the new QR")
        check(ADBPairingBrowser.isPairingActive && !ADBManager.isPairingInProgress,
              "A cancelled generation cannot release the replacement QR's discovery protection")
        qrFallback.stop()
        check(!ADBPairingBrowser.isPairingActive && !ADBManager.isPairingInProgress,
              "Closing QR pairing releases both protection flags")
        WirelessDiscovery.shared.stop()
        ADBPairingBrowser.isPairingActive = false
        ADBPairingBrowser.suppressAutoConnect = false

    }

    static func testRecognizedDevices() async throws {
        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        Shell.useDefaultServer = false
        ADBPairingBrowser.suppressAutoConnect = true
        WirelessDiscovery.shared.stop()
        for identity in ["PHONE-A", "PHONE-B"] {
            ADBManager.rememberWirelessDevice(target: "192.168.1.99:40000", hardwareSerial: identity)
        }
        ConnectionTestDefaults.shared.set(["PHONE-A": "Pixel", "PHONE-B": "Galaxy"], forKey: "wirelessDisplayNameBySerial")
        ConnectionTestDefaults.shared.set(["adb-PHONE-A-old": "Pixel", "adb-PHONE-B-old": "Galaxy"], forKey: "wirelessDisplayNameByServiceID")
        let target = "192.168.1.42:41000"
        let services = ["adb-PHONE-A-current _adb-tls-connect._tcp \(target)",
                        "adb-PHONE-B-current _adb-tls-connect._tcp 192.168.1.43:42000"]
        try fixture(["services": services, "live": [target: "PHONE-A"], "delays": [target: 0.5]])
        let manager = DeviceManager()
        manager.userDisconnected = true
        await manager.refreshRecognizedWirelessDevices()
        let manual = Task { await manager.connectRecognizedWirelessDevice(serial: "PHONE-A") }
        let deadline = Date().addingTimeInterval(3)
        while !(try commands()).contains(where: { $0["command"] as? String == "connect" }), Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(manager.connectingWirelessSerials == ["PHONE-A"], "Manual Connect shows progress only for the selected phone")
        await manager.connectRecognizedWirelessDevice(serial: "PHONE-A")
        await manual.value
        check(manager.isConnected && manager.connectingWirelessSerials.isEmpty && manager.recognizedConnectionErrors["PHONE-A"] == nil,
              "Manual Connect verifies the phone and clears its progress")
        let connectCommands = try commands().filter { $0["command"] as? String == "connect" }
        check(connectCommands.count == 1 && connectCommands.first?["args"] as? [String] == ["connect", target],
              "Duplicate Connect clicks share one attempt at the current serial-matched address, ignoring stale addresses and other phones")
        check(!(try commands()).contains { $0["command"] as? String == "pair" }, "Recognized Connect reuses saved pairing")
        manager.removeRecognizedWirelessDevice(serial: "PHONE-A")
        check(!manager.isConnected && manager.connectionType == .none && manager.lastWirelessIP.isEmpty &&
              !manager.availableDevices.contains { $0.serial == target },
              "Remove clears the phone's active app session and connection details")
        check(ADBManager.rememberedWirelessSerials == ["PHONE-B"] && manager.recognizedWirelessDevices.map(\.id) == ["PHONE-B"],
              "Remove updates saved identities and the displayed list, preserving other phones")
        check(ConnectionTestDefaults.shared.dictionary(forKey: "wirelessDisplayNameBySerial")?["PHONE-A"] == nil &&
              ConnectionTestDefaults.shared.dictionary(forKey: "wirelessDisplayNameByServiceID")?["adb-PHONE-A-old"] == nil,
              "Remove clears both saved display-name caches for that identity")
        check(Shell.serverPortBySerial[target] == nil && ADBManager.appManagedWirelessCleanupTargets()[target] == nil,
              "Remove clears ADB routing and app-managed session caches for the phone")
        let rediscovered = DiscoveredDevice(ip: "192.168.1.42", serviceName: "adb-PHONE-A-current", hostname: nil,
                                            connectPort: 41000, verifiedPaired: true)
        check(!rediscovered.isRecognized, "A removed phone is presented as new even if discovery had cached a paired state")
        ADBManager.rememberWirelessDevice(target: target, hardwareSerial: "PHONE-A")
        await manager.refreshRecognizedWirelessDevices()
        check(!ADBManager.rememberedWirelessSerials.contains("PHONE-A") && !manager.recognizedWirelessDevices.contains { $0.id == "PHONE-A" },
              "Late metadata and rediscovery cannot recognize a removed phone again")
        await manager.detectDevice()
        check(!manager.isConnected && !manager.availableDevices.contains { $0.serial == target },
              "Periodic detection cannot restore an existing ADB transport for a removed phone")
        let backgroundConnect = await ADBManager.connectAndVerifyWirelessTarget(target, verificationAttempts: 1)
        check(!backgroundConnect.success && !ADBManager.rememberedWirelessSerials.contains("PHONE-A"),
              "An automatic connection without an expected identity cannot re-add a removed phone")
        let rotatedTarget = "192.168.1.42:41001"
        try fixture(["live": [rotatedTarget: "PHONE-A"]])
        let rotatedConnect = await ADBManager.connectAndVerifyWirelessTarget(rotatedTarget, verificationAttempts: 1)
        check(!rotatedConnect.success && !ADBManager.rememberedWirelessSerials.contains("PHONE-A") &&
              ADBManager.appManagedWirelessCleanupTargets()[rotatedTarget] == nil,
              "Verification rejects a removed identity discovered at an unknown new port during automatic connection")
        await manager.detectDevice()
        check(!manager.isConnected && !manager.availableDevices.contains { $0.serial == rotatedTarget },
              "A retained daemon session cannot restore a removed phone after its port changes")
        try fixture(["live": [target: "PHONE-A"], "devices": ["56037": [target: "device"]]])
        let newSession = DeviceManager()
        newSession.userDisconnected = true
        await newSession.refreshRecognizedWirelessDevices()
        await newSession.detectDevice()
        check(!newSession.isConnected && !newSession.recognizedWirelessDevices.contains { $0.id == "PHONE-A" },
              "A new app session retains removal and does not recognize the cached transport")
        newSession.stopMonitoring()
        manager.stopMonitoring()
        WirelessDiscovery.shared.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        // An explicit new connection can recognize the phone again.
        try fixture(["live": [target: "PHONE-A"]])
        let recognizedAgain = await ADBManager.connectAndVerifyWirelessTarget(target, verificationAttempts: 1, explicitlyRequested: true)
        check(recognizedAgain.success && ADBManager.rememberedWirelessSerials.contains("PHONE-A"),
              "A new explicit connection can recognize a previously removed phone")
        check(rediscovered.isRecognized, "Fresh explicit connection restores recognition for subsequent discovery")

        let usb = DeviceManager()
        ADBManager.activeDeviceSerial = "PHONE-A"
        try fixture(["devices": ["56037": ["PHONE-A": "device"]]])
        await usb.detectDevice()
        usb.removeRecognizedWirelessDevice(serial: "PHONE-A")
        check(usb.isConnected && usb.connectionType == .usb && ADBManager.activeDeviceSerial == "PHONE-A",
              "Removing remembered Wi-Fi information preserves an independently connected USB session")
        usb.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        ADBPairingBrowser.suppressAutoConnect = false
        ADBManager.rememberWirelessDevice(target: target, hardwareSerial: "PHONE-A")
        let otherTarget = "192.168.1.43:42000"
        ADBManager.rememberWirelessDevice(target: otherTarget, hardwareSerial: "PHONE-B")
        try fixture(["services": services, "live": [target: "PHONE-A", otherTarget: "PHONE-B"],
                     "verificationDelays": [target: [1.4]], "delays": [otherTarget: 0.8]])
        let automatic = DeviceManager()
        await automatic.detectDevice()
        let autoDeadline = Date().addingTimeInterval(3)
        while automatic.connectingWirelessSerials.count < 2, Date() < autoDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(automatic.connectingWirelessSerials == ["PHONE-A", "PHONE-B"], "Automatic recovery identifies each phone being connected")
        let verificationDeadline = Date().addingTimeInterval(3)
        while !(try commands()).contains(where: { $0["command"] as? String == "shell" }), Date() < verificationDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        automatic.removeRecognizedWirelessDevice(serial: "PHONE-A")
        check(automatic.connectingWirelessSerials == ["PHONE-B"] && automatic.isWirelessReconnectHuntActive,
              "Remove clears only the removed phone's progress and leaves the other reconnect running")
        try await Task.sleep(nanoseconds: 1_200_000_000)
        check(!ADBManager.rememberedWirelessSerials.contains("PHONE-A") && automatic.recognizedWirelessDevices.map(\.id) == ["PHONE-B"],
              "A cancelled verification cannot re-add a removed phone")
        let automaticCommands = try commands()
        check(automatic.connectingWirelessSerials.isEmpty && !automatic.isWirelessReconnectHuntActive &&
              automaticCommands.contains { $0["command"] as? String == "shell" && $0["serial"] as? String == otherTarget },
              "The remaining phone completes automatic connection and clears progress")
        automatic.stopMonitoring()
        WirelessDiscovery.shared.stop()

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        ADBManager.rememberWirelessDevice(target: target, hardwareSerial: "PHONE-A")
        try fixture(["services": [services[0]], "connectError": "failed to authenticate"])
        let failed = DeviceManager()
        let failedConnect = Task { await failed.connectRecognizedWirelessDevice(serial: "PHONE-A") }
        await failedConnect.value
        check(failed.connectingWirelessSerials.isEmpty && failed.recognizedConnectionErrors["PHONE-A"]?.contains("Pair") == true,
              "A rejected connection clears progress and explains that pairing is needed")
        check(ADBManager.rememberedWirelessSerials.contains("PHONE-A"), "A failed connection retains the remembered phone")
        failed.stopMonitoring()
        WirelessDiscovery.shared.stop()
        ConnectionTestDefaults.shared.reset()

        ADBManager.activeDeviceSerial = nil
        ADBManager.rememberWirelessDevice(target: target, hardwareSerial: "PHONE-A")
        try fixture(["services": [services[0]], "live": [target: "PHONE-A"], "delays": [target: 1.0]])
        let stopped = DeviceManager()
        let stoppedConnect = Task { await stopped.connectRecognizedWirelessDevice(serial: "PHONE-A") }
        try await Task.sleep(nanoseconds: 100_000_000)
        stopped.stopMonitoring()
        await stoppedConnect.value
        check(stopped.connectingWirelessSerials.isEmpty && stopped.recognizedConnectionErrors.isEmpty && !stopped.isWirelessReconnectHuntActive,
              "Stopping monitoring clears manual progress and rejects late results")
        WirelessDiscovery.shared.stop()

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        let reusedTarget = "192.168.1.44:49900"
        ADBManager.rememberWirelessDevice(target: reusedTarget, hardwareSerial: "PHONE-A")
        try fixture(["live": [reusedTarget: "PHONE-B"]])
        let otherPhone = await ADBManager.connectAndVerifyWirelessTarget(reusedTarget,
            expectedHardwareSerial: "PHONE-B", explicitlyRequested: true)
        check(otherPhone.success, "A reused address is verified as a different phone")
        ADBManager.forgetWirelessDevice(hardwareSerial: "PHONE-A")
        check(!ADBManager.isForgottenWirelessTarget(reusedTarget, hardwareSerial: "PHONE-B") &&
              Shell.serverPortBySerial[reusedTarget] != nil && ADBManager.appManagedWirelessCleanupTargets()[reusedTarget] != nil,
              "Removing an old identity preserves the different phone now using its former address")
        ADBPairingBrowser.suppressAutoConnect = false
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--listing") {
            try await testFileListing()
            Swift.print("PASS: \(assertions) file listing regression assertions")
            return
        }
        if CommandLine.arguments.contains("--recognized") {
            try await testRecognizedDevices()
            Swift.print("PASS: \(assertions) recognized-device regression assertions")
            return
        }
        if CommandLine.arguments.contains("--pairing") {
            try await testPairing()
            Swift.print("PASS: \(assertions) pairing regression assertions")
            return
        }
        let old = RememberedWirelessDevice(hardwareSerial: "PHONE-A", target: "192.168.1.8:37001", hostname: "phone.local")
        let endpoints = WirelessEndpoint.parse("""
        List of discovered mdns services
        adb-PHONE-A-random _adb-tls-connect._tcp 192.168.1.42:41000 phone.local
        adb-PHONE-B-random _adb-tls-connect._tcp 192.168.1.8:42000 other.local
        afs-qr _adb-tls-pairing._tcp 192.168.1.42:43000 phone.local
        adb-PHONE-A-random _adb-tls-connect._tcp [fe80::1234%en0]:44000 phone.local.
        """)
        check(endpoints.count == 4, "Parse IPv4, IPv6, pairing, hostname fields")
        let recognized = RecognizedWirelessDevice.devices(from: endpoints,
            rememberedSerials: ["PHONE-A", "PHONE-OFFLINE"],
            namesBySerial: ["PHONE-A": "Pixel 9"], namesByService: ["adb-PHONE-OFFLINE-old": "Galaxy S24"])
        check(recognized.count == 2 && !recognized.contains { $0.id == "PHONE-B" },
              "The home screen lists only recognized phones, including offline identities")
        check(recognized.first { $0.id == "PHONE-A" }?.address == "192.168.1.42",
              "Duplicate IPv4/IPv6 advertisements produce one recognized phone with a current address")
        check(recognized.first { $0.id == "PHONE-OFFLINE" }?.displayName == "Galaxy S24" &&
              recognized.first { $0.id == "PHONE-OFFLINE" }?.isNearby == false,
              "Offline phones retain their cached names without claiming to be available")
        let noLongerNearby = RecognizedWirelessDevice.devices(from: [],
            rememberedSerials: ["PHONE-A", "PHONE-OFFLINE"],
            namesBySerial: ["PHONE-A": "Pixel 9"], namesByService: ["adb-PHONE-OFFLINE-old": "Galaxy S24"])
        check(noLongerNearby.map(\.id) == recognized.map(\.id) && noLongerNearby.allSatisfy { !$0.isNearby },
              "Losing discovery changes availability without removing or reordering recognized phones")
        check(RecognizedWirelessDevice.devices(from: endpoints, rememberedSerials: [],
              namesBySerial: [:], namesByService: [:]).isEmpty,
              "First-time users do not see unknown nearby phones in recognized history")
        check(endpoints.last?.target == "[fe80::1234%en0]:44000", "Preserve scoped IPv6")
        check(WirelessEndpoint.address(from: "phone.local:41000")?.host == "phone.local", "Hostname target parsing")
        check(WirelessEndpoint.address(from: "phone.local:0") == nil, "Reject zero port")
        check(!ADBManager.shouldRejectWirelessEndpoint("No route to host") &&
              !ADBManager.shouldRejectWirelessEndpoint("Host is down"),
              "Routing errors do not prove that the phone's advertised port is obsolete")
        check(ADBManager.shouldRejectWirelessEndpoint("Connection refused"),
              "A closed connection port still triggers targeted cache reconfirmation")
        let candidates = WirelessReconnectPolicy.candidates(endpoints: endpoints, rememberedSerials: ["PHONE-A"])
        check(candidates.first?.target == "192.168.1.42:41000", "Resolve a remembered serial to its current IP and port")
        check(!candidates.contains { $0.target == "192.168.1.8:42000" }, "Reject a different serial reusing the old IP")
        check(!candidates.contains { $0.target.contains("43000") }, "Pairing ports are not connect ports")
        let changedPort = WirelessEndpoint(serviceName: "adb-PHONE-A-random", serviceType: "_adb-tls-connect._tcp",
            host: "192.168.1.8", port: 47000)
        check(WirelessReconnectPolicy.candidates(endpoints: [changedPort], rememberedSerials: ["PHONE-A"]).first?.target == "192.168.1.8:47000", "Port-only rotation")
        let changedIP = WirelessEndpoint(serviceName: "adb-PHONE-A-random", serviceType: "_adb-tls-connect._tcp",
            host: "192.168.1.42", port: 37001)
        check(WirelessReconnectPolicy.candidates(endpoints: [changedIP], rememberedSerials: ["PHONE-A"]).first?.target == "192.168.1.42:37001", "IP-only rotation")
        check(WirelessReconnectPolicy.candidates(endpoints: [], rememberedSerials: ["PHONE-A"]).isEmpty,
              "Without current discovery there are no saved-address connection candidates")
        check(WirelessReconnectPolicy.candidates(endpoints: [changedIP], rememberedSerials: []).isEmpty,
              "An IP-only legacy history never authorizes an automatic connection")

        ConnectionTestDefaults.shared.set(try JSONEncoder().encode([old]), forKey: "wirelessDeviceIdentities")
        ConnectionTestDefaults.shared.set(["PHONE-B", old.target, "adb-PHONE-C-random._adb-tls-connect._tcp"], forKey: "connectedWirelessSerials")
        ConnectionTestDefaults.shared.set(["192.168.1.212", "192.168.1.214"], forKey: "connectedWirelessDevices")
        ConnectionTestDefaults.shared.set(["192.168.1.212": "192.168.1.212:38349"], forKey: "wirelessLastKnownTargetByIP")
        check(Set(ADBManager.rememberedWirelessSerials) == ["PHONE-A", "PHONE-B", "PHONE-C"],
              "Migrate only hardware identities from old records and mDNS serials")
        check(ConnectionTestDefaults.shared.object(forKey: "wirelessLastKnownTargetByIP") == nil &&
              ConnectionTestDefaults.shared.object(forKey: "connectedWirelessDevices") == nil &&
              ConnectionTestDefaults.shared.object(forKey: "wirelessDeviceIdentities") == nil,
              "Migration removes obsolete IP and port histories")
        ConnectionTestDefaults.shared.reset()

        var currentServicePort = 43420
        let discovery = WirelessDiscovery(resolutionInterval: 0, makeService: {
            FixtureNetService(name: $0.name, port: currentServicePort)
        })
        let oldService = FixtureNetService(name: "adb-PHONE-A-unchanged", port: currentServicePort)
        discovery.resolveService(oldService)
        check(discovery.endpoints.first?.port == 43420, "Resolve the initial native service port")
        currentServicePort = 44080
        check(discovery.endpoints.first?.port == 44080,
              "Re-resolve a rotated SRV port even when Android keeps the same service name")
        let obsoleteSnapshot = WirelessEndpoint(serviceName: "adb-PHONE-A-unchanged", serviceType: "_adb-tls-connect._tcp",
            host: "192.168.1.42", port: 43420)
        check(!discovery.acceptsSnapshot(obsoleteSnapshot),
              "An older ADB snapshot cannot overwrite a newer native SRV port")
        discovery.netServiceDidResolveAddress(oldService)
        check(discovery.endpoints.first?.port == 44080, "Ignore late callbacks from the old native resolver")
        discovery.invalidate(target: "192.168.1.42:44080")
        currentServicePort = 45000
        check(discovery.endpoints.first?.port == 45000, "An unreachable cached port is replaced without removing pairing")
        discovery.stop()
        check(discovery.endpoints.isEmpty, "Stopping discovery clears all resolved port records")

        let browser = ADBPairingBrowser()
        let serviceKey = "adb-PHONE-A-unchanged"
        browser.discoveredDevices[serviceKey] = DiscoveredDevice(ip: "192.168.1.42", serviceName: serviceKey,
            hostname: "phone.local", connectPort: 44080, verifiedPaired: true)
        browser.recordConnectionResult(success: false, message: "Connection refused", deviceKey: serviceKey, ip: "192.168.1.42")
        check(!ADBPairingBrowser.needsRepairing.contains("192.168.1.42") && browser.discoveredDevices[serviceKey]?.verifiedPaired == true,
              "The actual discovery view preserves pairing after connection refused")
        browser.recordConnectionResult(success: false, message: "Command timed out", deviceKey: serviceKey, ip: "192.168.1.42")
        check(!ADBPairingBrowser.needsRepairing.contains("192.168.1.42"), "Timeouts must not force the pairing form")
        browser.recordConnectionResult(success: false, message: "failed to authenticate", deviceKey: serviceKey, ip: "192.168.1.42")
        check(ADBPairingBrowser.needsRepairing.contains("192.168.1.42") && browser.discoveredDevices[serviceKey]?.verifiedPaired == false,
              "An explicit authentication rejection still requests pairing")
        browser.recordConnectionResult(success: true, message: "Connected", deviceKey: serviceKey, ip: "192.168.1.42")
        check(!ADBPairingBrowser.needsRepairing.contains("192.168.1.42") && browser.discoveredDevices[serviceKey]?.verifiedPaired == true,
              "A verified connection clears a previous pairing warning")

        browser.startBrowsing()
        check(browser.status == .searching, "Entering Auto-Discovery immediately publishes a searching state")
        browser.stopBrowsing()
        await Task.yield()
        check(browser.status == .idle && browser.discoveredDevices.isEmpty,
              "Leaving Auto-Discovery cannot be undone by a deferred search-start callback")

        ConnectionTestDefaults.shared.reset()
        ADBManager.rememberWirelessDevice(target: old.target, hardwareSerial: "PHONE-A")
        try fixture([:])
        let cancelledSearch = DeviceManager()
        await cancelledSearch.detectDevice()
        check(cancelledSearch.isDetecting && cancelledSearch.isWirelessReconnectHuntActive,
              "Opening the app with Wireless debugging off begins a search")
        cancelledSearch.cancelWirelessReconnectHunt() // QR Code / Nearby devices take over discovery.
        check(!cancelledSearch.isDetecting && !cancelledSearch.isWirelessReconnectHuntActive,
              "Opening connection settings clears dashboard scanning when it cancels the hunt")
        await cancelledSearch.detectDevice()
        check(!cancelledSearch.isDetecting && !cancelledSearch.isWirelessReconnectHuntActive,
              "Closing connection settings does not restart an empty foreground search")
        cancelledSearch.stopMonitoring()
        WirelessDiscovery.shared.stop()
        ConnectionTestDefaults.shared.reset()

        ADBManager.rememberWirelessDevice(target: old.target, hardwareSerial: "PHONE-A")
        try fixture([:])
        let timedSearch = DeviceManager(connectionScanTimeout: 0.4)
        timedSearch.startMonitoring()
        await timedSearch.detectDevice()
        let timeoutWait = Date()
        while !timedSearch.connectionScanTimedOut, Date().timeIntervalSince(timeoutWait) < 2 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(timedSearch.connectionScanTimedOut && !timedSearch.isDetecting &&
              !timedSearch.isWirelessReconnectHuntActive && !timedSearch.isDetectionInProgress,
              "The foreground deadline releases scan and refresh controls when debugging stays off")
        check(timedSearch.connectionScanStartedAt == nil && !ADBManager.rememberedWirelessSerials.isEmpty,
              "A timed-out scan stops elapsed progress without forgetting pairing")
        try await Task.sleep(nanoseconds: 100_000_000)
        try fixture(["live": ["192.168.1.42:48000": "PHONE-A"],
                     "services": ["adb-PHONE-A-enabled _adb-tls-connect._tcp 192.168.1.42:48000"]])
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-enabled", port: 48000))
        check(!timedSearch.isDetecting, "A late wireless advertisement does not reopen foreground scanning")
        let enabledAt = Date()
        while !timedSearch.isConnected, Date().timeIntervalSince(enabledAt) < 3 {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        check(timedSearch.isConnected && !timedSearch.connectionScanTimedOut,
              "Turning Wireless debugging on after timeout still connects a recognized phone")
        timedSearch.stopMonitoring()
        WirelessDiscovery.shared.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil

        try fixture(["deviceDelays": ["56037": 0.8], "devices": ["56037": ["STALE-USB": "device"]]])
        let delayedScan = DeviceManager(connectionScanTimeout: 0.3)
        let delayedScanTask = Task { await delayedScan.detectDevice() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let originalStart = delayedScan.connectionScanStartedAt
        await delayedScan.detectDevice(showProgress: true)
        check(delayedScan.connectionScanStartedAt == originalStart,
              "An overlapping scan request cannot extend the foreground deadline")
        try await Task.sleep(nanoseconds: 350_000_000)
        check(delayedScan.connectionScanTimedOut && !delayedScan.isDetectionInProgress && !delayedScan.isDetecting,
              "A slow device query and its queued refresh are cancelled at the same deadline")
        await delayedScanTask.value
        check(!delayedScan.isConnected && delayedScan.lastDetectionDate == nil,
              "A cancelled device query cannot publish a late device or a completed check")
        try fixture([:])
        await delayedScan.retryDeviceDetection()
        check(!delayedScan.connectionScanTimedOut && !delayedScan.isDetecting && delayedScan.lastDetectionDate != nil,
              "Scan again starts a fresh check and clears the previous timeout")
        delayedScan.stopMonitoring()
        WirelessDiscovery.shared.stop()
        ConnectionTestDefaults.shared.reset()

        for identity in ["PHONE-A", "PHONE-B", "PHONE-C"] {
            ADBManager.rememberWirelessDevice(target: "192.168.1.99:40000", hardwareSerial: identity)
        }
        try fixture(["services": [
            "adb-PHONE-A-current _adb-tls-connect._tcp 192.168.1.41:41000",
            "adb-PHONE-B-current _adb-tls-connect._tcp 192.168.1.42:42000",
            "adb-PHONE-C-current _adb-tls-connect._tcp 192.168.1.43:43000"
        ]])
        let availability = DeviceManager()
        availability.userDisconnected = true
        async let firstRefresh: Void = availability.refreshRecognizedWirelessDevices()
        async let duplicateRefresh: Void = availability.refreshRecognizedWirelessDevices()
        _ = await (firstRefresh, duplicateRefresh)
        check(availability.recognizedWirelessDevices.count == 3 && availability.recognizedWirelessDevices.allSatisfy(\.isNearby),
              "Recognized-device refresh checks every saved phone, including rows beyond the first two")
        check(availability.lastRecognizedRefreshDate != nil && !availability.isRefreshingRecognizedDevices,
              "Refreshing recognized phones completes with a timestamp and clears progress")
        check(availability.userDisconnected && !availability.isConnected && availability.connectionType == .none,
              "Checking availability preserves manual disconnect and does not change transports")
        let availabilityCommands = try commands()
        check(availabilityCommands.filter { $0["command"] as? String == "mdns" }.count == 1,
              "Repeated refresh clicks share one in-flight availability check")
        check(!availabilityCommands.contains { ["connect", "pair", "devices", "kill-server"].contains($0["command"] as? String ?? "") },
              "Recognized refresh performs discovery without retrying USB, pairing, or connecting")

        WirelessDiscovery.shared.stop()
        try fixture([:])
        await availability.refreshRecognizedWirelessDevices()
        check(availability.recognizedWirelessDevices.count == 3 && availability.recognizedWirelessDevices.allSatisfy { !$0.isNearby },
              "A fresh refresh replaces old available results while retaining offline recognized phones")
        let completedRefreshDate = availability.lastRecognizedRefreshDate
        let cancelledRefresh = Task { await availability.refreshRecognizedWirelessDevices() }
        try await Task.sleep(nanoseconds: 30_000_000)
        availability.stopMonitoring()
        await cancelledRefresh.value
        check(!availability.isRefreshingRecognizedDevices && availability.recognizedWirelessDevices.isEmpty &&
              availability.lastRecognizedRefreshDate == completedRefreshDate,
              "Stopping monitoring cancels availability refresh and rejects its late results")
        WirelessDiscovery.shared.stop()
        ConnectionTestDefaults.shared.reset()

        try fixture(["runningServers": ["56037": false], "startupDelay": 0.5,
                     "live": ["192.168.1.42:41000": "PHONE-A"], "services": []])
        let cancelledStartup = Task {
            await Shell.runAsyncWithTimeout(ADBManager.getADBPath(), args: ["mdns", "services"], timeoutSeconds: 0.1)
        }
        async let coldDevices = ADBManager.listAllConnectedDevices()
        async let coldMDNS = Shell.runAsyncWithTimeout(ADBManager.getADBPath(), args: ["mdns", "services"], timeoutSeconds: 0.1)
        async let coldConnection = ADBManager.connectAndVerifyWirelessTarget("192.168.1.42:41000",
            connectTimeout: 0.1, verificationAttempts: 1, expectedHardwareSerial: "PHONE-A")
        try await Task.sleep(nanoseconds: 50_000_000)
        let startupCancellationAt = Date()
        cancelledStartup.cancel()
        let cancelledStartupResult = await cancelledStartup.value
        check(cancelledStartupResult.0 == -999 && Date().timeIntervalSince(startupCancellationAt) < 0.2,
              "Cancellation during cold daemon startup returns promptly")
        let (_, mdnsResult, connectionResult) = await (coldDevices, coldMDNS, coldConnection)
        let coldCommands = try commands()
        check(mdnsResult.0 == 0 && connectionResult.success, "Cold daemon startup does not consume the short query/connect deadline")
        check(coldCommands.filter { $0["command"] as? String == "start-server" }.count == 1,
              "Concurrent detection, discovery, and reconnect share one daemon startup")
        check(!coldCommands.contains { $0["command"] as? String == "kill-server" }, "Cold startup needs no recovery restart")
        check(coldCommands.first?["command"] as? String == "start-server", "Start ADB before sending concurrent queries")
        check(mdnsResult.0 == 0 && connectionResult.success,
              "Cancelling one startup waiter does not cancel another caller's connection")

        try fixture(["services": ["adb-PHONE-A-current _adb-tls-connect._tcp 192.168.1.42:45555",
                                  "adb-PHONE-B-current _adb-tls-connect._tcp 192.168.1.43:45666"]])
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-current", port: 45555))
        let partialDiscovery = await ADBManager.discoverWirelessEndpoints(for: ["PHONE-A", "PHONE-B"])
        check(Set(partialDiscovery.endpoints.compactMap(\.hardwareSerial)) == ["PHONE-A", "PHONE-B"],
              "A partial native discovery still resolves every requested hardware serial")
        check(partialDiscovery.endpoints.count == 2, "Merge native and ADB discovery without duplicate endpoints")
        WirelessDiscovery.shared.stop()

        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-old", port: 45555))
        WirelessDiscovery.shared.invalidate(target: "192.168.1.42:45555")
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-PHONE-A-old", port: 45555))
        try fixture(["services": ["adb-PHONE-A-old _adb-tls-connect._tcp 192.168.1.42:45555",
                                  "adb-PHONE-A-new _adb-tls-connect._tcp 192.168.1.42:46487"]])
        var delivered: [String] = []
        let freshDiscovery = await ADBManager.discoverWirelessEndpoints(for: ["PHONE-A"]) { delivered.append($0.target) }
        check(freshDiscovery.endpoints.map(\.target) == ["192.168.1.42:46487"],
              "A rejected port cannot return from native or ADB discovery snapshots")
        check(delivered == ["192.168.1.42:46487"], "Deliver only the current usable discovery candidate")
        WirelessDiscovery.shared.stop()

        try fixture(["services": ["adb-PHONE-A-new _adb-tls-connect._tcp 192.168.1.42:46487"]])
        var availableBeforePeer = false
        var lookupFinished = false
        let slowPeerLookup = Task {
            let result = await ADBManager.discoverWirelessEndpoints(for: ["PHONE-A", "PHONE-MISSING"]) { _ in
                availableBeforePeer = !lookupFinished
            }
            lookupFinished = true
            return result
        }
        let partialAt = Date()
        while !availableBeforePeer, Date().timeIntervalSince(partialAt) < 0.4 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(availableBeforePeer && !lookupFinished,
              "Deliver a matching phone before an unresolved peer's discovery finishes")
        slowPeerLookup.cancel()
        _ = await slowPeerLookup.value
        check(Date().timeIntervalSince(partialAt) < 0.7, "Cancelling a peer lookup does not wait for DNS deadlines")
        WirelessDiscovery.shared.stop()

        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"], "services": []])
        let verified = await ADBManager.connectAndVerifyWirelessTarget("192.168.1.42:41000",
            connectTimeout: 1, verificationAttempts: 1, expectedHardwareSerial: "PHONE-A")
        check(verified.success, "Verify a remembered device")
        check(ADBManager.rememberedWirelessDevices.first?.hardwareSerial == "PHONE-A", "Store hardware identity")
        check(await ADBManager.getHardwareSerial(for: "192.168.1.42:41000") == "PHONE-A", "Hardware identity is not an IP:port")
        let rejected = await ADBManager.connectAndVerifyWirelessTarget("192.168.1.42:41000",
            connectTimeout: 1, verificationAttempts: 1, expectedHardwareSerial: "PHONE-B")
        check(!rejected.success, "Reject a TLS-authorized but different phone")

        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"], "services": [], "stale": ["192.168.1.9:45000"]])
        let refreshed = await ADBManager.connectAndVerifyWirelessTarget("192.168.1.9:45000",
            connectTimeout: 1, verificationAttempts: 1, expectedHardwareSerial: "PHONE-A")
        check(refreshed.success, "Refresh an already-connected transport that cannot run commands")
        check(try commands().contains { $0["command"] as? String == "disconnect" }, "Clear only the stale target")

        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"], "services": []])
        let started = Date()
        let manual = await ADBManager.connectWireless(ip: "192.168.1.42", port: "41000")
        check(manual.0, "Manual connection works without multicast")
        check(Date().timeIntervalSince(started) < 2, "No initial 5.25-second discovery wait")

        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"], "services": [],
                     "transientFailures": ["192.168.1.42:41000": 1]])
        let temporarilyStarting = await ADBManager.connectWireless(ip: "192.168.1.42", port: "41000")
        check(temporarilyStarting.0, "Retry a current port if adbd is briefly unavailable after a debugging toggle")
        check(!(try commands()).contains { $0["command"] as? String == "pair" }, "Toggle recovery reuses pairing without a new handshake")

        ADBManager.activeDeviceSerial = nil
        Shell.useDefaultServer = false
        ConnectionTestDefaults.shared.reset()
        ADBManager.rememberWirelessDevice(target: old.target, hardwareSerial: "PHONE-A", hostname: "phone.local")
        ADBManager.rememberWirelessDevice(target: "192.168.1.99:46000", hardwareSerial: "PHONE-OFFLINE")
        try fixture([
            "live": ["192.168.1.42:41000": "PHONE-A"],
            "services": ["adb-PHONE-A-random\t_adb-tls-connect._tcp\t192.168.1.42:41000\tphone.local"],
            "delays": [old.target: 5, "192.168.1.99:46000": 5, "192.168.1.42:41000": 0.3],
        ])
        let manager = DeviceManager()
        var displayedOfflineDuringStartup = false
        let startupObservation = manager.$isDetecting.sink {
            if !$0 && !manager.isConnected { displayedOfflineDuringStartup = true }
        }
        let startup = Date()
        await manager.detectDevice()
        while !manager.isConnected, Date().timeIntervalSince(startup) < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(manager.isConnected, "Recover after simultaneous IP and port change")
        startupObservation.cancel()
        check(!displayedOfflineDuringStartup, "Never publish the offline page while initial wireless recovery is pending")
        check(!manager.isDetecting, "Dismiss startup progress as soon as a device connects, even with offline peers")
        check(Date().timeIntervalSince(startup) < 3, "Offline saved devices do not block the first verified connection")
        check(ADBManager.activeDeviceSerial == "192.168.1.42:41000", "Activate the recovered phone")
        check(ADBManager.rememberedWirelessDevices.first { $0.hardwareSerial == "PHONE-A" }?.target == "192.168.1.42:41000", "Keep the current endpoint in memory")
        check(Set(ConnectionTestDefaults.shared.stringArray(forKey: "wirelessRememberedHardwareSerials") ?? []) == ["PHONE-A", "PHONE-OFFLINE"] &&
              ConnectionTestDefaults.shared.data(forKey: "wirelessDeviceIdentities") == nil,
              "A verified connection persists only serials, without endpoint records")
        check(!(ConnectionTestDefaults.shared.stringArray(forKey: "connectedWirelessDevices") ?? []).contains("192.168.1.8"), "Remove the obsolete IP after identity recovery")
        manager.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        ADBManager.rememberWirelessDevice(target: "192.168.1.42:41000", hardwareSerial: "PHONE-A")
        ADBManager.rememberWirelessDevice(target: "192.168.1.43:42000", hardwareSerial: "PHONE-B")
        try fixture(["live": ["192.168.1.42:45000": "PHONE-A", "192.168.1.43:46000": "PHONE-B"],
            "services": ["adb-PHONE-A-unchanged _adb-tls-connect._tcp 192.168.1.42:45000",
                         "adb-PHONE-B-unchanged _adb-tls-connect._tcp 192.168.1.43:46000"]])
        let toggledDevices = DeviceManager()
        let toggledAt = Date()
        await toggledDevices.detectDevice()
        while toggledDevices.availableDevices.filter({ $0.status == "device" }).count < 2,
              Date().timeIntervalSince(toggledAt) < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(toggledDevices.availableDevices.filter { $0.status == "device" }.count == 2,
              "Both paired phones reconnect after their ports rotate under unchanged service names")
        check(Set(ADBManager.rememberedWirelessDevices.map(\.target)) == ["192.168.1.42:45000", "192.168.1.43:46000"],
              "Keep each device's current connect port independently in memory")
        check(!(try commands()).contains { $0["command"] as? String == "pair" }, "Two-device toggle recovery requires no new pairing")
        toggledDevices.stopMonitoring()

        try fixture(["live": ["192.168.1.43:48001": "PHONE-B"]])
        _ = await ADBManager.connectAndVerifyWirelessTarget("192.168.1.43:48001",
            connectTimeout: 1, verificationAttempts: 1, expectedHardwareSerial: "PHONE-B")
        try fixture(["live": ["192.168.1.43:48000": "PHONE-A", "192.168.1.43:48001": "PHONE-B"],
                     "devices": ["56037": ["192.168.1.42:45000": "offline", "192.168.1.43:48001": "device"]],
                     "services": ["adb-PHONE-A-unchanged _adb-tls-connect._tcp 192.168.1.43:48000"],
                     "disconnectedSerials": ["192.168.1.42:45000"]])
        let monitored = DeviceManager()
        monitored.isConnected = true
        let health = monitored.connectionHealthMonitor
        health.startMonitoring(serial: "192.168.1.42:45000", ip: "192.168.1.42", hwSerial: "PHONE-A", deviceManager: monitored)
        let healthAt = Date()
        while health.monitoredSerial != "192.168.1.43:48000", Date().timeIntervalSince(healthAt) < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(health.monitoredSerial == "192.168.1.43:48000" && health.isHealthy,
              "The disconnect monitor recovers by serial when both IP and port change")
        let healthConnections = try commands().filter { $0["command"] as? String == "connect" }
        check(!healthConnections.isEmpty && healthConnections.allSatisfy { $0["args"] as? [String] == ["connect", "192.168.1.43:48000"] },
              "The disconnect monitor never retries an old IP or saved port")
        while !(try commands()).contains(where: { $0["command"] as? String == "disconnect" }),
              Date().timeIntervalSince(healthAt) < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let cleanupConnections = try commands().filter { $0["command"] as? String == "disconnect" }
        check(!cleanupConnections.isEmpty && cleanupConnections.allSatisfy { $0["args"] as? [String] == ["disconnect", "192.168.1.42:45000"] },
              "Stale cleanup removes the same hardware serial and preserves another phone sharing its new IP")
        monitored.stopMonitoring()

        // Restore the saved record used by the following restart test.
        ConnectionTestDefaults.shared.reset()
        ADBManager.rememberWirelessDevice(target: "192.168.1.42:41000", hardwareSerial: "PHONE-A")

        // A relaunch resolves the saved hardware serial using a current advertisement.
        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"],
                     "services": ["adb-PHONE-A-random _adb-tls-connect._tcp 192.168.1.42:41000"]])
        ADBManager.activeDeviceSerial = nil
        let restarted = DeviceManager()
        let restartedAt = Date()
        await restarted.detectDevice()
        while !restarted.isConnected, Date().timeIntervalSince(restartedAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(restarted.isConnected, "Relaunch discovers the remembered serial instead of reusing an old endpoint")
        restarted.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        ConnectionTestDefaults.shared.set(["192.168.1.8"], forKey: "connectedWirelessDevices")
        ConnectionTestDefaults.shared.set([old.target], forKey: "connectedWirelessSerials")
        try fixture(["live": ["192.168.1.42:41000": "PHONE-A"],
            "services": ["adb-PHONE-A-random\t_adb-tls-connect._tcp\t192.168.1.42:41000"]])
        ADBManager.activeDeviceSerial = nil
        let migrated = DeviceManager()
        let migrationAt = Date()
        _ = await migrated.connectWirelessly(ip: "192.168.1.42", port: "41000")
        while !migrated.isConnected, Date().timeIntervalSince(migrationAt) < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(migrated.isConnected, "An explicit connection upgrades an IP-only legacy pairing to a hardware identity")
        check(ADBManager.rememberedWirelessDevices.first?.hardwareSerial == "PHONE-A", "Upgrade legacy record to a stable identity")
        migrated.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        ADBManager.rememberWirelessDevice(target: old.target, hardwareSerial: "PHONE-A")
        ADBManager.activeDeviceSerial = nil
        try fixture(["live": [old.target: "PHONE-A"], "services": ["adb-PHONE-A-random _adb-tls-connect._tcp 192.168.1.8:37001"], "daemonFault": true])
        let recoveredDaemon = DeviceManager()
        let recoveryAt = Date()
        await recoveredDaemon.detectDevice()
        while !recoveredDaemon.isConnected, Date().timeIntervalSince(recoveryAt) < 4 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        check(recoveredDaemon.isConnected, "Recover a private daemon reporting a protocol fault")
        check((try commands()).filter { $0["command"] as? String == "kill-server" }.count == 1, "Restart the private daemon at most once")
        recoveredDaemon.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        ADBManager.rememberWirelessDevice(target: old.target, hardwareSerial: "PHONE-A")
        ADBManager.activeDeviceSerial = nil
        try fixture(["services": ["adb-PHONE-A-random _adb-tls-connect._tcp 192.168.1.8:47000"],
                     "connectError": "failed to connect: Connection refused"])
        let unreachable = DeviceManager()
        let unreachableAt = Date()
        await unreachable.detectDevice()
        check(unreachable.isDetecting && !unreachable.isConnected, "Keep searching while a remembered phone is temporarily unreachable")
        while unreachable.isWirelessReconnectHuntActive, Date().timeIntervalSince(unreachableAt) < 23 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if unreachable.isWirelessReconnectHuntActive || unreachable.isDetecting || unreachable.isConnected {
            let details = "Bounded failure active=\(unreachable.isWirelessReconnectHuntActive) detecting=\(unreachable.isDetecting) connected=\(unreachable.isConnected) elapsed=\(Date().timeIntervalSince(unreachableAt)) devices=\(unreachable.availableDevices) status=\(unreachable.statusMessage) commands=\(try commands())\n"
            FileHandle.standardError.write(Data(details.utf8))
        }
        check(!unreachable.isWirelessReconnectHuntActive && !unreachable.isDetecting && !unreachable.isConnected,
              "An unreachable phone eventually displays the disconnected page after the bounded search")
        check(!((try commands()).contains { $0["command"] as? String == "kill-server" }),
              "An unavailable IP must not restart a healthy daemon")
        let unavailableCommands = try commands()
        let connectCommands = unavailableCommands.filter { $0["command"] as? String == "connect" }
        check(connectCommands.count == 1 && connectCommands.first?["args"] as? [String] == ["connect", "192.168.1.8:47000"],
              "Try only the current serial-matched endpoint once when its port is closed")
        await unreachable.detectDevice()
        check(!unreachable.isDetecting && !unreachable.isWirelessReconnectHuntActive,
              "Periodic detection does not reopen the initial loading/retry loop after discovery times out")
        unreachable.stopMonitoring()

        ConnectionTestDefaults.shared.reset()
        try fixture([:])
        let unpaired = DeviceManager()
        check(unpaired.lastDetectionDate == nil, "Do not show a completed check before initial detection")
        await unpaired.detectDevice()
        check(!unpaired.isDetecting && !unpaired.isWirelessReconnectHuntActive, "No remembered phone shows connection options immediately")
        check(unpaired.lastDetectionDate != nil && !unpaired.isDetectionInProgress,
              "An empty completed scan publishes a timestamp and clears the dashboard activity state")
        unpaired.stopMonitoring()

        // Device ownership is preserved when private Wi-Fi and shared USB coexist.
        ConnectionTestDefaults.shared.reset()
        ConnectionTestDefaults.shared.set(true, forKey: "fixtureDefaultServerRunning")
        try fixture(["devices": ["56037": ["192.168.1.42:41000": "device"], "5037": ["USB-SERIAL": "device"]],
            "live": ["192.168.1.42:41000": "PHONE-A"], "services": []])
        let mixed = await ADBManager.listAllConnectedDevices()
        check(mixed.count == 2, "List private Wi-Fi and shared USB together")
        check(Shell.serverPortBySerial["USB-SERIAL"] == 5037, "Remember USB server ownership")
        check(Shell.serverPortBySerial["192.168.1.42:41000"] == 56037, "Remember private Wi-Fi ownership")

        try fixture(["runningServers": ["56037": false, "5037": true], "startupDelay": 5,
                     "devices": ["5037": ["USB-SERIAL": "device"]]])
        let sharedAt = Date()
        let sharedUSB = await ADBManager.listAllConnectedDevices()
        check(sharedUSB.contains { $0.serial == "USB-SERIAL" } && Date().timeIntervalSince(sharedAt) < 1,
              "An existing shared USB connection does not wait for a cold private daemon")
        check(!(try commands()).contains { $0["command"] as? String == "start-server" },
              "Do not start an unused private daemon when USB is already available")

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        try fixture(["devices": ["56037": ["USB-UNAUTHORIZED": "unauthorized", "192.168.1.42:41000": "device"]],
            "live": ["192.168.1.42:41000": "PHONE-A"], "services": []])
        let selection = DeviceManager()
        await selection.detectDevice()
        check(selection.isConnected && selection.connectionType == .wireless, "Ready Wi-Fi is selected ahead of unauthorized USB")
        check(selection.availableDevices.contains { $0.status == "unauthorized" }, "Keep the USB authorization prompt available")
        selection.stopMonitoring()

        // Reproduce startup with a stale port, followed by a current advertisement
        // under the same service name while another remembered phone is absent.
        ConnectionTestDefaults.shared.reset()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil
        let refusedPort = "192.168.1.42:43096"
        let replacementPort = "192.168.1.42:48933"
        ADBManager.rememberWirelessDevice(target: refusedPort, hardwareSerial: "ROTATING-PHONE")
        ADBManager.rememberWirelessDevice(target: "192.168.1.43:43000", hardwareSerial: "ABSENT-PHONE")
        try fixture(["live": [replacementPort: "ROTATING-PHONE"],
                     "services": ["adb-ROTATING-PHONE-unchanged _adb-tls-connect._tcp 192.168.1.42:43096"],
                     "servicesAfterConnect": [refusedPort: ["adb-ROTATING-PHONE-unchanged _adb-tls-connect._tcp 192.168.1.42:48933"]]])
        let rotatingPhone = DeviceManager()
        let rotatedAt = Date()
        await rotatingPhone.detectDevice()
        while !rotatingPhone.isConnected, Date().timeIntervalSince(rotatedAt) < 4 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(rotatingPhone.isConnected && ADBManager.activeDeviceSerial == replacementPort,
              "A refused old port is replaced during the same startup search, without waiting for another absent phone")
        let rotationCommands = try commands()
        check(rotationCommands.filter { $0["command"] as? String == "connect" && $0["args"] as? [String] == ["connect", refusedPort] }.count == 1,
              "Do not repeatedly connect to the obsolete port")
        check(!rotationCommands.contains { ["pair", "kill-server"].contains($0["command"] as? String ?? "") },
              "A port change recovers without pairing again or restarting ADB")
        rotatingPhone.stopMonitoring()
        WirelessDiscovery.shared.stop()

        // Reproduce the user's initial no-route failure: the service stays the
        // same and the phone becomes reachable without another Bonjour callback.
        ConnectionTestDefaults.shared.reset()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil
        let routingTarget = "192.168.1.42:41321"
        ADBManager.rememberWirelessDevice(target: routingTarget, hardwareSerial: "ROUTING-PHONE")
        try fixture(["live": [routingTarget: "ROUTING-PHONE"], "services": [],
                     "transientFailures": [routingTarget: 1], "transientError": "failed to connect: No route to host"])
        WirelessDiscovery.shared.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-ROUTING-PHONE-current", port: 41321))
        let routingPhone = DeviceManager()
        let routingAt = Date()
        await routingPhone.detectDevice()
        while !routingPhone.isConnected, Date().timeIntervalSince(routingAt) < 5 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(routingPhone.isConnected,
              "A transient no-route failure retries the same native advertisement without a new callback")
        let routingCommands = try commands()
        check(routingCommands.filter { $0["command"] as? String == "connect" }.count == 2,
              "Routing recovery uses only two bounded attempts on the current endpoint")
        check(!routingCommands.contains { ["pair", "kill-server"].contains($0["command"] as? String ?? "") },
              "Temporary routing failure does not reset pairing or restart a healthy daemon")
        routingPhone.stopMonitoring()
        WirelessDiscovery.shared.stop()

        // A failed shell verification must not quarantine a current endpoint for 30 seconds.
        ConnectionTestDefaults.shared.reset()
        WirelessDiscovery.shared.stop()
        ADBManager.activeDeviceSerial = nil
        let wakingTarget = "192.168.1.42:45050"
        ADBManager.rememberWirelessDevice(target: wakingTarget, hardwareSerial: "WAKING-PHONE")
        try fixture(["live": [wakingTarget: "WAKING-PHONE"],
                     "verificationDelays": [wakingTarget: [3.5]],
                     "services": []])
        WirelessDiscovery.shared.start()
        // Let NWPathMonitor establish the initial interface before injecting the
        // one native advertisement; a real interface refresh clears old records.
        try await Task.sleep(nanoseconds: 200_000_000)
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-WAKING-PHONE-current", port: 45050))
        let wakingPhone = DeviceManager()
        let wakingAt = Date()
        await wakingPhone.detectDevice()
        while !wakingPhone.isConnected, Date().timeIntervalSince(wakingAt) < 6 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        if !wakingPhone.isConnected {
            FileHandle.standardError.write(Data("Waking failure: \(try commands()) endpoints=\(WirelessDiscovery.shared.endpoints)\n".utf8))
        }
        check(wakingPhone.isConnected, "A slow first shell verification retries during the same search")
        check((try commands()).filter { $0["command"] as? String == "connect" }.count == 2,
              "A verification timeout permits one bounded retry on the same advertised endpoint")
        wakingPhone.stopMonitoring()
        WirelessDiscovery.shared.stop()

        ConnectionTestDefaults.shared.reset()
        ConnectionTestDefaults.shared.set(true, forKey: "fixtureDefaultServerRunning")
        ADBManager.activeDeviceSerial = nil
        try fixture(["devices": ["5037": ["FAST-USB": "device"]], "deviceDelays": ["56037": 3]])
        let fastUSB = DeviceManager()
        let fastAt = Date()
        let slowSnapshot = Task { await fastUSB.detectDevice() }
        while !fastUSB.isConnected, Date().timeIntervalSince(fastAt) < 0.8 {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(fastUSB.isConnected && ADBManager.activeDeviceSerial == "FAST-USB",
              "Publish a ready USB device before the other daemon's two-second timeout")
        await slowSnapshot.value
        check(fastUSB.isConnected, "The other daemon timing out does not drop the ready connection")
        fastUSB.stopMonitoring()

        Shell.serverPortBySerial["DUPLICATE-USB"] = 5037
        try fixture(["devices": ["56037": ["DUPLICATE-USB": "device"], "5037": ["DUPLICATE-USB": "offline"]]])
        let duplicate = await ADBManager.listAllConnectedDevices()
        check(duplicate.first?.status == "device" && Shell.serverPortBySerial["DUPLICATE-USB"] == 56037,
              "A stale previous owner cannot replace the same serial's ready transport")

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        try fixture(["runningServers": ["56037": true, "5037": false],
                     "devices": ["56037": ["LIVE-USB": "unauthorized"]],
                     "trackEvents": ["56037": [
                        ["after": 0.15, "devices": ["LIVE-USB": "device"]],
                        ["after": 0.6, "devices": [String: String]()]
                     ]]])
        let trackedUSB = DeviceManager()
        await trackedUSB.detectDevice()
        check(!trackedUSB.isConnected && !trackedUSB.isDetecting, "Show authorization before the user accepts")
        let authorizedAt = Date()
        trackedUSB.startMonitoring()
        trackedUSB.startMonitoring()
        while !trackedUSB.isConnected, Date().timeIntervalSince(authorizedAt) < 0.7 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(trackedUSB.isConnected, "Accepting USB debugging connects immediately without a timer or replug")
        while trackedUSB.isConnected, Date().timeIntervalSince(authorizedAt) < 1.4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!trackedUSB.isConnected, "ADB transport loss is detected even without an IOKit detach")
        let trackedCommands = try commands()
        check(trackedCommands.filter { $0["command"] as? String == "track-devices" }.count == 1,
              "Repeated monitor startup keeps one subscription and does not start an unused daemon")
        check(!trackedCommands.contains { $0["command"] as? String == "start-server" }, "Tracking never starts the shared server")
        trackedUSB.stopMonitoring()
        WirelessDiscovery.shared.stop()
        try await Task.sleep(nanoseconds: 100_000_000)

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        try fixture(["deviceDelays": ["56037": 0.2], "devices": ["56037": ["LATE-USB": "device"]]])
        let stoppedDetection = DeviceManager()
        let delayedDetection = Task { await stoppedDetection.detectDevice() }
        try await Task.sleep(nanoseconds: 30_000_000)
        await stoppedDetection.detectDevice() // Queue another refresh behind the delayed one.
        stoppedDetection.stopMonitoring()
        await delayedDetection.value
        check(!stoppedDetection.isConnected && ADBManager.activeDeviceSerial == nil,
              "A detection completing after monitoring stops cannot restore an old connection")
        check(stoppedDetection.lastDetectionDate == nil && !stoppedDetection.isDetectionInProgress,
              "A cancelled scan cannot publish a completed dashboard check")

        ConnectionTestDefaults.shared.reset()
        ADBManager.activeDeviceSerial = nil
        let stableTarget = "192.168.1.60:45600"
        try fixture(["runningServers": ["56037": true, "5037": false],
                     "devices": ["56037": [stableTarget: "device"]], "live": [stableTarget: "STABLE-PHONE"]])
        let stablePhone = DeviceManager()
        stablePhone.startMonitoring()
        await stablePhone.detectDevice()
        try await Task.sleep(nanoseconds: 15_100_000_000)
        WirelessDiscovery.shared.resolveService(FixtureNetService(name: "adb-STABLE-PHONE-current", port: 45600))
        await stablePhone.detectDevice()
        try await Task.sleep(nanoseconds: 100_000_000)
        if !stablePhone.isConnected || stablePhone.isWirelessReconnectHuntActive {
            FileHandle.standardError.write(Data("Stable failure: connected=\(stablePhone.isConnected) devices=\(stablePhone.availableDevices) commands=\(try commands())\n".utf8))
        }
        check(stablePhone.isConnected && !stablePhone.isWirelessReconnectHuntActive,
              "A healthy monitored phone does not become missing when its liveness timestamp ages")
        check(!(try commands()).contains { $0["command"] as? String == "connect" },
              "Discovery changes do not reconnect an already healthy phone")
        stablePhone.stopMonitoring()
        WirelessDiscovery.shared.stop()

        // Explicit disconnect must remove identity-based recovery as well as the old IP map.
        ADBManager.forgetWirelessDevice(hardwareSerial: "PHONE-A")
        check(!ADBManager.rememberedWirelessDevices.contains { $0.hardwareSerial == "PHONE-A" }, "Forget explicitly disconnected identity")
        check(!ADBManager.rememberedWirelessSerials.contains("PHONE-A"), "Forget the durable hardware identity too")

        try await testPairing()

        let cancelledAt = Date()
        let command = Task { await Shell.runAsyncWithTimeout("/bin/sleep", args: ["10"], timeoutSeconds: 20) }
        try await Task.sleep(nanoseconds: 50_000_000)
        command.cancel()
        let cancelled = await command.value
        check(cancelled.0 == -999 && Date().timeIntervalSince(cancelledAt) < 0.5, "Cancellation promptly stops a command")
        let alreadyCancelled = Task {
            await Shell.runAsyncWithTimeout("/bin/sleep", args: ["10"], timeoutSeconds: 20)
        }
        alreadyCancelled.cancel()
        check(await alreadyCancelled.value.0 == -999, "Cancellation before launch")
        let timed = await Shell.runAsyncWithTimeout("/bin/sleep", args: ["10"], timeoutSeconds: 0.05)
        check(timed.0 == -1, "Command deadline")
        let large = await Shell.runAsyncWithTimeout("/usr/bin/head", args: ["-c", "1048576", "/dev/zero"], timeoutSeconds: 2)
        check(large.0 == 0 && large.1.utf8.count == 1048576, "Drain large output without deadlock or truncation")
        Shell.serverPortBySerial["USB-SERIAL"] = 5037
        Shell.useDefaultServer = false
        ADBManager.activeDeviceSerial = "USB-SERIAL"
        check(ADBManager.deviceArgs(["shell", "echo", "ok"]).prefix(2) == ["-P", "5037"], "Pin transfer arguments to the owning server")
        check(Shell.environment(for: ["-s", "USB-SERIAL", "shell"])["ANDROID_ADB_SERVER_PORT"] == "5037", "Route explicit device queries to the owner")
        ADBManager.activeDeviceSerial = nil

        // Shutdown must own every child and reject reconnects queued before quit,
        // while still permitting targeted cleanup of the app's private daemon.
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try AppProcessLifecycle.run(child)
        let watcher = Task { await Shell.runAsync("/bin/sleep", args: ["10"]) }
        try fixture(["runningServers": ["56037": false], "startupDelay": 5])
        let queuedStartup = Task {
            await Shell.runAsyncWithTimeout(ADBManager.getADBPath(), args: ["mdns", "services"],
                                           timeoutSeconds: 1, environment: Shell.adbEnvironment)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let shutdownAt = Date()
        AppProcessLifecycle.beginTermination()
        AppProcessLifecycle.beginTermination()
        let watcherResult = await watcher.value
        let queuedStartupResult = await queuedStartup.value
        let shutdownCommands = try commands()
        while child.isRunning, Date().timeIntervalSince(shutdownAt) < 1 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        check(!child.isRunning && watcherResult.0 != 0 && Date().timeIntervalSince(shutdownAt) < 1,
              "Quit stops tracked transfer and watcher processes promptly")
        check(queuedStartupResult.0 != 0 && !shutdownCommands.contains { $0["command"] as? String == "mdns" },
              "Quit cancels a cold daemon startup before its queued discovery command can launch")
        try fixture([:])
        let blocked = await Shell.runAsyncWithTimeout(ADBManager.getADBPath(), args: ["start-server"], timeoutSeconds: 1)
        let blockedCommands = try commands()
        check(blocked.0 == -999 && blockedCommands.isEmpty, "A late reconnect cannot restart ADB after quit")
        let stoppedManager = DeviceManager()
        await stoppedManager.detectDevice()
        check((try commands()).isEmpty, "Queued device detection cannot start ADB during quit")
        Shell.serverPortBySerial["192.168.1.42:41000"] = 5037
        ADBManager.markAppManagedWirelessTarget("192.168.1.42:41000")
        await ADBManager.disconnectAppManagedWireless(timeoutSeconds: 1, allowDuringTermination: true)
        _ = await Shell.runAsyncWithTimeout(ADBManager.getADBPath(), args: ["kill-server"], timeoutSeconds: 1,
                                          environment: Shell.adbEnvironment, allowDuringTermination: true)
        let cleanupCommands = try commands()
        check(cleanupCommands.contains { $0["command"] as? String == "disconnect" && $0["port"] as? Int == 5037 },
              "Quit can still disconnect an app-managed session on its owning shared server")
        check(cleanupCommands.filter { $0["command"] as? String == "kill-server" }.allSatisfy { $0["port"] as? Int == Shell.appADBServerPort }
              && cleanupCommands.contains { $0["command"] as? String == "kill-server" },
              "Quit kills only the private daemon, preserving Android Studio's server")
        Swift.print("PASS: \(assertions) connection regression assertions")
    }
}
