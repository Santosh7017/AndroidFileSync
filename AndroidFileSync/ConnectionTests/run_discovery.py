#!/usr/bin/env python3
"""Test the production SRV cache against a temporary local Bonjour service.

No phone connections, ADB daemons, app preferences, or windows are used.
"""
from pathlib import Path
import subprocess
import tempfile
import uuid
import sys
from StaleBonjourFixture import StaleBonjourFixture

sources = Path(__file__).resolve().parents[1] / "AndroidFileSync"
negative_control = "--without-reconfirmation" in sys.argv
with tempfile.TemporaryDirectory(prefix="afs-discovery-tests-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    fixture = root / "Fixture.swift"
    fixture.write_text(r'''
import Foundation
import dnssd

nonisolated enum AppProcessLifecycle {
    static var isTerminating: Bool { false }
}
enum AppLogger { static func log(_ message: String) { Swift.print(message) } }

/// Publish individual records so the SRV port changes without a browse remove/add.
final class FixturePublisher {
    private var connection: DNSServiceRef?
    private var srvRecord: DNSRecordRef?
    private let host: String

    init(name: String, type: String, port: UInt16, publishBrowseRecord: Bool = true, publishTXT: Bool = true) {
        host = "afs-test-" + UUID().uuidString + ".local."
        precondition(DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError)
        precondition(DNSServiceSetDispatchQueue(connection, .main) == kDNSServiceErr_NoError)
        let fullname = name + "." + type + "local."
        _ = register(name: host, type: UInt16(kDNSServiceType_A), data: Data([127, 0, 0, 1]), shared: false)
        if publishTXT {
            _ = register(name: fullname, type: UInt16(kDNSServiceType_TXT), data: Data([0]), shared: false)
        }
        srvRecord = register(name: fullname, type: UInt16(kDNSServiceType_SRV), data: srvData(port: port), shared: false)
        if publishBrowseRecord {
            _ = register(name: type + "local.", type: UInt16(kDNSServiceType_PTR), data: Self.dnsName(fullname), shared: true)
        }
    }

    private static func dnsName(_ name: String) -> Data {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".") {
            let part = Array(label.utf8)
            bytes.append(UInt8(part.count))
            bytes += part
        }
        return Data(bytes + [0])
    }

    private func srvData(port: UInt16) -> Data {
        Data([0, 0, 0, 0, UInt8(port >> 8), UInt8(port & 255)]) + Self.dnsName(host)
    }

    private func register(name: String, type: UInt16, data: Data, shared: Bool) -> DNSRecordRef? {
        var record: DNSRecordRef?
        let error = data.withUnsafeBytes {
            DNSServiceRegisterRecord(connection, &record, DNSServiceFlags(shared ? kDNSServiceFlagsShared : kDNSServiceFlagsUnique),
                0, name, type, UInt16(kDNSServiceClass_IN), UInt16(data.count), $0.baseAddress, 120,
                { _, _, _, _, _ in }, nil)
        }
        precondition(error == kDNSServiceErr_NoError)
        return record
    }

    func updatePort(to port: UInt16) {
        let data = srvData(port: port)
        let error = data.withUnsafeBytes {
            DNSServiceUpdateRecord(connection, srvRecord, 0, UInt16(data.count), $0.baseAddress, 120)
        }
        precondition(error == kDNSServiceErr_NoError)
    }

    func stop() {
        if let connection { DNSServiceRefDeallocate(connection) }
        connection = nil
    }
}

@main struct DiscoveryTests {
    static func main() {
        if CommandLine.arguments.count > 2 {
            let name = CommandLine.arguments[1]
            let marker = CommandLine.arguments[2]
            let discovery = WirelessDiscovery()
            discovery.start()
            let deadline = Date().addingTimeInterval(12)
            var rejectedAt: Date?
            var recovered = false
            while Date() < deadline && !recovered {
                if let endpoint = discovery.endpoints.first(where: { $0.serviceName == name }) {
                    if endpoint.port == 50553 && rejectedAt == nil {
                        try! Data().write(to: URL(fileURLWithPath: marker))
                        rejectedAt = Date()
                        discovery.invalidate(target: endpoint.target)
                    } else if endpoint.port == 50554 {
                        recovered = true
                    }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            }
            discovery.stop()
            guard recovered && rejectedAt != nil else {
                print("FAIL: A refused cached port did not trigger a fresh network SRV answer")
                exit(2)
            }
            print("PASS: Missed SRV update recovered after reconfirmation in \(String(format: "%.2f", Date().timeIntervalSince(rejectedAt!)))s")
            return
        }
        let type = "_adb-tls-connect._tcp."
        let name = "adb-AFS_TEST-" + UUID().uuidString
        let discovery = WirelessDiscovery(resolutionInterval: 1)
        let publisher = FixturePublisher(name: name, type: type, port: 50453)
        discovery.start()

        let deadline = Date().addingTimeInterval(15)
        var initialResolved = false
        var rotatedResolved = false
        var seenPorts = Set<UInt16>()
        var rotatedAt: Date?
        while Date() < deadline && !rotatedResolved {
            if let endpoint = discovery.endpoints.first(where: { $0.serviceName == name }) {
                seenPorts.insert(endpoint.port)
                if !initialResolved && endpoint.port == 50453 {
                    initialResolved = true
                    // Change the SRV record in place, without removing/re-adding the service.
                    discovery.invalidate(target: endpoint.target)
                    publisher.updatePort(to: 50454)
                    rotatedAt = Date()
                } else if initialResolved && endpoint.port == 50454 {
                    rotatedResolved = endpoint.serviceName == name
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        publisher.stop()
        guard initialResolved && rotatedResolved else {
            fatalError("Native Bonjour did not resolve both SRV ports; observed \(seenPorts)")
        }
        print("PASS: Native Bonjour refreshes a changed port under the same service name")
        precondition(Date().timeIntervalSince(rotatedAt!) < 3, "A new port must arrive without a periodic re-resolution delay")
        print("PASS: A rejected port is replaced immediately through continuous SRV callbacks")
        let removalDeadline = Date().addingTimeInterval(3)
        while discovery.endpoints.contains(where: { $0.serviceName == name }), Date() < removalDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        precondition(!discovery.endpoints.contains(where: { $0.serviceName == name }), "A removed service must lose its endpoint")
        print("PASS: Removing the service discards its endpoint")
        discovery.stop()
        precondition(discovery.endpoints.isEmpty)
        print("PASS: Stopping native discovery removes its cached endpoints")

        // The phone can accept a QR and expose SRV/address records while its
        // browse PTR never reaches this Mac. Start an exact query before the
        // service exists, then publish it without a browse record.
        let qrName = "afs-hidden-" + UUID().uuidString
        let qrDiscovery = WirelessDiscovery()
        qrDiscovery.watchPairingService(name: qrName)
        let qrPublisher = FixturePublisher(name: qrName, type: "_adb-tls-pairing._tcp.",
            port: 50600, publishBrowseRecord: false)
        let qrDeadline = Date().addingTimeInterval(6)
        while !qrDiscovery.endpoints.contains(where: { $0.serviceName == qrName }), Date() < qrDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(qrDiscovery.endpoints.contains { $0.serviceName == qrName && $0.port == 50600 },
                     "An exact QR query must resolve a service that was never browsed")
        qrDiscovery.refresh()
        let refreshDeadline = Date().addingTimeInterval(3)
        while !qrDiscovery.endpoints.contains(where: { $0.serviceName == qrName }), Date() < refreshDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(qrDiscovery.endpoints.contains { $0.serviceName == qrName },
                     "Network refresh must restore the active QR's exact query")
        qrDiscovery.stopWatchingPairingService(name: qrName)
        precondition(!qrDiscovery.endpoints.contains { $0.serviceName == qrName },
                     "Stopping the QR query must remove its cached endpoint")
        qrPublisher.stop()
        qrDiscovery.stop()
        print("PASS: Exact native QR resolution without PTR, before publication, across refresh, and cleanup")

        // ADB needs SRV + an address; optional TXT metadata must not gate it.
        let sparseName = "afs-sparse-" + UUID().uuidString
        let sparseDiscovery = WirelessDiscovery()
        sparseDiscovery.watchPairingService(name: sparseName)
        let sparsePublisher = FixturePublisher(name: sparseName, type: "_adb-tls-pairing._tcp.",
            port: 50601, publishBrowseRecord: false, publishTXT: false)
        let sparseDeadline = Date().addingTimeInterval(3)
        while !sparseDiscovery.endpoints.contains(where: { $0.serviceName == sparseName }), Date() < sparseDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(sparseDiscovery.endpoints.contains { $0.serviceName == sparseName && $0.port == 50601 },
                     "An available SRV/address must resolve promptly without optional TXT or PTR records")
        sparsePublisher.stop()
        sparseDiscovery.stop()
        print("PASS: Native QR pairing resolves SRV/address without waiting for TXT metadata")
    }
}
''')
    discovery_source = root / "WirelessDiscovery.swift"
    production = (sources / "Managers/WirelessDiscovery.swift").read_text()
    if negative_control:
        production = production.replace("resolver.reconfirm(port: endpoint.port)", "/* Test control: leave the system cache untouched. */")
    discovery_source.write_text(production)
    compilation = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(root / "module-cache"), str(fixture),
        str(discovery_source), "-o", str(root / "discovery-tests"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if compilation.returncode:
        print(compilation.stderr)
        raise SystemExit(compilation.returncode)
    if not negative_control:
        subprocess.run([str(root / "discovery-tests")], check=True, timeout=20)

    if "--qr" in sys.argv:
        raise SystemExit(0)

    stale = StaleBonjourFixture("adb-AFS_STALE-" + uuid.uuid4().hex, root / "port-changed")
    try:
        stale.start()
        result = subprocess.run([str(root / "discovery-tests"), stale.name, str(stale.marker)], timeout=15)
        if negative_control:
            assert result.returncode == 2 and stale.marker.exists() and stale.fresh_queries == 0, \
                "The control must reproduce the stale-port failure when reconfirmation is disabled"
            print("PASS: Negative control reproduces the stale-port failure without reconfirmation")
        else:
            assert result.returncode == 0 and stale.fresh_queries > 0, \
                "The new port must come from a real SRV question, not an unsolicited announcement"
            print("PASS: Reconfirmation issued a fresh SRV question for the refused service")
    finally:
        stale.stop()
