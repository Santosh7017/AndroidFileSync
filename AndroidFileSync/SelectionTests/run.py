#!/usr/bin/env python3
"""Compile and check production range selection and AppKit keyboard handling."""
from pathlib import Path
import subprocess
import tempfile
import sys
import plistlib
import json

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="afs-selection-tests-", dir="/private/tmp") as temporary:
    build = Path(temporary)
    binary = build / "selection-tests"
    if "--browser" in sys.argv:
        contents = build / "BrowserSelectionTests.app/Contents"
        (contents / "MacOS").mkdir(parents=True)
        binary = contents / "MacOS/BrowserSelectionTests"
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": binary.name, "CFBundleIdentifier": "com.afs.selectiontests",
            "CFBundleName": "BrowserSelectionTests", "CFBundlePackageType": "APPL",
            "NSPrincipalClass": "NSApplication", "LSUIElement": True,
        }))
        products = Path("/private/tmp/afs-selection-build/Build/Products/Debug")
        library = products / "AndroidFileSync.app/Contents/MacOS/AndroidFileSync.debug.dylib"
        compilation = subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
            "-module-cache-path", str(build / "module-cache"), "-I", str(products),
            "-Xcc", "-I/opt/homebrew/include", "-Xlinker", "-rpath", "-Xlinker", str(library.parent),
            str(root / "SelectionTests/BrowserHarness.swift"), str(library), "-o", str(binary),
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        Path("/private/tmp/afs-browser-compile.log").write_text(compilation.stderr)
        if compilation.returncode:
            print("\n".join(line for line in compilation.stderr.splitlines() if ": error:" in line))
            raise SystemExit(compilation.returncode)
        for mode in ("list", "tiles"):
            print("Rendering", mode, flush=True)
            result_path = build / f"{mode}-result.json"
            subprocess.run(["open", "-g", "-n", "-W", str(contents.parent), "--args", mode, str(result_path)],
                           check=True, timeout=30)
            if not result_path.exists():
                raise SystemExit("Rendered browser test exited before verification")
            report = json.loads(result_path.read_text())
            if report.get("passed") is not True:
                print(report)
                raise SystemExit("Rendered browser selection failed")
            print(f"PASS: rendered {mode} clicks, repeated Shift + arrows, drag reversal, and double-click/drag distinction")
        raise SystemExit(0)
    subprocess.run([
        "xcrun", "swiftc", "-swift-version", "5", "-default-isolation", "MainActor",
        "-module-cache-path", str(build / "module-cache"),
        str(root / "AndroidFileSync/Utilities/FileSelectionNavigator.swift"),
        str(root / "AndroidFileSync/Utilities/FileBrowserKeyboardNavigation.swift"),
        str(root / "SelectionTests/Harness.swift"), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
