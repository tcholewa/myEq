#!/bin/bash
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ "$(/usr/bin/id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
if /usr/bin/pgrep -x myEq >/dev/null; then echo 'Quit myEq first.' >&2; exit 1; fi
script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
/bin/bash "$script_dir/maintenance.sh" rollback
echo 'Previous verified installation restored. Reload Core Audio with sudo killall -TERM coreaudiod (brief audio interruption), or restart macOS, before enabling EQ.'
