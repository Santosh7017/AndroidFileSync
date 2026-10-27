import Foundation
import Network

/// Read only newly written, target-matched socket errors from ADB's daemon log.
/// Never export the raw log, which can contain pairing credentials from tracing.
nonisolated struct ADBPairingDiagnostics {
    private let url: URL
    private let offset: UInt64
    private let fileID: UInt64?

    init(environment: [String: String]) {
        let directory = environment["TMPDIR"] ?? NSTemporaryDirectory()
        url = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("adb.\(getuid()).log")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        offset = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        fileID = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func socketFailure(target: String, code: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let currentID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let start = currentID == fileID && size >= offset ? offset : 0
        // A shared daemon can log unrelated traffic; bound the read to 64 KiB.
        let boundedStart = max(start, size > 65_536 ? size - 65_536 : 0)
        do {
            try handle.seek(toOffset: boundedStart)
            guard let data = try handle.read(upToCount: 65_536) else { return nil }
            let marker = "Failed to start pairing connection client [failed to connect to '\(target)': "
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
                guard let range = line.range(of: marker), line.hasSuffix("]") else { continue }
                let reason = String(line[range.upperBound..<line.index(before: line.endIndex)])
                guard !reason.isEmpty, reason.count <= 256 else { continue }
                return code.isEmpty ? reason : reason.replacingOccurrences(of: code, with: "<redacted>")
            }
        } catch { return nil }
        return nil
    }
}

/// ADB's pair service sends OKAY followed by either a length-prefixed success
/// or FAIL + a length-prefixed reason. Some ADB clients parse FAIL as hex and
/// report "couldn't read status message", hiding a perfectly valid rejection.
nonisolated enum ADBPairingResponse {
    static func pair(serverPort: Int, target: String, code: String,
                     timeout: TimeInterval) async -> (Int32, String, String) {
        guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else {
            return (-999, "", "Pairing cancelled")
        }
        guard let port = UInt16(exactly: serverPort), port > 0,
              !code.isEmpty, !code.contains(":"), !code.contains("\0"),
              !target.isEmpty, !target.contains("\0") else {
            return (-1, "", "Invalid pairing request")
        }
        let request = Data("host:pair:\(code):\(target)".utf8)
        guard request.count <= 65_535 else { return (-1, "", "Pairing request is too long") }
        let operation = PairingRequest(port: port, request: request, timeout: timeout)
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
        withExtendedLifetime(operation) {}
        return result
    }

    private final class PairingRequest: @unchecked Sendable {
        private enum Phase { case status, response, reasonLength, payload(Int, Bool) }
        private let queue = DispatchQueue(label: "com.androidfilesync.pairing-response")
        private let connection: NWConnection
        private let request: Data
        private let timeout: TimeInterval
        private var phase: Phase = .status
        private var buffer = Data()
        private var continuation: CheckedContinuation<(Int32, String, String), Never>?
        private var result: (Int32, String, String)?
        private var deadline: DispatchWorkItem?

        init(port: UInt16, request: Data, timeout: TimeInterval) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            self.request = request
            self.timeout = timeout
        }

        func start(_ continuation: CheckedContinuation<(Int32, String, String), Never>) {
            queue.async { [self] in
                if let result { continuation.resume(returning: result); return }
                self.continuation = continuation
                let deadline = DispatchWorkItem { [weak self] in
                    self?.finish((-1, "", "Pairing response timed out"))
                }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, self.result == nil else { return }
                    switch state {
                    case .ready:
                        var message = Data(String(format: "%04x", self.request.count).utf8)
                        message.append(self.request)
                        self.connection.send(content: message, completion: .contentProcessed { [weak self] error in
                            guard let self, self.result == nil else { return }
                            if error != nil { self.finish((-1, "", "Could not send pairing request to the ADB server")) }
                            else { self.receive() }
                        })
                    case .failed:
                        self.finish((-1, "", "Could not read the pairing response from the ADB server"))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }

        func cancel() {
            queue.async { [self] in finish((-999, "", "Pairing cancelled")) }
        }

        private func receive() {
            guard result == nil else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
                guard let self, self.result == nil else { return }
                if let data { self.buffer.append(data); self.parse() }
                guard self.result == nil else { return }
                if complete || error != nil {
                    self.finish((-1, "", "ADB server closed an incomplete pairing response"))
                } else { self.receive() }
            }
        }

        private func parse() {
            while result == nil {
                switch phase {
                case .status, .response, .reasonLength:
                    guard buffer.count >= 4 else { return }
                    let header = Data(buffer.prefix(4))
                    buffer.removeFirst(4)
                    switch phase {
                    case .status:
                        if header == Data("OKAY".utf8) { phase = .response }
                        else if header == Data("FAIL".utf8) { phase = .reasonLength }
                        else { invalidResponse(); return }
                    case .response:
                        if header == Data("FAIL".utf8) { phase = .reasonLength }
                        else if let length = Self.length(header) { phase = .payload(length, false) }
                        else { invalidResponse(); return }
                    case .reasonLength:
                        guard let length = Self.length(header) else { invalidResponse(); return }
                        phase = .payload(length, true)
                    case .payload: break
                    }
                case .payload(let length, let failed):
                    guard buffer.count >= length else { return }
                    guard let text = String(data: buffer.prefix(length), encoding: .utf8), !text.isEmpty else {
                        invalidResponse(); return
                    }
                    // An OKAY transport acknowledgement alone never means pairing succeeded.
                    if !failed, text.lowercased().hasPrefix("successfully paired") {
                        finish((0, text, ""))
                    } else { finish((1, "", text)) }
                }
            }
        }

        private static func length(_ header: Data) -> Int? {
            guard header.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let text = String(data: header, encoding: .ascii) else { return nil }
            return Int(text, radix: 16)
        }

        private func invalidResponse() { finish((-1, "", "ADB server returned an invalid pairing response")) }

        private func finish(_ value: (Int32, String, String)) {
            guard result == nil else { return }
            result = value
            deadline?.cancel()
            deadline = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
