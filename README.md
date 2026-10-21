# myEq

A native macOS menu bar equalizer for the mixed system stereo output. Eight parametric bands, presets, automatic preamp, a response graph, and stereo-linked peak protection. Apple Silicon, macOS 27+, Xcode 27+.

## Build and install

```sh
bash scripts/build-installer.sh
open dist/myEq.pkg
```

Quit myEq before installation. The local installer uses administrator authorization to install `/Applications/myEq.app`, the output-only driver under `/Library/Audio/Plug-Ins/HAL`, and a small unprivileged bridge service. Its welcome screen explains that it **reloads Core Audio at the end of installation**, briefly interrupting sound in all apps, including calls and recordings. Install when that interruption is acceptable. This is needed after upgrades too: replacing the driver bundle can unload it even when the executable is unchanged. No full Mac restart is required.

For an older installer, or if the driver still needs loading, reload Core Audio manually:

```sh
sudo killall -TERM coreaudiod
```

macOS relaunches the service. A full macOS restart is an alternative. Then open the installed app and allow its recovery helper in **System Settings → General → Login Items & Extensions** if requested. The build is locally ad-hoc signed; it is not notarized for distribution.

The app, bridge, and driver must come from the same package. Rebuild and reinstall after updates; the installer refreshes the trusted signing hashes. Do not replace just the app with a development build. `bash scripts/build.sh` builds app/driver artifacts without making a package or installing anything. Its app output is `build/artifacts.noindex/myEq.app`; Xcode products and temporary staging also live under `artifacts.noindex` to exclude them from Spotlight. Packaging removes temporary copies on success or failure, and `dist` contains only the current installer. The build scripts never restart Core Audio or reboot.

Launch `/Applications/myEq.app` directly after quitting other copies. Xcode's intermediate app does not contain the packaged helper. Development copies show the installed app's location and leave audio/helper registration disabled; `--preview` remains available for editor work. Quit a development preview before rebuilding it; the installed app can remain open.

This version replaces the process-tap backend with a virtual output and shared memory. It has no recording-input stream, process-tap calls, microphone capture, or network transport. Audio is never saved to disk. Absence of macOS capture prompts/indicators is a hardware acceptance check; see [verification status](docs/VERIFICATION.md).

## Design

Version 0.3.0 introduces a graphite studio interface with warm ivory type, gold controls, and color reserved for the eight bands. The editor groups the response and preamp together, adds filter-shape glyphs and width dials, and keeps stereo levels in a fixed footer. A compact layout fits the normal controls at 1040 × 740; additional notices can scroll. The app icon and menu bar symbol share the same three-fader mark.

## Use

1. Choose your physical speakers or headphones using **Output** in myEq, then enable EQ. myEq redirects the default media and system-sound mix through its virtual output, named **myEq: {physical output name}** in macOS (for example, **myEq: ADAM Audio D3V**). The name follows output changes and returns to **myEq** when no session is attached.
2. Start with **Flat**, or **Botaniq1** for the seven reference bands. The eighth band is initially disabled. Edit numeric fields, faders, or graph points; save personal presets with **Save preset**. Double-click a gain fader or width dial to reset it; exact values remain directly editable. The preset’s **…** menu contains rename, update, restore, and delete actions.
3. Closing or hiding the window keeps audio processing active. The menu bar opens a compact panel with the destination, a static response preview, preset selection, quick Flat/Botaniq1 buttons, bypass, and **Open equalizer**. **Options** contains launch at login and Background Items. ⌘⇧E opens the editor from the panel; ⌘E toggles EQ and ⌘0 selects Flat in the editor.
4. Selecting a physical output in macOS bypasses EQ. If the current destination disconnects, myEq follows an available physical fallback and resumes when supported. It does not automatically switch back when the disconnected device returns.

Volume and mute follow the physical device where supported. Fixed-volume hardware remains fixed-volume; myEq never forces the hardware to full volume or applies the same attenuation twice. Quit eqMac before using myEq to avoid competing virtual-output routing.

The independent L/R output meters refresh at **30 Hz**, retain short transients, and measure after EQ and peak protection. Bars fall at 24 dB/second. White peak markers and their matching dBFS readings hold for one second, then fall together at 6 dB/second. Native layers avoid repeated SwiftUI layout. When the editor is hidden, minimized, closed, or fully occluded, visual polling, DSP peak measurement, and the editor’s response calculations stop. Opening only the menu computes a small static response; it does not enable live metering. When both surfaces are hidden, all visual calculations stop.

Built-in/wired, USB/HDMI, and Bluetooth stereo routes are supported by the implementation. Bluetooth microphone use suspends EQ until stereo playback returns. AirPlay, other virtual devices, aggregates/multi-output, and surround are excluded. The virtual device follows the physical nominal sample rate from 32–192 kHz; unsupported formats remain bypassed. Applications explicitly routed to another device are outside the default mix.

## Recovery and removal

An independent per-user recovery agent owns output routing. It records routing metadata before changes and restores ordinary playback after quit, bypass, helper disconnect, or a stalled app. A bounded driver lease makes the virtual device unavailable if its helpers disappear. Recovery only changes defaults still pointing at myEq; it preserves subsequent manual selections. Recovery timing and crash behavior still need the live acceptance checks documented below.

After quitting myEq:

```sh
sudo bash scripts/uninstall.sh
# Or restore the previous complete installed package:
sudo bash scripts/rollback.sh
```

After either operation, reload Core Audio with the command above, or restart macOS, to unload/reload the driver. Personal presets under `~/Library/Application Support/myEq` are preserved. Settings version 1 migrates to version 2 without losing presets or the enable preference; version 2 adds the preferred physical output UID.

## Development and verification

```sh
swift test
bash scripts/test-native.sh
bash scripts/test-native.sh asan
xcrun swift-format lint --strict -r Sources/MyEqCore Sources/MyEqApp Tests/MyEqCoreTests
bash scripts/render-design.sh
```

The native checks exercise ring concurrency and wraparound, real Apple AUVarispeed rendering, clock drift, output-only driver properties, and recovery with mocked hardware. Audio Unit tests need access to the system Audio Unit service and may not run inside a restricted sandbox.

After installation, `bash scripts/test-native.sh installed-ipc` checks the real bridge's identity and rejection of wrong-version/unauthorized clients. It sends only handshake messages and does not change audio routing.

`render-design.sh` compiles a separate offscreen preview utility against the app views and core library. It writes Retina PNGs for the editor, compact editor, and menu states to `build/artifacts.noindex/design-preview`, and asserts that hidden surfaces do not recalculate their curves. It uses synthetic levels and settings, never captures the screen, and does not enable audio or save preferences. It currently uses Xcode 27’s SwiftPM product layout.

Open `myEq.xcodeproj` for editor development. `--preview` uses Botaniq1 without enabling audio or saving settings. `--diagnose` prints output-device information. See [architecture](docs/ARCHITECTURE.md) and [verification results and outstanding hardware checks](docs/VERIFICATION.md).

The C++ DSP retains eight double-precision biquads, 20 ms parameter transitions, and a 1 ms lookahead limiter at −0.5 dBFS. This is a sample-peak limiter, not oversampled true-peak limiting. Hardware buffering, the shared ring, and clock conversion add latency beyond that 1 ms; the under-20-ms wired target must be measured end to end.
