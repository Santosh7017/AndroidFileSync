import Foundation
import Network

/// Diagnose the app's UDP mDNS path after an ADB TCP pairing failure. There is
/// no general Local Network permission API: UDP success or denial must not gate
/// the actual TCP handshake. This never opens a spare TCP pairing connection.
nonisolated enum PairingNetworkAccess {
    enum Result: Equatable {
        case allowed
        case denied(String)
        case unavailable(String)
        case cancelled
    }

    static func check(host: String, port: UInt16 = 5353, timeout: TimeInterval = 3) async -> Result {
        guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else { return .cancelled }
        guard !host.isEmpty, !host.contains("\0"), port > 0 else { return .unavailable("Invalid phone address") }
        let operation = Request(host: host, port: port, timeout: timeout)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
        withExtendedLifetime(operation) {}
        return result
    }

    // EHOSTUNREACH by itself is ambiguous on macOS. Network.framework's path
    // reason distinguishes privacy denial from a VPN/router/routing failure.
    static func isPermissionDenied(_ error: NWError?, localNetworkDenied: Bool) -> Bool {
        if localNetworkDenied { return true }
        guard case .posix(let code) = error else { return false }
        return code == .EACCES || code == .EPERM
    }

    private final class Request: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.androidfilesync.pairing-network-access")
        private let connection: NWConnection
        private let timeout: TimeInterval
        private var continuation: CheckedContinuation<Result, Never>?
        private var result: Result?
        private var deadline: DispatchWorkItem?
        private var waitingForPermission = false
        private var lastState = "setup"
        private var sent = false

        init(host: String, port: UInt16, timeout: TimeInterval) {
            connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            self.timeout = timeout
        }

        func start(_ continuation: CheckedContinuation<Result, Never>) {
            queue.async { [self] in
                if let result { continuation.resume(returning: result); return }
                self.continuation = continuation
                let deadline = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    let detail = "UDP check timed out; \(self.pathDescription)"
                    self.finish(self.waitingForPermission ? .denied(detail) : .unavailable(detail))
                }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
                connection.pathUpdateHandler = { [weak self] path in
                    guard let self, self.result == nil else { return }
                    self.waitingForPermission = path.unsatisfiedReason == .localNetworkDenied
                }
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, self.result == nil else { return }
                    switch state {
                    case .ready:
                        self.lastState = "ready"
                        guard !self.sent else { return }
                        self.sent = true
                        self.connection.send(content: PairingMDNSProbe.query(requestID: 0),
                            completion: .contentProcessed { [weak self] error in
                                guard let self, self.result == nil else { return }
                                if let error {
                                    self.lastState = "send failed, error=\(error.debugDescription)"
                                    self.finish(self.denied(error) ? .denied(self.pathDescription) : .unavailable(self.pathDescription))
                                } else { self.finish(.allowed) }
                            })
                    case .waiting(let error):
                        self.lastState = "waiting, error=\(error.debugDescription)"
                        // A first-use prompt can initially look like denial.
                        // Keep the connection alive so Allow resumes this QR.
                        self.waitingForPermission = self.denied(error)
                    case .failed(let error):
                        self.lastState = "failed, error=\(error.debugDescription)"
                        self.finish(self.denied(error) ? .denied(self.pathDescription) : .unavailable(self.pathDescription))
                    case .cancelled:
                        self.finish(.cancelled)
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func cancel() {
            queue.async { [self] in finish(.cancelled) }
        }

        private func denied(_ error: NWError) -> Bool {
            PairingNetworkAccess.isPermissionDenied(error,
                localNetworkDenied: connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
        }

        private var pathDescription: String {
            guard let path = connection.currentPath else { return "state=\(lastState), path=unavailable" }
            let interfaces = path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            return "state=\(lastState), path=\(path.status), reason=\(path.unsatisfiedReason), interfaces=\(interfaces)"
        }

        private func finish(_ value: Result) {
            guard result == nil else { return }
            result = value
            deadline?.cancel()
            deadline = nil
            connection.stateUpdateHandler = nil
            connection.pathUpdateHandler = nil
            connection.cancel()
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
