#!/usr/bin/env python3
"""Verify the expanded package, including identities used by launchd and XPC."""
import argparse
import os
import stat
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


parser = argparse.ArgumentParser()
parser.add_argument('--production', action='store_true')
args = parser.parse_args()
repo = Path(__file__).resolve().parent.parent

def production_signature(path, identifier):
    detail = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], check=True, text=True, capture_output=True).stderr
    team = os.environ.get('MYEQ_TEAM_ID')
    assert team and f'TeamIdentifier={team}' in detail, 'Unexpected developer team'
    assert f'Identifier={identifier}\n' in detail
    assert 'Authority=Developer ID Application:' in detail and 'Timestamp=' in detail and '(runtime)' in detail
    ent = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], check=True, capture_output=True).stdout
    entitlements = plistlib.loads(ent) if ent else {}
    forbidden = ['com.apple.security.get-task-allow', 'com.apple.security.cs.disable-library-validation',
                 'com.apple.security.cs.allow-unsigned-executable-memory', 'com.apple.security.cs.allow-dyld-environment-variables']
    assert not any(entitlements.get(key) for key in forbidden), 'Unsafe production entitlement'

if args.production:
    package_signature = subprocess.run(['pkgutil', '--check-signature', str(repo / 'dist/myEq.pkg')], check=True, text=True, capture_output=True).stdout
    assert 'Developer ID Installer:' in package_signature and f'({os.environ["MYEQ_TEAM_ID"]})' in package_signature

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
    maintenance = root / "Library/Application Support/myEq/myEqMaintenance"
    driver = root / "Library/Audio/Plug-Ins/HAL/myEq.driver"
    trust = plistlib.loads((root / "Library/Application Support/myEq/trust.plist").read_bytes())
    for name, path, original in [
        ("app", app, repo / "build/artifacts.noindex/myEq.app"),
        ("bridge", bridge, repo / "build/native/myEqBridge"),
        ("recovery", recovery, repo / "build/native/myEqRecovery"),
        ("maintenance", maintenance, repo / "build/native/myEqMaintenance"),
    ]:
        assert cdhash(path) == trust[name] == cdhash(original), name
    assert cdhash(driver) == trust['driver'] == cdhash(repo / "build/native/myEq.driver")
    assert cdhash(component / 'Scripts/myEqMaintenance') == trust['maintenance']
    for path in root.rglob('*'):
        mode = path.lstat().st_mode
        assert not path.is_symlink() and (stat.S_ISREG(mode) or stat.S_ISDIR(mode)), path
        assert not mode & 0o7022, ('unsafe package mode', path)
    if args.production:
        for path, identifier in [(app, 'com.tc.myEq'), (driver, 'com.tc.myEq.driver'),
                (bridge, 'com.tc.myEq.bridge'), (recovery, 'com.tc.myEq.recovery'),
                (maintenance, 'com.tc.myEq.maintenance')]:
            production_signature(path, identifier)

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
    for name in ["LICENSE", "THIRD_PARTY_NOTICES.md"]:
        assert (app / "Contents/Resources" / name).read_bytes() == (repo / name).read_bytes(), name
    for name in ["preinstall", "postinstall"]:
        assert (component / "Scripts" / name).read_bytes() == (repo / "Installer/scripts" / name).read_bytes()
        subprocess.run(["bash", "-n", str(component / "Scripts" / name)], check=True)

print("PASS: package signatures, XPC identities, recovery spawn constraint, versions, icon, license notices, and scripts.")
print("Package SHA-256:", hashlib.sha256((repo / "dist/myEq.pkg").read_bytes()).hexdigest())
