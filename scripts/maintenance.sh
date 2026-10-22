#!/bin/bash
# Validate the installed executable's entire path before running it as root.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
if [ "$(/usr/bin/id -u)" -ne 0 ]; then echo 'Run maintenance with sudo.' >&2; exit 1; fi
case "${1:-}" in rollback|uninstall) ;; *) echo 'Unknown maintenance operation.' >&2; exit 1 ;; esac
for item in /Library '/Library/Application Support' '/Library/Application Support/myEq' '/Library/Application Support/myEq/myEqMaintenance'; do
  if [ -L "$item" ]; then echo "Unsafe symbolic link: $item" >&2; exit 1; fi
  owner=$(/usr/bin/stat -f '%u' "$item")
  mode=$(/usr/bin/stat -f '%Lp' "$item")
  listing=$(/bin/ls -lde "$item")
  permissions=${listing%% *}
  if [ "$owner" != 0 ] || (( (8#$mode & 0022) != 0 )) || [[ "$permissions" == *+* ]] || [[ "$listing" =~ $'\n'[[:space:]]*[0-9]+: ]]; then
    echo "Unsafe owner, permissions or ACL: $item" >&2; exit 1
  fi
  if [ "$item" != '/Library/Application Support/myEq/myEqMaintenance' ]; then
    [ -d "$item" ] || { echo "Not a directory: $item" >&2; exit 1; }
  else
    [ -f "$item" ] && [ -x "$item" ] && [ "$(/usr/bin/stat -f '%l' "$item")" = 1 ] && (( (8#$mode & 07000) == 0 )) || {
      echo 'Unsafe maintenance executable.' >&2; exit 1;
    }
  fi
done
# Every ancestor is now root-owned and non-writable by others. Unprivileged
# processes cannot substitute the executable between validation and exec.
/usr/bin/codesign --verify --strict '/Library/Application Support/myEq/myEqMaintenance'
exec '/Library/Application Support/myEq/myEqMaintenance' "$1"
