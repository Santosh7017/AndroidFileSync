import Foundation
import Network

nonisolated enum AppProcessLifecycle { static var isTerminating: Bool { false } }
enum AppLogger { static func log(_ message: String) {} }

@main struct PairingProbeTests {
    static func main() async throws {
        let packet = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let port = UInt16(CommandLine.arguments[2])!
        let parsed = PairingMDNSProbe.parse(packet, requestID: 0x1234, serviceName: "afs-fixture")
        precondition(parsed.count == 1 && parsed[0].target == "192.168.1.210:40645")
        precondition(parsed[0].hostname == "Android.local")
        var zeroID = packet
        zeroID[0] = 0
        zeroID[1] = 0
        precondition(PairingMDNSProbe.parse(zeroID, requestID: 0x1234, serviceName: "afs-fixture") == parsed)
        precondition(PairingMDNSProbe.parse(packet, requestID: 0x1235, serviceName: "afs-fixture").isEmpty)
        precondition(PairingMDNSProbe.parse(packet, requestID: 0x1234, serviceName: "afs-other").isEmpty)
        for length in 0..<packet.count {
            precondition(PairingMDNSProbe.parse(packet.prefix(length), requestID: 0x1234, serviceName: "afs-fixture").isEmpty)
        }
        var malformed = packet
        malformed[2] = 0 // A query must not be treated as a response.
        precondition(PairingMDNSProbe.parse(malformed, requestID: 0x1234, serviceName: "afs-fixture").isEmpty)
        malformed = packet
        malformed[12] = 0xC0
        malformed[13] = 12 // A compressed name pointing to itself must not hang.
        precondition(PairingMDNSProbe.parse(malformed, requestID: 0x1234, serviceName: "afs-fixture").isEmpty)
        malformed[13] = 255 // Nor may a pointer run past the packet.
        precondition(PairingMDNSProbe.parse(malformed, requestID: 0x1234, serviceName: "afs-fixture").isEmpty)

        let root = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        let srv = try Data(contentsOf: root.appendingPathComponent("srv.bin"))
        let address = try Data(contentsOf: root.appendingPathComponent("address.bin"))
        let goodbye = try Data(contentsOf: root.appendingPathComponent("goodbye.bin"))
        let rotated = try Data(contentsOf: root.appendingPathComponent("rotated.bin"))
        var split = PairingMDNSProbe.ResponseAccumulator(serviceName: "afs-fixture")
        split.ingest(srv, requestID: 0x1234)
        precondition(split.endpoints.isEmpty && split.unresolvedHosts == ["Android.local"])
        split.ingest(address, requestID: 0x1234)
        precondition(split.endpoints == parsed, "SRV and A replies must accumulate across packets")
        split.ingest(rotated, requestID: 0x1234)
        precondition(split.endpoints.first?.port == 40646, "Current SRV replaces the old pairing port")
        split.ingest(goodbye, requestID: 0x1234)
        precondition(split.endpoints.first?.port == 40646, "An old-port goodbye must preserve the new port")
        split.ingest(srv, requestID: 0x1234)
        split.ingest(goodbye, requestID: 0x1234)
        precondition(split.endpoints.isEmpty, "TTL-zero goodbyes remove the matching service")
        var reversed = PairingMDNSProbe.ResponseAccumulator(serviceName: "afs-fixture")
        reversed.ingest(address, requestID: 0x1234)
        reversed.ingest(srv, requestID: 0x1234)
        precondition(reversed.endpoints == parsed, "Packet order must not matter")
        var wrong = PairingMDNSProbe.ResponseAccumulator(serviceName: "afs-other")
        wrong.ingest(srv, requestID: 0x1234)
        wrong.ingest(address, requestID: 0x1234)
        precondition(wrong.endpoints.isEmpty, "A known phone address does not authorize an unrelated service")
        var truncated = PairingMDNSProbe.ResponseAccumulator(serviceName: "afs-fixture")
        truncated.ingest(address, requestID: 0x1234)
        truncated.ingest(srv.dropLast(), requestID: 0x1234)
        precondition(truncated.endpoints.isEmpty, "A malformed partial packet must not mutate accumulated records")

        let live = await PairingMDNSProbe.discover(serviceName: "afs-fixture", timeout: 1,
            destination: "127.0.0.1", port: port, sourceAddresses: ["127.0.0.1"])
        precondition(live == parsed, "A direct UDP reply must reach production QR discovery")
        let splitLive = await PairingMDNSProbe.discover(serviceName: "afs-fixture", timeout: 1,
            destination: "invalid", port: port, sourceAddresses: ["127.0.0.1"], knownHosts: ["127.0.0.1"])
        precondition(splitLive == parsed, "An exact unicast SRV query and follow-up A query work without browse records")
        let deadlineStart = Date()
        let empty = await PairingMDNSProbe.discover(serviceName: "afs-fixture", timeout: 0.08,
            destination: "127.0.0.1", port: port, sourceAddresses: ["127.0.0.1"])
        precondition(empty.isEmpty && Date().timeIntervalSince(deadlineStart) < 0.6)
        let cancellationStart = Date()
        let task = Task { await PairingMDNSProbe.discover(serviceName: "afs-fixture", timeout: 10,
            destination: "127.0.0.1", port: port, sourceAddresses: ["127.0.0.1"]) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.isEmpty && Date().timeIntervalSince(cancellationStart) < 0.6)
        print("PASS: exact unicast QR queries without PTR, split SRV/A replies, ID zero, rotation, goodbyes, malformed packets, deadlines, and cancellation")

        precondition(PairingNetworkAccess.isPermissionDenied(.posix(.EHOSTUNREACH), localNetworkDenied: true),
                     "A denied native path explains macOS 27's No route to host")
        precondition(!PairingNetworkAccess.isPermissionDenied(.posix(.EHOSTUNREACH), localNetworkDenied: false),
                     "No route to host alone must not be labelled a confirmed privacy denial")
        precondition(PairingNetworkAccess.isPermissionDenied(.posix(.EPERM), localNetworkDenied: false))
        precondition(PairingNetworkAccess.isPermissionDenied(.posix(.EACCES), localNetworkDenied: false))
        precondition(!PairingNetworkAccess.isPermissionDenied(.posix(.ECONNREFUSED), localNetworkDenied: false))
        let accessPort = UInt16(CommandLine.arguments[3])!
        let access = await PairingNetworkAccess.check(host: "127.0.0.1", port: accessPort, timeout: 1)
        precondition(access == .allowed, "The native check must complete after sending UDP without waiting for an mDNS reply")
        let invalidAccess = await PairingNetworkAccess.check(host: "", port: accessPort, timeout: 1)
        precondition(invalidAccess == .unavailable("Invalid phone address"))
        let cancelledCheck = Task { await PairingNetworkAccess.check(host: "127.0.0.1", port: accessPort, timeout: 10) }
        cancelledCheck.cancel()
        let cancelledNative = await cancelledCheck.value
        precondition(cancelledNative == .cancelled)
        print("PASS: Native UDP permission check without a TCP probe, privacy/routing classification, validation, and cancellation")
    }
}
