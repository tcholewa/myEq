# Installation and troubleshooting

## Build from source

Use an Apple Silicon Mac running macOS 27 or later, full Xcode 27 or later, and Python 3. Confirm the selected developer tools:

```sh
xcode-select -p
xcodebuild -version
python3 --version
```

If the developer directory points to standalone Command Line Tools, select the full Xcode installation in **Xcode → Settings → Locations → Command Line Tools**.

From the repository root:

```sh
bash scripts/build-installer.sh
python3 scripts/verify-installer.py
open dist/myEq.pkg
```

The default build uses local ad-hoc signing and does not notarize the app or installer. See [releasing](RELEASING.md) for the separate Developer ID candidate path. The build and verification commands do not install anything or change audio routing.

`bash scripts/build.sh` builds app/driver artifacts without creating an installer. The app is staged at `build/artifacts.noindex/myEq.app`; Xcode products and temporary staging also live under `artifacts.noindex` to keep them out of Spotlight. `dist` contains the current installer. Quit a development preview before rebuilding it; the installed app can remain open during a build.

## Install or upgrade

Quit myEq and playback apps, including Music. Installation requires administrator authorization. Fresh installations and changed driver/bridge identities trigger a Core Audio reload, briefly interrupting all audio, including calls and recordings. Upgrades with unchanged identities skip that reload, but replacing the driver files can still unload the virtual output and require a manual reload. Wait until an audio interruption is acceptable before installing. A full Mac restart is usually unnecessary, but may be needed if Core Audio remains stuck.

The package installs `/Applications/myEq.app`, the output-only driver under `/Library/Audio/Plug-Ins/HAL`, an unprivileged bridge service, the app's recovery helper, and a one-shot maintenance utility. The app, bridge, recovery helper and driver must come from the same package: rebuild and reinstall after updates rather than replacing only the app. Version 0.4 uses IPC protocol 2 and cannot be mixed with previous runtime components. The installer validates the signing hashes used to authenticate the components.

Maintenance validates fixed installation paths, ownership, permissions, ACLs, signatures and the manifest before backing up or invoking recovery. It refuses symbolic links, hard links and unsafe existing installations instead of recursively changing their ownership. An upgrade runs a verified snapshot of the previous recovery helper as the console user. If validation fails, preserve the reported files for investigation; do not repair the failure with a blanket `chown` or `chmod`. A pre-existing app without a valid installation manifest needs manual review/removal before installing.

Open `/Applications/myEq.app`. Allow the recovery helper in **System Settings → General → Login Items & Extensions** if prompted, select your physical output, and enable EQ. Reopen playback apps after installation so they reconnect to Core Audio.

The system output should become `myEq: {physical output name}`. A virtual output and shared memory carry the mixed audio to the app; there is no recording-input stream or process-tap capture fallback. Audio is never saved to disk.

## Troubleshooting

### Audio helpers are not ready

Launch `/Applications/myEq.app` directly after quitting development copies. Xcode's intermediate app does not contain the packaged helper. Development copies show the installed location and leave helper registration/audio activation disabled; `--preview` remains available for UI work.

Check that the background helper is allowed in System Settings, then use **Retry**. Temporary connection failures retry automatically before showing an error. Reinstall the complete current package if components came from different builds.

### Driver installed but not loaded

The installer reloads Core Audio for fresh installations or changed driver/bridge identities. It skips the reload when both identities are unchanged, but macOS can unload the driver during file replacement. This happened in the tested 0.4.3 upgrade: physical outputs remained available while the myEq output disappeared. If the driver is installed but not loaded, quit myEq and audio apps and wait until a system-wide audio interruption is acceptable, then run:

```sh
sudo killall -TERM coreaudiod
```

macOS relaunches the service. Reopen myEq and playback apps afterward. This restored the virtual output in the tested 0.4.3 upgrade without a Mac restart. If output discovery or Music remains stuck after a reload, save your work and restart macOS; repeatedly reloading the service did not resolve the earlier initialization hang. See the [installed upgrade results](VERIFICATION.md#043-installed-upgrade-verification).

### Music skips tracks after installation

Music can retain a stale audio-service connection after Core Audio reloads. Quit Music completely with ⌘Q and reopen it before testing again. The observed cause and fresh-client checks are recorded in [verification](VERIFICATION.md#music-skipping-tracks-after-installation).

### No sound or an unexpected output

Bypass or quit myEq, select your physical speakers/headphones in macOS, and verify ordinary playback. Quit other system equalizers before enabling myEq again. Check the [supported output types](../README.md#output-compatibility); AirPlay, aggregate devices, and surround are excluded.

The recovery helper restores ordinary playback after normal quit/bypass and handles interrupted sessions. Crash recovery and device transitions still have outstanding hardware checks; see [verification](VERIFICATION.md#remaining-hardware-acceptance-checks).

## Remove or roll back

Quit myEq and audio playback apps. Run one of the following from the repository root:

```sh
# Remove myEq and its system components:
sudo bash scripts/uninstall.sh

# Or restore the previous complete package retained by the installer:
sudo bash scripts/rollback.sh
```

After removal or rollback, reload Core Audio with the command above, or restart macOS, to unload/reload the driver. Personal presets under `~/Library/Application Support/myEq` are preserved. Settings version 1 migrates to version 2 without losing presets or the enable preference; version 2 adds the preferred physical output UID. The installer retains rollback bundles in `.noindex` directories so they do not appear as launchable copies in Spotlight.

The scripts require the maintenance utility installed by version 0.4 or later. Their launcher checks the executable and every ancestor for root ownership, safe permissions and absence of ACLs/links before running it. Rollback validates the retained complete package and keeps the current maintenance utility. Uninstall removes the active app, driver and helpers but deliberately retains root-owned recovery snapshots under `/Library/Application Support/myEq`; it does not recursively erase the support directory or user presets. Retained snapshots can contain older executable versions and should be removed by an administrator after recovery is no longer needed.
