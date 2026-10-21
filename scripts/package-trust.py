#!/usr/bin/env python3
"""Extract verified local signing identities; never trust a client-supplied bundle ID."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path

def cdhash(path):
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)], check=True, capture_output=True, text=True)
    return re.search(r"^CDHash=([0-9a-f]{40})$", result.stderr, re.MULTILINE).group(1)

if sys.argv[1] == "components":
    path = Path(sys.argv[2])
    components = plistlib.loads(path.read_bytes())
    for item in components:
        item["BundleIsRelocatable"] = False
        item["BundleIsVersionChecked"] = False
        item["BundleOverwriteAction"] = "upgrade"
    path.write_bytes(plistlib.dumps(components))
elif sys.argv[1] == "driver":
    destination = Path("build/native/myEq.driver/Contents/Resources/BridgeTrust.plist")
    destination.write_bytes(plistlib.dumps({"bridge": cdhash("build/native/myEqBridge")}))
elif sys.argv[1] == "agent":
    # SMAppService can retain an inferred ad-hoc requirement across upgrades.
    # Publish this build's exact identity in the signed registration plist so
    # launchd receives an explicit, current constraint instead of that cache.
    destination = Path(sys.argv[2])
    agent = plistlib.loads(Path("Resources/com.tc.myEq.recovery.plist").read_bytes())
    agent["SpawnConstraint"] = {
        "signing-identifier": "com.tc.myEq.recovery",
        "cdhash": bytes.fromhex(cdhash(sys.argv[3])),
    }
    destination.write_bytes(plistlib.dumps(agent))
else:
    destination = Path(sys.argv[2])
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(plistlib.dumps({
        "app": cdhash(sys.argv[3]),
        "bridge": cdhash("build/native/myEqBridge"),
        "recovery": cdhash("build/native/myEqRecovery"),
    }))
