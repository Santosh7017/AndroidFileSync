import Foundation
import Darwin
import Network
import AppKit
import dnssd

/// A resolved ADB service. Service identity survives DHCP and debugging-port changes.
nonisolated struct WirelessEndpoint: Equatable, Hashable, Sendable {
    let serviceName: String
    let serviceType: String
    let host: String
    let port: UInt16
    var hostname: String?

    var target: String { Self.target(host: host, port: port) }
    var hardwareSerial: String? { Self.hardwareSerial(from: serviceName) }
    var isConnectService: Bool { serviceType == "_adb-tls-connect._tcp" }
    var outputLine: String {
        [serviceName, serviceType, target, hostname].compactMap { $0 }.joined(separator: "\t")
    }

    static func target(host: String, port: UInt16) -> String {
        let unwrapped = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return unwrapped.contains(":") ? "[\(unwrapped)]:\(port)" : "\(unwrapped):\(port)"
    }

    static func address(from target: String) -> (host: String, port: UInt16)? {
        guard let colon = target.lastIndex(of: ":"),
              let port = UInt16(target[target.index(after: colon)...]), port > 0 else { return nil }
        let host = String(target[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }
        return (host, port)
    }

    static func hardwareSerial(from serviceName: String) -> String? {
        let name = serviceName.components(separatedBy: ".").first ?? serviceName
        guard name.hasPrefix("adb-") else { return nil }
        let body = String(name.dropFirst(4))
        guard let suffix = body.lastIndex(of: "-") else { return nil }
        let serial = String(body[..<suffix])
        return serial.isEmpty ? nil : serial
    }

    static func parse(_ output: String) -> [WirelessEndpoint] {
        var seen = Set<WirelessEndpoint>()
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 3,
                  let type = parts.first(where: { $0.hasPrefix("_adb-tls-") }),
                  let target = parts.dropFirst(2).first(where: { address(from: $0) != nil }),
                  let address = address(from: target) else { return nil }
            let endpoint = WirelessEndpoint(serviceName: parts[0], serviceType: type.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
                host: address.host, port: address.port,
                hostname: parts.last.flatMap { $0.hasSuffix(".local") || $0.hasSuffix(".local.") ? $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) : nil })
            return seen.insert(endpoint).inserted ? endpoint : nil
        }
    }
}

