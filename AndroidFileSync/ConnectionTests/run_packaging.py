#!/usr/bin/env python3
"""Check the real DMG workflow with simulated build/sign tools; no keys or images."""
from pathlib import Path
import json
import os
import plistlib
import shutil
import subprocess
import tempfile

project = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="afs-package-tests-", dir="/private/tmp") as temporary:
    root = Path(temporary)
    shutil.copy(project / "build-dmg.sh", root / "build-dmg.sh")
    resources = root / "AndroidFileSync/Resources"
    resources.mkdir(parents=True)
    (resources / "adb").write_bytes(b"fixture ADB")
    (root / "AndroidFileSync/AndroidFileSync.entitlements").write_bytes(plistlib.dumps({}))
    (root / "build").mkdir()
    sentinel = root / "build/previous-artifact"
    sentinel.write_text("preserve me")
    commands = root / "commands.jsonl"
    bin_directory = root / "bin"
    bin_directory.mkdir()
    stub = root / "Tool.py"
    stub.write_text(r'''#!/usr/bin/env python3
from pathlib import Path
import hashlib
import json
import os
import plistlib
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ["AFS_PACKAGE_TEST_LOG"]).open("a") as log:
    log.write(json.dumps({"tool": name, "args": args}) + "\n")
if name == "security":
    print(os.environ.get("AFS_PACKAGE_TEST_IDENTITIES", "0 valid identities found"))
elif name == "xcodebuild":
    derived = Path(args[args.index("-derivedDataPath") + 1])
    contents = derived / "Build/Products/Release/AndroidFileSync.app/Contents"
    (contents / "Resources").mkdir(parents=True)
    (contents / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.santosh.AndroidFileSync1"}))
    (contents / "Resources/._adb").write_text("fixture AppleDouble metadata")
elif name == "ditto":
    import shutil
    assert all(flag in args for flag in ("--norsrc", "--noextattr", "--noqtn", "--noacl"))
    source, destination = map(Path, args[-2:])
    assert str(destination).startswith("/private/tmp/afs-package."), "Staging inside Documents can reattach Finder metadata"
    shutil.copytree(source, destination)
elif name == "codesign":
    target = Path(args[-1])
    signature = target / "signature.json" if target.is_dir() else target.with_name(target.name + ".signature.json")
    helper = target / "Contents/Resources/adb" if target.is_dir() else target
    digest = hashlib.sha256(helper.read_bytes()).hexdigest()
    if "--sign" in args:
        assert "--timestamp" in args and "runtime" in args
        identity = args[args.index("--sign") + 1]
        if target.is_dir():
            assert not list(target.rglob("._*")), "AppleDouble metadata survived cleanup"
            helper_signature = helper.with_name(helper.name + ".signature.json")
            assert helper_signature.exists(), "App signed before its helper"
            assert json.loads(helper_signature.read_text())["identity"] == identity
            assert "--entitlements" in args
        signature.write_text(json.dumps({"identity": identity, "digest": digest}))
    elif "--verify" in args:
        assert args[args.index("-R") + 1] == "=anchor apple generic"
        assert json.loads(signature.read_text())["digest"] == digest, "Helper changed after signing"
        if os.environ.get("AFS_PACKAGE_TEST_BAD_SIGNATURE") == "1":
            raise SystemExit(2)
elif name == "hdiutil":
    staging = Path(args[args.index("-srcfolder") + 1])
    assert (staging / "Applications").is_symlink()
    assert (staging / "AndroidFileSync.app/signature.json").exists()
    Path(args[-1]).write_text("simulated signed DMG")
elif name != "xattr":
    raise SystemExit("Unexpected tool " + name)
''')
    stub.chmod(0o755)
    for name in ("security", "xcodebuild", "codesign", "xattr", "hdiutil", "ditto"):
        (bin_directory / name).symlink_to(stub)

    def run(identities="", explicit=None, bad_signature=False):
        commands.write_text("")
        environment = {**os.environ, "PATH": str(bin_directory) + os.pathsep + os.environ["PATH"],
                       "AFS_PACKAGE_TEST_LOG": str(commands), "AFS_PACKAGE_TEST_IDENTITIES": identities,
                       "AFS_PACKAGE_TEST_BAD_SIGNATURE": "1" if bad_signature else "0"}
        environment.pop("AFS_CODESIGN_IDENTITY", None)
        if explicit is not None:
            environment["AFS_CODESIGN_IDENTITY"] = explicit
        result = subprocess.run(["bash", str(root / "build-dmg.sh")], cwd=root.parent,
                                env=environment, text=True, capture_output=True, timeout=10)
        records = [json.loads(line) for line in commands.read_text().splitlines()]
        assert sentinel.read_text() == "preserve me", "Packaging removed an existing artifact"
        builds = [record for record in records if record["tool"] == "xcodebuild"]
        if builds:
            args = builds[0]["args"]
            staging = Path(args[args.index("-derivedDataPath") + 1]).parent
            if result.returncode == 0:
                assert not staging.exists(), "Successful packaging left temporary staging"
            else:
                assert staging.exists(), "Failure discarded the staging needed for diagnosis"
                shutil.rmtree(staging)
        return result, records

    missing, records = run()
    assert missing.returncode != 0 and "Apple-issued" in missing.stdout
    assert all(record["tool"] == "security" for record in records)
    ad_hoc, records = run(explicit="-")
    assert ad_hoc.returncode != 0 and not records

    development = "Apple Development: Fixture (TEAM123)"
    distribution = "Developer ID Application: Fixture (TEAM123)"
    success, records = run(f'1) AAAAA "{development}"\n2) BBBBB "{distribution}"')
    assert success.returncode == 0, success.stdout + success.stderr
    signing = [record for record in records if record["tool"] == "codesign"]
    assert len(signing) == 4
    assert signing[0]["args"][-1].endswith("/Contents/Resources/adb")
    assert signing[1]["args"][-1].endswith("/AndroidFileSync.app")
    assert all(record["args"][record["args"].index("--sign") + 1] == distribution for record in signing[:2])
    assert signing[0]["args"][signing[0]["args"].index("--identifier") + 1] == "com.santosh.AndroidFileSync1.adb"
    assert records[-1]["tool"] == "hdiutil"
    assert "--verify" in signing[2]["args"] and "--verify" in signing[3]["args"]
    app_signing_index = records.index(signing[1])
    assert records[app_signing_index - 1]["tool"] == "xattr", "App wasn't cleaned immediately before signing"

    explicit, records = run(explicit=development)
    assert explicit.returncode == 0, explicit.stdout + explicit.stderr
    assert not any(record["tool"] == "security" for record in records)
    assert all(record["args"][record["args"].index("--sign") + 1] == development
               for record in records if record["tool"] == "codesign" and "--sign" in record["args"])

    failed, records = run(explicit=distribution, bad_signature=True)
    assert failed.returncode != 0 and not any(record["tool"] == "hdiutil" for record in records)
    print("PASS: Certificate selection, unsigned/ad-hoc rejection, helper-before-app signing, Apple-anchor verification, failed-signature stop, and artifact preservation")
