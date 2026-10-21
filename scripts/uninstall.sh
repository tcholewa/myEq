#!/bin/bash
# Explicitly run with sudo after quitting myEq. Personal presets are preserved.
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then echo 'Run this script with sudo.' >&2; exit 1; fi
if pgrep -x myEq >/dev/null; then echo 'Quit myEq first.' >&2; exit 1; fi
if [ -e /Applications/myEq.app ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Applications/myEq.app/Contents/Info.plist)" != com.tc.myEq ]; then
  echo 'The installed app does not belong to myEq; refusing to remove it.' >&2; exit 1
fi
if [ -e /Library/Audio/Plug-Ins/HAL/myEq.driver ] && [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' /Library/Audio/Plug-Ins/HAL/myEq.driver/Contents/Info.plist)" != com.tc.myEq.driver ]; then
  echo 'The installed driver does not belong to myEq; refusing to remove it.' >&2; exit 1
fi
console_uid=$(stat -f %u /dev/console)
console_user=$(stat -f %Su /dev/console)
if [ "$console_uid" -ge 500 ] && [ -x /Applications/myEq.app/Contents/Helpers/myEqRecovery ]; then
  launchctl asuser "$console_uid" sudo -u "$console_user" /Applications/myEq.app/Contents/Helpers/myEqRecovery --restore
  launchctl bootout "gui/$console_uid/com.tc.myEq.recovery" 2>/dev/null || true
fi
launchctl bootout system/com.tc.myEq.bridge 2>/dev/null || true
# Only remove the exact product paths, never the user's Application Support directory.
rm -rf /Applications/myEq.app /Library/Audio/Plug-Ins/HAL/myEq.driver '/Library/Application Support/myEq'
rm -f /Library/LaunchDaemons/com.tc.myEq.bridge.plist
pkgutil --forget com.tc.myEq.installer >/dev/null || true
echo 'myEq removed; presets preserved. Restart macOS to unload the audio driver.'