/// A remembered phone with presence derived only from current discovery, never a saved address.
nonisolated struct RecognizedWirelessDevice: Identifiable, Equatable {
    let id: String
    let displayName: String
    let address: String?
    var isNearby: Bool { address != nil }

    static func devices(from endpoints: [WirelessEndpoint], rememberedSerials: Set<String>,
                        namesBySerial: [String: String], namesByService: [String: String]) -> [Self] {
        let phones = endpoints.filter {
            $0.isConnectService || ($0.serviceType == "_adb-tls-pairing._tcp" && $0.serviceName.hasPrefix("adb-"))
        }
        return rememberedSerials.map { serial in
            // Pairing and connect services, IPv4 and IPv6 all describe the same phone.
            let services = phones.filter { $0.hardwareSerial == serial }.sorted {
                if $0.isConnectService != $1.isConnectService { return $0.isConnectService }
                if $0.host.contains(":") != $1.host.contains(":") { return !$0.host.contains(":") }
                return $0.target < $1.target
            }
            let cachedServiceNames = namesByService.keys.sorted().filter {
                WirelessEndpoint.hardwareSerial(from: $0) == serial
            }.compactMap { namesByService[$0] }
            let names = [namesBySerial[serial]].compactMap { $0 } + cachedServiceNames
            let name = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            return Self(id: serial, displayName: name ?? "Android device · \(serial.suffix(4))",
                        address: services.first?.host)
        }.sorted {
            // Keep rows stable as availability changes.
            if $0.displayName != $1.displayName { return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

/// Remember identities separately from addresses; an IP address can be reassigned to another phone.
nonisolated struct RememberedWirelessDevice: Codable, Equatable {
    var hardwareSerial: String
    var target: String
    var hostname: String?
}

nonisolated struct WirelessReconnectCandidate: Hashable {
    let target: String
    let hardwareSerial: String?
    let advertised: Bool
}

nonisolated enum WirelessReconnectPolicy {
    static func candidates(endpoints: [WirelessEndpoint], rememberedSerials: Set<String>) -> [WirelessReconnectCandidate] {
        var seen = Set<String>()
        return endpoints.compactMap { endpoint in
            guard endpoint.isConnectService, let serial = endpoint.hardwareSerial,
                  rememberedSerials.contains(serial), seen.insert(endpoint.target).inserted else { return nil }
            return WirelessReconnectCandidate(target: endpoint.target, hardwareSerial: serial, advertised: true)
        }
    }

}

/// Keep SRV and address questions open so changes do not depend on another browse event.
/// All DNSServiceRef operations and callbacks run on this serial queue.
nonisolated final class BonjourServiceResolver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.androidfilesync.bonjour-resolver")
    private let queueKey = DispatchSpecificKey<Bool>()
    private let name: String
    private let type: String
    private let domain: String
    private let onEndpoint: @Sendable (WirelessEndpoint?) -> Void
    private var resolveRef: DNSServiceRef?
    private var srvRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private struct SRVRecord {
        let fullname: String
        let interface: UInt32
        let data: Data
        var port: UInt16 { UInt16(data[data.startIndex + 4]) << 8 | UInt16(data[data.startIndex + 5]) }
    }
    private var srvRecords: [UInt32: SRVRecord] = [:]
    private var lastReconfirmation: [UInt16: Date] = [:]
    private var pendingReconfirmation: UInt16?
    private var hostname = ""
    private var port: UInt16 = 0
    private var addresses = Set<String>()
    private var stopped = false
    private var retryWork: DispatchWorkItem?
    private var ipv6Publication: DispatchWorkItem?

    init(name: String, type: String, domain: String, onEndpoint: @escaping @Sendable (WirelessEndpoint?) -> Void) {
        self.name = name
        self.type = type.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.domain = domain
        self.onEndpoint = onEndpoint
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() {
        queue.async { [self] in
            stopped = false
            startOnQueue()
        }
    }

    private func startOnQueue() {
        guard !stopped, resolveRef == nil else { return }
        let error = DNSServiceResolve(&resolveRef, DNSServiceFlags(kDNSServiceFlagsForceMulticast),
            0, name, type, domain, Self.resolveReply, Unmanaged.passUnretained(self).toOpaque())
        guard error == kDNSServiceErr_NoError, let resolveRef else { recoverOnQueue(); return }
        guard DNSServiceSetDispatchQueue(resolveRef, queue) == kDNSServiceErr_NoError else { recoverOnQueue(); return }
        // Retain the exact SRV bytes and interface so a failed TCP connection can
        // ask mDNSResponder to verify its cache, rather than just reading it again.
        var fullname = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        guard DNSServiceConstructFullName(&fullname, name, type, domain) == 0 else { return }
        let queryError = DNSServiceQueryRecord(&srvRef, DNSServiceFlags(kDNSServiceFlagsForceMulticast),
            0, String(cString: fullname), UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN),
            Self.srvReply, Unmanaged.passUnretained(self).toOpaque())
        if queryError != kDNSServiceErr_NoError || srvRef == nil ||
            DNSServiceSetDispatchQueue(srvRef, queue) != kDNSServiceErr_NoError {
            recoverOnQueue()
        }
    }

    /// A refused connect port is evidence that the cached SRV answer may be stale.
    /// Reconfirm only that service, with a cooldown, while keeping live queries open
    /// to receive the replacement. Do not restart ADB or flush unrelated DNS.
    func reconfirm(port: UInt16) {
        queue.async { [self] in
            guard !stopped,
                  lastReconfirmation[port].map({ Date().timeIntervalSince($0) >= 5 }) ?? true else { return }
            pendingReconfirmation = port
            reconfirmOnQueue()
        }
    }

    private func reconfirmOnQueue() {
        guard let failedPort = pendingReconfirmation else { return }
        let records = srvRecords.values.filter { $0.port == failedPort && $0.interface != 0 }
        guard !records.isEmpty else { return }
        pendingReconfirmation = nil
        lastReconfirmation[failedPort] = Date()
        for record in records {
            record.data.withUnsafeBytes {
                _ = DNSServiceReconfirmRecord(0, record.interface, record.fullname,
                    UInt16(kDNSServiceType_SRV), UInt16(kDNSServiceClass_IN), UInt16($0.count), $0.baseAddress)
            }
            // Android may also replace the service-instance suffix on a toggle.
            // Verify its browse entry too so a cached, vanished instance cannot
            // postpone discovery of the new name until the normal PTR TTL expires.
            let labels = [name] + type.split(separator: ".").map(String.init) + domain.split(separator: ".").map(String.init)
            var instance = Data()
            for label in labels {
                let bytes = Array(label.utf8)
                guard bytes.count <= 63 else { return }
                instance.append(UInt8(bytes.count))
                instance.append(contentsOf: bytes)
            }
            instance.append(0)
            instance.withUnsafeBytes {
                _ = DNSServiceReconfirmRecord(0, record.interface, type + "." + domain,
                    UInt16(kDNSServiceType_PTR), UInt16(kDNSServiceClass_IN), UInt16($0.count), $0.baseAddress)
            }
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }

    deinit { stop() }

    private func stopOnQueue() {
        stopped = true
        retryWork?.cancel()
        retryWork = nil
        clearReferences()
    }

    private func clearReferences() {
        ipv6Publication?.cancel()
        ipv6Publication = nil
        if let addressRef { DNSServiceRefDeallocate(addressRef) }
        if let resolveRef { DNSServiceRefDeallocate(resolveRef) }
        if let srvRef { DNSServiceRefDeallocate(srvRef) }
        addressRef = nil
        resolveRef = nil
        srvRef = nil
        srvRecords.removeAll()
        addresses.removeAll()
    }

    private func recoverOnQueue() {
        clearReferences()
        onEndpoint(nil)
        guard !stopped else { return }
        retryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.startOnQueue() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func publishAddress() {
        guard let preferred = addresses.sorted().first(where: { !$0.contains(":") }) else {
            guard !addresses.isEmpty else {
                ipv6Publication?.cancel()
                ipv6Publication = nil
                onEndpoint(nil)
                return
            }
            // Give an IPv4 answer a brief chance to arrive before publishing a scoped IPv6 route.
            guard ipv6Publication == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.addressRef != nil, let host = self.addresses.sorted().first else { return }
                self.ipv6Publication = nil
                self.publish(host: host)
            }
            ipv6Publication = work
            queue.asyncAfter(deadline: .now() + 0.05, execute: work)
            return
        }
        ipv6Publication?.cancel()
        ipv6Publication = nil
        publish(host: preferred)
    }

    private func publish(host: String) {
        onEndpoint(WirelessEndpoint(serviceName: name, serviceType: type, host: host, port: port, hostname: hostname))
    }

    private static let srvReply: DNSServiceQueryRecordReply = { reference, flags, interface, error, fullname, type, _, length, data, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        guard reference == resolver.srvRef, error == kDNSServiceErr_NoError,
              type == UInt16(kDNSServiceType_SRV), length >= 7, let fullname, let data else { return }
        let record = SRVRecord(fullname: String(cString: fullname), interface: interface,
                               data: Data(bytes: data, count: Int(length)))
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 {
            resolver.srvRecords[interface] = record
            resolver.reconfirmOnQueue()
        } else if resolver.srvRecords[interface]?.data == record.data {
            resolver.srvRecords.removeValue(forKey: interface)
        }
    }

    private static let resolveReply: DNSServiceResolveReply = { reference, _, interface, error, _, host, networkPort, _, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        guard reference == resolver.resolveRef else { return }
        guard error == kDNSServiceErr_NoError else { resolver.recoverOnQueue(); return }
        guard let host else { return }
        let port = UInt16(bigEndian: networkPort)
        let hostname = String(cString: host).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard port > 0, !hostname.isEmpty else { return }
        if hostname == resolver.hostname, port == resolver.port, resolver.addressRef != nil { return }
        if let addressRef = resolver.addressRef { DNSServiceRefDeallocate(addressRef) }
        resolver.ipv6Publication?.cancel()
        resolver.ipv6Publication = nil
        resolver.addressRef = nil
        resolver.addresses.removeAll()
        resolver.hostname = hostname
        resolver.port = port
        resolver.onEndpoint(nil)
        let status = DNSServiceGetAddrInfo(&resolver.addressRef, DNSServiceFlags(kDNSServiceFlagsForceMulticast),
            interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            hostname, BonjourServiceResolver.addressReply, context)
        guard status == kDNSServiceErr_NoError, let addressRef = resolver.addressRef else { resolver.recoverOnQueue(); return }
        if DNSServiceSetDispatchQueue(addressRef, resolver.queue) != kDNSServiceErr_NoError {
            resolver.recoverOnQueue()
        }
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = { reference, flags, _, error, _, address, _, context in
        guard let context else { return }
        let resolver = Unmanaged<BonjourServiceResolver>.fromOpaque(context).takeUnretainedValue()
        guard reference == resolver.addressRef else { return }
        if error != kDNSServiceErr_NoError {
            if error != kDNSServiceErr_NoSuchRecord { resolver.recoverOnQueue() }
            return
        }
        guard let address else { return }
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let length = socklen_t(address.pointee.sa_len)
        guard length > 0, getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return }
        let host = String(cString: buffer)
        if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { resolver.addresses.insert(host) }
        else { resolver.addresses.remove(host) }
        resolver.publishAddress()
    }
}

@MainActor
final class WirelessDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    static let shared = WirelessDiscovery()
    var onChange: (() -> Void)?
    private var browsers: [NetServiceBrowser] = []
    private var services: [String: NetService] = [:]
    private var resolved: [String: WirelessEndpoint] = [:]
    /// ADB snapshots identify a service to reconfirm even before Bonjour finishes
    /// resolving it. They are never promoted to native discovery results.
    private var advertised: [String: WirelessEndpoint] = [:]
    private var resolvedAt: [String: Date] = [:]
    private var resolutionStarted: [String: Date] = [:]
    private var resolving = Set<String>()
    private var continuousResolvers: [String: BonjourServiceResolver] = [:]
    private var resolverIDs: [String: UUID] = [:]
    private var rejectedTargets: [String: Date] = [:]
    private let resolutionInterval: TimeInterval
    private let makeService: (NetService) -> NetService
    private var pathMonitor: NWPathMonitor?
    private var receivedInitialPath = false
    private var wakeObserver: NSObjectProtocol?

    init(resolutionInterval: TimeInterval = 3, makeService: ((NetService) -> NetService)? = nil) {
        self.resolutionInterval = resolutionInterval
        self.makeService = makeService ?? { NetService(domain: $0.domain, type: $0.type, name: $0.name) }
        super.init()
    }

    var endpoints: [WirelessEndpoint] {
        // Android can retain the service name while replacing its SRV port.
        // NetService.startMonitoring watches TXT, not SRV/address changes.
        // Re-resolve on demand instead of trusting one resolution indefinitely.
        let now = Date()
        for (key, service) in Array(services) where
            continuousResolvers[key] == nil &&
            now.timeIntervalSince(resolutionStarted[key] ?? .distantPast) >= resolutionInterval &&
            (!resolving.contains(key) || now.timeIntervalSince(resolutionStarted[key] ?? .distantPast) >= 4) {
            resolveService(makeService(service))
        }
        return resolved.filter {
            accepts($0.value) && (continuousResolvers[$0.key] != nil ||
                now.timeIntervalSince(resolvedAt[$0.key] ?? .distantPast) <= max(6, resolutionInterval * 2))
        }.map(\.value).sorted { $0.target < $1.target }
    }

    /// Drop an unreachable endpoint and resolve its service again without
    /// deleting the device's pairing or restarting either ADB daemon.
    func invalidate(target: String, reject: Bool = true) {
        if reject { rejectedTargets[target] = Date() }
        let known = advertised.merging(resolved) { _, native in native }
        for (key, endpoint) in known where endpoint.target == target {
            if resolved[key]?.target == target {
                resolved.removeValue(forKey: key)
                resolvedAt.removeValue(forKey: key)
            }
            if reject, let resolver = continuousResolvers[key] {
                AppLogger.log("📱 [WirelessDiscovery] Reconfirming refused service=\(endpoint.serviceName), port=\(endpoint.port)")
                resolver.reconfirm(port: endpoint.port)
            }
            if let service = services[key],
               continuousResolvers[key] == nil,
               !resolving.contains(key),
               Date().timeIntervalSince(resolutionStarted[key] ?? .distantPast) >= 0.5 {
                resolveService(makeService(service))
            }
        }
    }

    /// A rejected port cannot be reintroduced by ADB or a delayed resolver snapshot.
    func accepts(_ endpoint: WirelessEndpoint) -> Bool {
        rejectedTargets[endpoint.target].map { Date().timeIntervalSince($0) >= 30 } ?? true
    }

    /// An older ADB query must not reintroduce a port already replaced by a live
    /// Bonjour callback for the same service.
    func acceptsSnapshot(_ endpoint: WirelessEndpoint) -> Bool {
        guard accepts(endpoint) else { return false }
        let native = resolved[endpoint.serviceType + "./" + endpoint.serviceName]
        return native == nil || native?.target == endpoint.target
    }

    func verified(target: String) { rejectedTargets.removeValue(forKey: target) }

    func resolveService(_ service: NetService) {
        guard !AppProcessLifecycle.isTerminating else { return }
        let key = key(service)
        services[key]?.delegate = nil
        services[key]?.stop()
        services[key] = service
        resolutionStarted[key] = Date()
        resolving.insert(key)
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func start() {
        guard browsers.isEmpty, !AppProcessLifecycle.isTerminating else { return }
        if pathMonitor == nil {
            receivedInitialPath = false
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self, weak monitor] in
                    guard let self, self.pathMonitor === monitor else { return }
                    // The first callback describes the interface we just started
                    // browsing. Clearing it can discard the first fresh port.
                    guard self.receivedInitialPath else { self.receivedInitialPath = true; return }
                    self.refresh()
                }
            }
            monitor.start(queue: DispatchQueue(label: "com.androidfilesync.network-change"))
            pathMonitor = monitor
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refresh() }
                }
        }
        for type in ["_adb-tls-connect._tcp.", "_adb-tls-pairing._tcp."] {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            browsers.append(browser)
        }
    }

    func stop() {
        continuousResolvers.values.forEach { $0.stop() }
        continuousResolvers.removeAll()
        resolverIDs.removeAll()
        browsers.forEach { $0.stop() }
        services.values.forEach { $0.stop() }
        browsers.removeAll()
        services.removeAll()
        resolved.removeAll()
        advertised.removeAll()
        resolvedAt.removeAll()
        resolutionStarted.removeAll()
        resolving.removeAll()
        rejectedTargets.removeAll()
        pathMonitor?.pathUpdateHandler = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        onChange = nil
    }

    /// Discard addresses cached on the old interface after Wi-Fi/VPN changes or sleep.
    func refresh() {
        guard !browsers.isEmpty, !AppProcessLifecycle.isTerminating else { return }
        continuousResolvers.values.forEach { $0.stop() }
        continuousResolvers.removeAll()
        resolverIDs.removeAll()
        browsers.forEach { $0.stop() }
        services.values.forEach { $0.stop() }
        browsers.removeAll()
        services.removeAll()
        resolved.removeAll()
        advertised.removeAll()
        resolvedAt.removeAll()
        resolutionStarted.removeAll()
        resolving.removeAll()
        start()
        onChange?()
    }

    private func key(_ service: NetService) -> String { service.type + "/" + service.name }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        observeService(service)
    }

    /// The command-line browse fallback may see a name before NetServiceBrowser does.
    func observeConnectService(name: String) {
        observeService(NetService(domain: "local.", type: "_adb-tls-connect._tcp.", name: name))
    }

    func observeConnectEndpoint(_ endpoint: WirelessEndpoint) {
        guard endpoint.isConnectService, acceptsSnapshot(endpoint) else { return }
        let service = NetService(domain: "local.", type: endpoint.serviceType + ".", name: endpoint.serviceName)
        advertised[key(service)] = endpoint
        guard resolved[key(service)] == nil else { return }
        observeService(service)
    }

    private func observeService(_ service: NetService) {
        guard !AppProcessLifecycle.isTerminating else { return }
        let key = key(service)
        services[key] = service
        guard continuousResolvers[key] == nil else { return }
        let id = UUID()
        resolverIDs[key] = id
        let resolver = BonjourServiceResolver(name: service.name, type: service.type, domain: service.domain) { [weak self] endpoint in
            Task { @MainActor [weak self] in
                guard let self, self.resolverIDs[key] == id, !AppProcessLifecycle.isTerminating else { return }
                guard let endpoint, self.accepts(endpoint) else {
                    if self.resolved.removeValue(forKey: key) != nil { self.onChange?() }
                    return
                }
                let changed = self.resolved[key] != endpoint
                self.resolved[key] = endpoint
                self.resolvedAt[key] = Date()
                if changed {
                    AppLogger.log("📱 [WirelessDiscovery] source=bonjour-stream, serial=\(endpoint.hardwareSerial ?? "unknown"), target=\(endpoint.target)")
                    self.onChange?()
                }
            }
        }
        continuousResolvers[key] = resolver
        resolver.start()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        guard browsers.contains(where: { $0 === browser }) else { return }
        let key = key(service)
        resolverIDs.removeValue(forKey: key)
        continuousResolvers.removeValue(forKey: key)?.stop()
        services.removeValue(forKey: key)?.stop()
        advertised.removeValue(forKey: key)
        resolved.removeValue(forKey: key)
        resolvedAt.removeValue(forKey: key)
        resolutionStarted.removeValue(forKey: key)
        resolving.remove(key)
        onChange?()
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard services[key(sender)] === sender,
              let port = UInt16(exactly: sender.port), port > 0 else { return }
        let hosts = (sender.addresses ?? []).compactMap { data -> String? in
            data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress, bytes.count >= MemoryLayout<sockaddr>.size else { return nil }
                let address = base.assumingMemoryBound(to: sockaddr.self)
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(data.count), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
                return String(cString: buffer)
            }
        }
        let hostname = sender.hostName?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard let host = hosts.first(where: { !$0.contains(":") }) ?? hosts.first ?? hostname else { return }
        let key = key(sender)
        resolving.remove(key)
        let endpoint = WirelessEndpoint(serviceName: sender.name,
            serviceType: sender.type.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            host: host, port: port, hostname: hostname)
        guard accepts(endpoint) else { return }
        let changed = resolved[key] != endpoint
        resolved[key] = endpoint
        resolvedAt[key] = Date()
        if changed { onChange?() }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        guard services[key(sender)] === sender else { return }
        let key = key(sender)
        resolving.remove(key)
        let removed = resolved.removeValue(forKey: key) != nil
        resolvedAt.removeValue(forKey: key)
        if removed { onChange?() }
    }
}
