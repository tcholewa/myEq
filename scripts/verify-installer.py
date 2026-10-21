#!/usr/bin/env python3
"""Verify the expanded package, including identities used by launchd and XPC."""
import hashlib
import plistlib
import re
import subprocess
import tempfile
from pathlib import Path


def cdhash(path):
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
    result = subprocess.run(
        ["codesign", "-d", "--verbose=4", str(path)],
        check=True, capture_output=True, text=True,
    )
    return re.search(r"^CDHash=([0-9a-f]{40})$", result.stderr, re.M).group(1)


repo = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(
    prefix="verify-installer-", suffix=".noindex", dir=repo / "build/artifacts.noindex"
) as temporary:
    expanded = Path(temporary) / "expanded"
    subprocess.run(["pkgutil", "--expand-full", str(repo / "dist/myEq.pkg"), str(expanded)], check=True)
    component = expanded / "myEq-components.pkg"
    root = component / "Payload"
    app = root / "Applications/myEq.app"
    bridge = root / "Library/Application Support/myEq/myEqBridge"
    recovery = app / "Contents/Helpers/myEqRecovery"
    driver = root / "Library/Audio/Plug-Ins/HAL/myEq.driver"
    trust = plistlib.loads((root / "Library/Application Support/myEq/trust.plist").read_bytes())
    for name, path, original in [
        ("app", app, repo / "build/artifacts.noindex/myEq.app"),
        ("bridge", bridge, repo / "build/native/myEqBridge"),
        ("recovery", recovery, repo / "build/native/myEqRecovery"),
    ]:
        assert cdhash(path) == trust[name] == cdhash(original), name
    assert cdhash(driver) == cdhash(repo / "build/native/myEq.driver")
    assert plistlib.loads((driver / "Contents/Resources/BridgeTrust.plist").read_bytes())["bridge"] == trust["bridge"]

    agent = plistlib.loads((app / "Contents/Library/LaunchAgents/com.tc.myEq.recovery.plist").read_bytes())
    constraint = agent.pop("SpawnConstraint")
    assert constraint == {
        "signing-identifier": "com.tc.myEq.recovery",
        "cdhash": bytes.fromhex(trust["recovery"]),
    }, "launchd must require this package's signed recovery helper"
    assert agent == plistlib.loads((repo / "Resources/com.tc.myEq.recovery.plist").read_bytes())
    assert app / agent["BundleProgram"] == recovery

    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source_info = plistlib.loads((repo / "Resources/Info.plist").read_bytes())
    for key in ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]:
        assert info[key] == source_info[key], key
    assert f'version="{info["CFBundleShortVersionString"]}"' in (component / "PackageInfo").read_text()
    assert (app / "Contents/Resources/AppIcon.icns").read_bytes() == (repo / "build/AppIcon.icns").read_bytes()
    for name in ["preinstall", "postinstall"]:
        assert (component / "Scripts" / name).read_bytes() == (repo / "Installer/scripts" / name).read_bytes()
        subprocess.run(["bash", "-n", str(component / "Scripts" / name)], check=True)

print("PASS: package signatures, XPC identities, recovery spawn constraint, versions, icon, and scripts.")
print("Package SHA-256:", hashlib.sha256((repo / "dist/myEq.pkg").read_bytes()).hexdigest())
