import Foundation
import Darwin

/// Some Wi-Fi networks deliver mDNS questions but lose multicast responses.
/// A query from an ephemeral port requests a legacy unicast response (RFC 6762
/// section 6.7), avoiding that return path without knowing the phone's address.
nonisolated enum PairingMDNSProbe {
    private static let serviceType = "_adb-tls-pairing._tcp"

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func cancel() { lock.lock(); value = true; lock.unlock() }
    }

    static func discover(serviceName: String, timeout: TimeInterval = 1,
                         destination: String = "224.0.0.251", port: UInt16 = 5353,
                         sourceAddresses: [String]? = nil) async -> [WirelessEndpoint] {
        guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return [] }
        let cancellation = Cancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let result = probe(serviceName: serviceName, timeout: timeout,
                        destination: destination, port: port,
                        sourceAddresses: sourceAddresses ?? localIPv4Addresses(), cancellation: cancellation)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func localIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result = Set<String>()
        var current = head
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_MULTICAST) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.pointee.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                var ip = $0.pointee.sin_addr
                if inet_ntop(AF_INET, &ip, &buffer, socklen_t(buffer.count)) != nil {
                    result.insert(String(cString: buffer))
                }
            }
        }
        return result.sorted()
    }

    private static func address(_ host: String, port: UInt16) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        return address
    }

    private static func probe(serviceName: String, timeout: TimeInterval, destination: String,
                              port: UInt16, sourceAddresses: [String], cancellation: Cancellation) -> [WirelessEndpoint] {
        guard !cancellation.isCancelled, var remote = address(destination, port: port) else { return [] }
        let requestID = UInt16.random(in: 1...UInt16.max)
        let packet = query(requestID: requestID)
        var sockets: [pollfd] = []
        defer { sockets.forEach { close($0.fd) } }
        for source in sourceAddresses {
            guard !cancellation.isCancelled, var local = address(source, port: 0) else { continue }
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { continue }
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0 else { close(fd); continue }
            var ttl: UInt8 = 255
            _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl)))
            _ = setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &local.sin_addr, socklen_t(MemoryLayout<in_addr>.size))
            let sent = packet.withUnsafeBytes { bytes in
                withUnsafePointer(to: &remote) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == packet.count else { close(fd); continue }
            sockets.append(pollfd(fd: fd, events: Int16(POLLIN), revents: 0))
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while !sockets.isEmpty, !cancellation.isCancelled, !AppProcessLifecycle.isTerminating {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            let ready = poll(&sockets, nfds_t(sockets.count), Int32(min(100, remaining * 1000)))
            guard ready >= 0 else { break }
            for socket in sockets where socket.revents & Int16(POLLIN) != 0 {
                var bytes = [UInt8](repeating: 0, count: 65_535)
                let count = recv(socket.fd, &bytes, bytes.count, MSG_DONTWAIT)
                guard count > 0 else { continue }
                let endpoints = parse(Data(bytes.prefix(count)), requestID: requestID, serviceName: serviceName)
                if !endpoints.isEmpty, !cancellation.isCancelled { return endpoints }
            }
        }
        return []
    }

    static func query(requestID: UInt16) -> Data {
        var bytes: [UInt8] = [UInt8(requestID >> 8), UInt8(requestID & 255), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in (serviceType + ".local").split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0, 0, 12, 0, 1]) // PTR, IN; source port requests the direct reply.
        return Data(bytes)
    }

    /// Parse only the current QR's SRV record and its IPv4 address. Compression
    /// pointers, all record lengths and counts are checked before accessing bytes.
    static func parse(_ packet: Data, requestID: UInt16, serviceName: String) -> [WirelessEndpoint] {
        let bytes = Array(packet)
        func word(_ offset: Int) -> Int { Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) }
        guard bytes.count >= 12, word(0) == Int(requestID), word(2) & 0xFA0F == 0x8000 else { return [] }
        func name(at start: Int) -> (String, Int)? {
            var offset = start
            var end: Int?
            var visited = Set<Int>()
            var labels: [String] = []
            while offset < bytes.count, visited.insert(offset).inserted, visited.count <= 128 {
                let length = Int(bytes[offset])
                if length == 0 { return (labels.joined(separator: "."), end ?? offset + 1) }
                if length & 0xC0 == 0xC0 {
                    guard offset + 1 < bytes.count else { return nil }
                    if end == nil { end = offset + 2 }
                    offset = (length & 0x3F) << 8 | Int(bytes[offset + 1])
                } else {
                    guard length <= 63, offset + 1 + length <= bytes.count,
                          let label = String(bytes: bytes[(offset + 1)..<(offset + 1 + length)], encoding: .utf8) else { return nil }
                    labels.append(label)
                    offset += 1 + length
                }
            }
            return nil
        }
        var offset = 12
        for _ in 0..<word(4) {
            guard let (_, end) = name(at: offset), end + 4 <= bytes.count else { return [] }
            offset = end + 4
        }
        let expected = (serviceName + "." + serviceType + ".local").lowercased()
        var services: [(host: String, port: UInt16)] = []
        var addresses: [String: [String]] = [:]
        for _ in 0..<(word(6) + word(8) + word(10)) {
            guard let (recordName, end) = name(at: offset), end + 10 <= bytes.count else { return [] }
            let type = word(end)
            let recordClass = word(end + 2) & 0x7FFF
            let length = word(end + 8)
            offset = end + 10
            guard offset + length <= bytes.count else { return [] }
            let live = bytes[(end + 4)..<(end + 8)].contains { $0 != 0 }
            if recordClass == 1, live {
                if type == 33, recordName.lowercased() == expected, length >= 7,
                   word(offset + 4) > 0, let (host, nameEnd) = name(at: offset + 6), nameEnd <= offset + length {
                    services.append((host, UInt16(word(offset + 4))))
                } else if type == 1, length == 4 {
                    let ip = bytes[offset..<(offset + 4)].map(String.init).joined(separator: ".")
                    addresses[recordName.lowercased(), default: []].append(ip)
                }
            }
            offset += length
        }
        return services.flatMap { service in
            (addresses[service.host.lowercased()] ?? []).map {
                WirelessEndpoint(serviceName: serviceName, serviceType: serviceType,
                    host: $0, port: service.port, hostname: service.host)
            }
        }
    }
}
