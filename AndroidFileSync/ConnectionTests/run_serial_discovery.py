#!/usr/bin/env python3
"""Read-only validation of production serial-to-endpoint lookup on this Mac.

Pass remembered hardware serials as arguments. Preferences and logs are isolated;
the bundled ADB reads service discovery on the app's existing private server.
No pair, connect, disconnect, or shell commands are issued.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sources = project / "AndroidFileSync"
names = [
    "Managers/ADBManager.swift", "Managers/DeviceManager.swift",
    "Managers/ConnectionHealthMonitor.swift", "Managers/USBDeviceMonitor.swift",
    "Managers/WirelessDiscovery.swift", "Models/Models.swift",
    "Managers/PairingMDNSProbe.swift",
    "Managers/QRPairingService.swift", "Utilities/Shell.swift",
    "Utilities/CommandProcess.swift", "Utilities/FileNameHelper.swift", "Utilities/Logger.swift",
]
with tempfile.TemporaryDirectory(prefix="afs-serial-discovery-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    inputs = []
    for name in names:
        target = root / Path(name).name
        target.write_text((sources / name).read_text().replace("UserDefaults.standard", "ConnectionTestDefaults.shared"))
        inputs.append(str(target))
    browser = (sources / "Views/WirelessConnectView.swift").read_text().split("// MARK: - QR Code Generator", 1)[0]
    target = root / "ADBPairingBrowser.swift"
    target.write_text(browser.replace("UserDefaults.standard", "ConnectionTestDefaults.shared"))
    inputs.append(str(target))
    fixture = (project / "ConnectionTests/Harness.swift").read_text().split("@main", 1)[0]
    fixture += r'''
@main struct SerialLookup {
    static func main() async {
        let serials = Set(CommandLine.arguments.dropFirst())
        let result = await ADBManager.discoverWirelessEndpoints(for: serials)
        for endpoint in result.endpoints {
            Swift.print("Resolved \(endpoint.hardwareSerial ?? "unknown"): \(endpoint.target)")
        }
        if result.endpoints.isEmpty { Swift.print("No matching connect service is currently advertised") }
        if !result.error.isEmpty { Swift.print(result.error) }
        WirelessDiscovery.shared.stop()
    }
}
'''
    target = root / "Fixture.swift"
    target.write_text(fixture)
    inputs.append(str(target))
    shutil.copy(sources / "Resources/adb", root / "adb")
    compilation = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(root / "module-cache"), *inputs, "-o", str(root / "serial-lookup"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if compilation.returncode:
        print(compilation.stderr)
        raise SystemExit(compilation.returncode)
    subprocess.run([str(root / "serial-lookup"), *sys.argv[1:]], check=True, timeout=20)
