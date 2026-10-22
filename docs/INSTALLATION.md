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

The build uses local ad-hoc signing and does not notarize the app or installer. The build and verification commands do not install anything or change audio routing.

`bash scripts/build.sh` builds app/driver artifacts without creating an installer. The app is staged at `build/artifacts.noindex/myEq.app`; Xcode products and temporary staging also live under `artifacts.noindex` to keep them out of Spotlight. `dist` contains the current installer. Quit a development preview before rebuilding it; the installed app can remain open during a build.

## Install or upgrade

Quit myEq and playback apps, including Music. Installation requires administrator authorization and briefly interrupts all audio by reloading Core Audio, including calls and recordings. Wait until that interruption is acceptable, then run the installer. A full Mac restart is not required.

The package installs `/Applications/myEq.app`, the output-only driver under `/Library/Audio/Plug-Ins/HAL`, an unprivileged bridge service, and the app's recovery helper. The app, bridge, and driver must come from the same package: rebuild and reinstall after updates rather than replacing only the app. The installer refreshes the signing hashes used to authenticate the components.

Open `/Applications/myEq.app`. Allow the recovery helper in **System Settings → General → Login Items & Extensions** if prompted, select your physical output, and enable EQ. Reopen playback apps after installation so they reconnect to Core Audio.

The system output should become `myEq: {physical output name}`. A virtual output and shared memory carry the mixed audio to the app; there is no recording-input stream or process-tap capture fallback. Audio is never saved to disk.

## Troubleshooting

### Audio helpers are not ready

Launch `/Applications/myEq.app` directly after quitting development copies. Xcode's intermediate app does not contain the packaged helper. Development copies show the installed location and leave helper registration/audio activation disabled; `--preview` remains available for UI work.

Check that the background helper is allowed in System Settings, then use **Retry**. Temporary connection failures retry automatically before showing an error. Reinstall the complete current package if components came from different builds.

### Driver installed but not loaded

The current installer reloads Core Audio automatically. For an older package or a driver that still has not loaded, first quit audio apps and wait until a system-wide audio interruption is acceptable, then run:

```sh
sudo killall -TERM coreaudiod
```

macOS relaunches the service. Reopen playback apps afterward and retry myEq. Restarting macOS is an alternative.

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
