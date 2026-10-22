#!/usr/bin/env python3
"""Run Clang analysis on native trust boundaries; never start audio services."""
import subprocess
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
files = ['Helpers/Bridge.mm', 'Helpers/Recovery.mm', 'Driver/Driver.mm',
         'Sources/CTransport/Client.mm', 'Sources/CDSP/DSP.cpp', 'Installer/Tools/Maintenance.mm']
for path in files:
    command = ['xcrun', 'clang++', '--analyze', '-std=c++17', '-arch', 'arm64',
               '-mmacosx-version-min=27.0', '-fblocks', '-I', 'Sources/CTransport',
               '-I', 'Sources/CDSP/include', '-Xanalyzer', '-analyzer-output=text', '-o', '/dev/null']
    if path.endswith('.mm'):
        command.append('-fobjc-arc')
    result = subprocess.run(command + [path], cwd=repo, capture_output=True, text=True, timeout=60)
    if result.returncode or 'warning:' in result.stderr:
        raise SystemExit(f'{path}:\n{result.stderr}')
print('PASS: Clang static analysis of native runtime and maintenance code.')
