#!/usr/bin/env python3
"""Exercise the production quit delegate inside AppKit's real termination loop.

Uses no windows, real ADB servers, phones, app preferences, or app log files.
"""
from pathlib import Path
import json
import os
import signal
import subprocess
import tempfile
import time

sources = Path(__file__).resolve().parents[1] / "AndroidFileSync"
with tempfile.TemporaryDirectory(prefix="afs-quit-tests-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    app = (sources / "AndroidFileSyncApp.swift").read_text()
    delegate = app.split("class AppDelegate:", 1)[1].split("struct ConnectionBadge:", 1)[0]
    # Inject a stalled cleanup to exercise the overall deadline independently of
    # individual command timeouts. Normal and hung-ADB modes use the source as-is.
    delegate = delegate.replace("guard !adbPath.isEmpty else { return }", '''
        if ProcessInfo.processInfo.environment["AFS_QUIT_TEST_MODE"] == "deadline" {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        guard !adbPath.isEmpty else { return }
    ''')
    (root / "AppDelegate.swift").write_text(
        "import AppKit\nclass AppDelegate:" + delegate.replace("UserDefaults.standard", "QuitDefaults.shared")
    )
    (root / "Fixture.swift").write_text(r'''
import AppKit

extension Notification.Name {
    static let afsDeleteShortcut = Notification.Name("afsDeleteShortcut")
    static let afsPermanentDeleteShortcut = Notification.Name("afsPermanentDeleteShortcut")
}
final class DropCoordinator {}
final class QuitDefaults {
    static let shared = QuitDefaults()
    func object(forKey key: String) -> Any? {
        key == "showQuitDebuggingReminder" ? false : true
    }
    func set(_ value: Any, forKey key: String) {}
}
enum AppLogger {
    enum Level { case info, warning }
    nonisolated static func log(_ text: String, level: Level = .info) {
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let url = root.appendingPathComponent("trace.log")
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (old + text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    static func addSessionSeparator() {}
}
final class DeviceManager {
    private(set) var stopped = false
    func stopMonitoring() { stopped = true }
}
final class DownloadManager { func cancelAllDownloads() {} }
final class UploadManager { func cancelAllUploads() {} }
final class WirelessDiscovery {
    static let shared = WirelessDiscovery()
    func stop() {}
}
enum ADBManager {
    static func appManagedWirelessCleanupTargets() -> [String: Int] { ["fixture:1234": 5037] }
    static func getADBPath() -> String {
        URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("adb").path
    }
}
final class QuitDelegate: AppDelegate {
    let child = Process()
    let devices = DeviceManager()
    override func applicationDidFinishLaunching(_ notification: Notification) {
        deviceManager = devices
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["60"]
        try! AppProcessLifecycle.run(child)
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        try! String(child.processIdentifier).write(to: root.appendingPathComponent("child.pid"), atomically: true, encoding: .utf8)
        DispatchQueue.main.async {
            AppLogger.log("Requesting quit")
            NSApp.terminate(nil)
        }
    }
    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLogger.log("Entered quit delegate")
        let reply = super.applicationShouldTerminate(sender)
        AppLogger.log("Quit delegate returned \(reply.rawValue)")
        return reply
    }
    override func applicationWillTerminate(_ notification: Notification) {
        super.applicationWillTerminate(notification)
        let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let result = ["childStopped": !child.isRunning, "monitorStopped": devices.stopped]
        try! JSONSerialization.data(withJSONObject: result).write(to: root.appendingPathComponent("result.json"))
    }
}
@main struct QuitFixture {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let delegate = QuitDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
''')
    (root / "adb").write_text('''#!/usr/bin/python3
import json, os, pathlib, sys, time
root = pathlib.Path(__file__).parent
with (root / "commands.jsonl").open("a") as file:
    file.write(json.dumps({"args": sys.argv[1:], "pid": os.getpid(),
                          "port": os.environ.get("ANDROID_ADB_SERVER_PORT")}) + "\\n")
if os.environ.get("AFS_QUIT_TEST_MODE") == "hung":
    time.sleep(60)
''')
    (root / "adb").chmod(0o755)
    compilation = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(root / "module-cache"), str(root / "AppDelegate.swift"),
        str(root / "Fixture.swift"), str(sources / "Utilities/Shell.swift"),
        str(sources / "Utilities/CommandProcess.swift"), "-o", str(root / "quit-tests"),
        str(sources / "Utilities/AppCodeSigning.swift"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if compilation.returncode:
        print(compilation.stderr)
        raise SystemExit(compilation.returncode)
    for mode in ("normal", "hung", "deadline"):
        for name in ("child.pid", "result.json", "commands.jsonl", "trace.log"):
            (root / name).unlink(missing_ok=True)
        started = time.monotonic()
        try:
            subprocess.run([str(root / "quit-tests")],
                env={**os.environ, "AFS_QUIT_TEST_MODE": mode}, check=True, timeout=8,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            result = json.loads((root / "result.json").read_text())
            assert result["childStopped"] and result["monitorStopped"], result
            if mode == "deadline":
                assert "exceeded its deadline" in (root / "trace.log").read_text()
                assert time.monotonic() - started < 6
            else:
                commands = [json.loads(line) for line in (root / "commands.jsonl").read_text().splitlines()]
                assert any(command["args"] == ["disconnect", "fixture:1234"] and command["port"] == "5037"
                           for command in commands), commands
                kills = [command for command in commands if command["args"] == ["kill-server"]]
                assert kills and all(command["port"] == "56037" for command in kills), commands
            print(f"PASS: AppKit quit with {mode} ADB in {time.monotonic() - started:.2f}s", flush=True)
        except subprocess.TimeoutExpired:
            print("Quit timed out; fixture files:", sorted(path.name for path in root.iterdir()), flush=True)
            if (root / "trace.log").exists():
                print((root / "trace.log").read_text(), flush=True)
            raise
        finally:
            pids = []
            if (root / "child.pid").exists():
                pids.append(int((root / "child.pid").read_text()))
            if (root / "commands.jsonl").exists():
                pids.extend(json.loads(line)["pid"] for line in (root / "commands.jsonl").read_text().splitlines())
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
