#!/usr/bin/env python3
"""Exercise production ADB pair-response framing on loopback; no phone connection."""
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

project = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='afs-pair-response-', dir='/private/tmp') as temporary:
    root = Path(temporary)
    harness = root / 'Harness.swift'
    harness.write_text(r'''
import Foundation
nonisolated enum AppProcessLifecycle { static var isTerminating: Bool { false } }
@main struct Tests {
    static func main() async {
        let directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let log = directory.appendingPathComponent("adb.\(getuid()).log")
        func socketError(_ target: String, _ reason: String) -> String {
            "E adb : pairing_client.cpp:133 Failed to start pairing connection client [failed to connect to '\(target)': \(reason)]\n"
        }
        try! socketError("127.0.0.1:1", "old error").write(to: log, atomically: true, encoding: .utf8)
        let diagnostics = ADBPairingDiagnostics(environment: ["TMPDIR": directory.path])
        precondition(diagnostics.socketFailure(target: "127.0.0.1:1", code: "123456") == nil,
                     "An old socket failure must not explain a new pairing operation")
        let handle = try! FileHandle(forWritingTo: log)
        try! handle.seekToEnd()
        try! handle.write(contentsOf: Data(("pairing password=123456\n"
            + socketError("127.0.0.1:2", "unrelated error")
            + socketError("127.0.0.1:1", "Connection refused")).utf8))
        try! handle.close()
        precondition(diagnostics.socketFailure(target: "127.0.0.1:1", code: "123456") == "Connection refused",
                     "Only the new target-matched socket reason may be exported")
        precondition(diagnostics.socketFailure(target: "127.0.0.1:3", code: "123456") == nil)
        let redaction = ADBPairingDiagnostics(environment: ["TMPDIR": directory.path])
        let append = try! FileHandle(forWritingTo: log)
        try! append.seekToEnd()
        try! append.write(contentsOf: Data(socketError("127.0.0.1:1", "error 123456").utf8))
        try! append.close()
        precondition(redaction.socketFailure(target: "127.0.0.1:1", code: "123456") == "error <redacted>")
        let rotated = ADBPairingDiagnostics(environment: ["TMPDIR": directory.path])
        try! socketError("127.0.0.1:1", "Operation not permitted").write(to: log, atomically: true, encoding: .utf8)
        precondition(rotated.socketFailure(target: "127.0.0.1:1", code: "123456") == "Operation not permitted")
        print("PASS: Fresh target-matched socket diagnostics, stale/unrelated exclusion, credential redaction, and log rotation")
        let port = Int(CommandLine.arguments[1])!
        func pair(timeout: Double = 1) async -> (Int32, String, String) {
            await ADBPairingResponse.pair(serverPort: port, target: "127.0.0.1:1", code: "123456", timeout: timeout)
        }
        let success = await pair()
        precondition(success.0 == 0 && success.1 == "Successfully paired to 127.0.0.1:1")
        let rejected = await pair()
        precondition(rejected.0 == 1 && rejected.2 == "Failed: Wrong password or connection was dropped.")
        let initialFail = await pair()
        precondition(initialFail.0 == 1 && initialFail.2 == "unknown host service")
        let refusal = await pair()
        precondition(refusal.0 == 1 && refusal.2 == "Failed: Unable to start pairing client.")
        let fakeSuccess = await pair()
        precondition(fakeSuccess.0 != 0, "OKAY must not turn a failure payload into success")
        let malformed = await pair()
        precondition(malformed.0 != 0 && malformed.2.contains("invalid"))
        let truncated = await pair()
        precondition(truncated.0 != 0 && truncated.2.contains("incomplete"))
        let start = Date()
        let timed = await pair(timeout: 0.05)
        precondition(timed.0 != 0 && timed.2.contains("timed out") && Date().timeIntervalSince(start) < 0.5)
        let task = Task { await pair(timeout: 10) }
        try? await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        let cancelled = await task.value
        precondition(cancelled.0 == -999)
        let invalid = await ADBPairingResponse.pair(serverPort: port, target: "127.0.0.1:1", code: "bad:code", timeout: 1)
        precondition(invalid.0 != 0)
        if CommandLine.arguments.count > 2 {
            let real = await ADBPairingResponse.pair(serverPort: Int(CommandLine.arguments[2])!,
                target: "127.0.0.1:1", code: "123456", timeout: 3)
            precondition(real.0 == 1 && real.2 == "Failed: Unable to start pairing client.",
                         "The bundled server's real FAIL response must be decoded")
            print("PASS: Bundled ADB's hidden connection failure is reported correctly")
        }
        print("PASS: Fragmented success/FAIL, initial rejection, malformed/truncated responses, timeout, cancellation, and request validation")
    }
}
''')
    build = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-default-isolation', 'MainActor',
        '-module-cache-path', str(root / 'module-cache'), str(harness),
        str(project / 'AndroidFileSync/Managers/ADBPairingResponse.swift'), '-o', str(root / 'tests')],
        capture_output=True, text=True)
    if build.returncode:
        print(build.stderr)
        raise SystemExit(build.returncode)
    def string(value):
        data = value.encode()
        return f'{len(data):04x}'.encode() + data
    responses = [b'OKAY' + string('Successfully paired to 127.0.0.1:1'),
        b'OKAYFAIL' + string('Failed: Wrong password or connection was dropped.'),
        b'FAIL' + string('unknown host service'),
        b'OKAYFAIL' + string('Failed: Unable to start pairing client.'),
        b'OKAY' + string('Failed: not success'), b'OKAYzzzz', b'OKAY0010short', None, None]
    server = socket.socket()
    server.bind(('127.0.0.1', 0))
    server.listen()
    server.settimeout(5)
    requests = []
    errors = []
    connections = []
    def exact(peer, count):
        result = b''
        while len(result) < count:
            chunk = peer.recv(count - len(result))
            if not chunk: raise ValueError('incomplete request')
            result += chunk
        return result
    def serve():
        try:
            for response in responses:
                peer, _ = server.accept()
                peer.settimeout(2)
                length = int(exact(peer, 4), 16)
                requests.append(exact(peer, length))
                if response is None:
                    connections.append(peer)
                    continue
                with peer:
                    for offset in range(0, len(response), 3):
                        peer.sendall(response[offset:offset + 3])
                        time.sleep(0.001)
        except Exception as error:
            errors.append(error)
    thread = threading.Thread(target=serve)
    thread.start()
    try:
        real = [sys.argv[sys.argv.index('--real-adb') + 1]] if '--real-adb' in sys.argv else []
        subprocess.run([str(root / 'tests'), str(server.getsockname()[1]), *real], check=True, timeout=15)
        thread.join(timeout=1)
        assert not errors, errors
        assert len(requests) == len(responses)
        assert all(request == b'host:pair:123456:127.0.0.1:1' for request in requests)
    finally:
        server.close()
        for peer in connections: peer.close()
        thread.join(timeout=6)
