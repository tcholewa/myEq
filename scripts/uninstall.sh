#!/bin/bash
# Explicitly run with sudo after quitting myEq. Personal presets are preserved.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ "$(/usr/bin/id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
if /usr/bin/pgrep -x myEq >/dev/null; then echo 'Quit myEq first.' >&2; exit 1; fi
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
/bin/bash "$script_dir/maintenance.sh" uninstall
/usr/sbin/pkgutil --forget com.tc.myEq.installer >/dev/null || true
echo 'myEq removed; presets and root-owned recovery snapshots preserved. Reload Core Audio with sudo killall -TERM coreaudiod (brief audio interruption), or restart macOS, to unload the audio driver.'
