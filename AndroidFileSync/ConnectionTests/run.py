#!/usr/bin/env python3
"""Compile the actual connection sources with isolated in-memory preferences and a fake adb."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parents[1]
sources = project / "AndroidFileSync"
names = [
    "Managers/ADBManager.swift", "Managers/DeviceManager.swift",
    "Managers/AndroidStorageAccess.swift",
    "Managers/ConnectionHealthMonitor.swift", "Managers/USBDeviceMonitor.swift",
    "Managers/WirelessDiscovery.swift", "Models/Models.swift",
    "Managers/PairingMDNSProbe.swift",
    "Managers/PairingNetworkAccess.swift",
    "Managers/QRPairingService.swift",
    "Managers/ADBPairingResponse.swift",
    "Utilities/Shell.swift", "Utilities/CommandProcess.swift",
    "Utilities/AppCodeSigning.swift",
    "Utilities/FileNameHelper.swift", "Utilities/Logger.swift",
]
with tempfile.TemporaryDirectory(prefix="afs-connection-tests-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    inputs = []
    for name in names:
        target = root / Path(name).name
        # Substitute preferences and server availability, so tests never touch app settings or a running daemon.
        text = (sources / name).read_text().replace("UserDefaults.standard", "ConnectionTestDefaults.shared")
        text = text.replace("Shell.isDefaultServerRunning()", 'ConnectionTestDefaults.shared.bool(forKey: "fixtureDefaultServerRunning")')
        text = text.replace("Shell.isADBServerRunning(port:", "ConnectionTests.isFixtureServerRunning(port:")
        text = text.replace('"/usr/bin/dns-sd"', 'ConnectionTests.root.appendingPathComponent("dns-sd").path')
        text = text.replace("PairingMDNSProbe.discover(serviceName: serviceName, knownHosts: knownHosts)",
                            "ConnectionTests.discoverPairing(serviceName: serviceName, knownHosts: knownHosts)")
        text = text.replace("ADBPairingResponse.pair(serverPort:", "ConnectionTests.readPairingResponse(serverPort:")
        text = text.replace("PairingNetworkAccess.check(host:", "ConnectionTests.checkPairingNetworkAccess(host:")
        text = text.replace("ADBPairingDiagnostics(environment: environment)",
                            'ADBPairingDiagnostics(environment: ["TMPDIR": ConnectionTests.root.path])')
        text = text.replace("WirelessReachability.check(target: target, timeout: 0.8)",
                            "ConnectionTests.fixtureReachability(target: target)")
        target.write_text(text)
        inputs.append(str(target))
    # Include the actual discovery model/UI result handler, so network failures
    # cannot silently turn into pairing prompts outside the connection manager.
    browser = (sources / "Views/WirelessConnectView.swift").read_text().split("// MARK: - QR Code Generator", 1)[0]
    browser = browser.replace("UserDefaults.standard", "ConnectionTestDefaults.shared")
    target = root / "ADBPairingBrowser.swift"
    target.write_text(browser)
    inputs.append(str(target))
    shutil.copy(project / "ConnectionTests/FakeADB.py", root / "adb")
    (root / "adb").chmod(0o755)
    # An unresolved peer should exercise the production DNS deadline regardless
    # of whether the sandbox lets the system dns-sd process access Bonjour.
    # Real packet/cache behavior is covered separately by run_discovery.py.
    shutil.copy(project / "ConnectionTests/FakeDNSSD.py", root / "dns-sd")
    (root / "dns-sd").chmod(0o755)
    inputs.append(str(project / "ConnectionTests/Harness.swift"))
    inputs.append(str(project / "ConnectionTests/FileListingTests.swift"))
    compilation = subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(root / "module-cache"), *inputs, "-o", str(root / "connection-tests"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if compilation.returncode:
        print(compilation.stderr)
        raise SystemExit(compilation.returncode)
    subprocess.run([str(root / "connection-tests"), *sys.argv[1:]], check=True, timeout=90)
