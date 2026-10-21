#!/bin/bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
if pgrep -x myEq >/dev/null; then echo 'Quit myEq first.' >&2; exit 1; fi
support='/Library/Application Support/myEq'
backup="$support/previous.noindex"
if [ ! -d "$backup" ]; then backup="$support/previous"; fi
for item in myEq.app myEq.driver myEqBridge trust.plist com.tc.myEq.bridge.plist; do
  if [ ! -e "$backup/$item" ]; then echo 'No complete previous installation is available.' >&2; exit 1; fi
done
console_uid=$(stat -f %u /dev/console)
console_user=$(stat -f %Su /dev/console)
if [ "$console_uid" -ge 500 ]; then
  launchctl asuser "$console_uid" sudo -u "$console_user" /Applications/myEq.app/Contents/Helpers/myEqRecovery --restore
  launchctl bootout "gui/$console_uid/com.tc.myEq.recovery" 2>/dev/null || true
fi
launchctl bootout system/com.tc.myEq.bridge 2>/dev/null || true
mkdir -p "$support/rollback.noindex"
stage=$(mktemp -d "$support/rollback.noindex/run.XXXXXX")
ditto "$backup/myEq.app" "$stage/myEq.app"
ditto "$backup/myEq.driver" "$stage/myEq.driver"
codesign --verify --strict "$stage/myEq.app"
codesign --verify --strict "$stage/myEq.driver"
mv /Applications/myEq.app "$stage/replaced-myEq.app"
mv /Library/Audio/Plug-Ins/HAL/myEq.driver "$stage/replaced-myEq.driver"
mv "$stage/myEq.app" /Applications/myEq.app
mv "$stage/myEq.driver" /Library/Audio/Plug-Ins/HAL/myEq.driver
cp "$backup/myEqBridge" "$backup/trust.plist" "$support/"
cp "$backup/com.tc.myEq.bridge.plist" /Library/LaunchDaemons/
codesign --verify --strict /Applications/myEq.app
codesign --verify --strict /Library/Audio/Plug-Ins/HAL/myEq.driver
launchctl bootstrap system /Library/LaunchDaemons/com.tc.myEq.bridge.plist
echo 'Previous myEq package restored. Reload Core Audio with sudo killall -TERM coreaudiod (brief audio interruption), or restart macOS, before enabling EQ.'
