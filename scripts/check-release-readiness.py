#!/usr/bin/env python3
"""Fail closed until a maintainer records real clean-Mac validation of this source."""
import json
import re
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
record = repo / 'docs/release-validation.json'
if not record.is_file():
    raise SystemExit('Release blocked: docs/release-validation.json is missing. Complete the clean-Mac checklist; do not invent results.')
data = json.loads(record.read_text())
commit = data.get('sourceCommit', '')
if not re.fullmatch(r'[0-9a-f]{40}', commit):
    raise SystemExit('Release blocked: a full validated source commit is required.')
subprocess.run(['git', 'merge-base', '--is-ancestor', commit, 'HEAD'], cwd=repo, check=True)
changed = subprocess.check_output(['git', 'diff', '--name-only', commit, 'HEAD'], cwd=repo, text=True).splitlines()
if any(not (name.startswith('docs/') or name in ['README.md', 'SECURITY.md', 'CONTRIBUTING.md']) for name in changed):
    raise SystemExit('Release blocked: implementation changed since clean-Mac validation.')
if subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip():
    raise SystemExit('Release blocked: the checkout is not clean.')
for key in ['testedBy', 'testedAt', 'macOS', 'hardware', 'evidence']:
    if not isinstance(data.get(key), str) or not data[key].strip():
        raise SystemExit(f'Release blocked: missing {key}.')
required = ['cleanInstall', 'upgrade', 'rollback', 'uninstall', 'fastUserSwitch', 'crashRecovery',
            'sleepWake', 'audioMatrix', 'cpuHidden', 'cpuVisible', 'quarantinedDownload']
if any(data.get('checks', {}).get(key) is not True for key in required):
    raise SystemExit('Release blocked: every clean-Mac check must have a recorded pass.')
print('PASS: maintainer-recorded clean-Mac release gate matches the source revision.')
