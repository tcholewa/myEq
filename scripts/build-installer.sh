#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/signing.sh
bash scripts/build.sh
stage=$(mktemp -d build/artifacts.noindex/installer.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app=build/artifacts.noindex/myEq.app
root="$stage/root"
mkdir -p "$root/Applications" "$root/Library/Audio/Plug-Ins/HAL" "$root/Library/LaunchDaemons" "$root/Library/Application Support/myEq" "$stage/scripts"
ditto "$app" "$root/Applications/myEq.app"
ditto build/native/myEq.driver "$root/Library/Audio/Plug-Ins/HAL/myEq.driver"
cp build/native/myEqBridge build/native/myEqMaintenance "$root/Library/Application Support/myEq/"
cp Installer/com.tc.myEq.bridge.plist "$root/Library/LaunchDaemons/"
python3 scripts/package-trust.py installer "$root/Library/Application Support/myEq/trust.plist" "$app"
cp Installer/scripts/preinstall Installer/scripts/postinstall build/native/myEqMaintenance "$stage/scripts/"
chmod 755 "$stage/scripts/preinstall" "$stage/scripts/postinstall"
pkgbuild --analyze --root "$root" "$stage/components.plist"
python3 scripts/package-trust.py components "$stage/components.plist"
pkgbuild --root "$root" --component-plist "$stage/components.plist" --scripts "$stage/scripts" --identifier com.tc.myEq.installer --version 0.4.0 --install-location / "$stage/myEq-components.pkg"
installer_signing=()
if [ "$MYEQ_SIGNING_MODE" = production ]; then installer_signing=(--sign "$MYEQ_INSTALLER_IDENTITY" --timestamp); fi
productbuild "${installer_signing[@]}" --distribution Installer/Distribution.xml --resources Installer/Resources --package-path "$stage" "$stage/myEq.pkg"
mv "$stage/myEq.pkg" dist/myEq.pkg
printf 'Installer: %s/dist/myEq.pkg\n' "$PWD"
