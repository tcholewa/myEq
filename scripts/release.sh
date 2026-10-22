#!/bin/bash
# Produce a signed/notarized candidate. Publishing is a separate, gated action.
set -euo pipefail
cd "$(dirname "$0")/.."
export MYEQ_SIGNING_MODE=production
source scripts/signing.sh
: "${MYEQ_NOTARY_PROFILE:?notarytool keychain profile required}"
notary_args=(--keychain-profile "$MYEQ_NOTARY_PROFILE" --wait --output-format json)
if [ -n "${MYEQ_KEYCHAIN:-}" ]; then notary_args+=(--keychain "$MYEQ_KEYCHAIN"); fi
bash scripts/build-installer.sh
python3 scripts/verify-installer.py --production
xcrun notarytool submit dist/myEq.pkg "${notary_args[@]}" > build/notary-result.json
python3 - <<'PY'
import json
from pathlib import Path
result = json.loads(Path('build/notary-result.json').read_text())
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization did not succeed. Inspect the notarytool log before distributing.')
PY
xcrun stapler staple dist/myEq.pkg
xcrun stapler validate dist/myEq.pkg
/usr/sbin/spctl --assess --type install --verbose dist/myEq.pkg
/usr/bin/shasum -a 256 dist/myEq.pkg > dist/myEq.pkg.sha256
printf 'Notarized candidate: %s/dist/myEq.pkg\nComplete clean-Mac validation before publication.\n' "$PWD"
