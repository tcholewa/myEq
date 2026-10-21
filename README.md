# myEq

A native macOS menu bar equalizer for the mixed system stereo output. Eight parametric bands, presets, automatic preamp, a response graph, and stereo-linked peak protection. Apple Silicon, macOS 27+, Xcode 27+.

## Build and install

```sh
bash scripts/build-installer.sh
open dist/myEq.pkg
```

Quit myEq before installation. The local installer uses administrator authorization to install `/Applications/myEq.app`, the output-only driver under `/Library/Audio/Plug-Ins/HAL`, and a small unprivileged bridge service. Reload Core Audio to load the new driver without rebooting:

```sh
sudo killall -TERM coreaudiod
```

This briefly interrupts all system audio, including calls and recordings; run it when an interruption is acceptable. macOS relaunches the service. A full macOS restart is an alternative. Then open the installed app and allow its recovery helper in **System Settings → General → Login Items & Extensions** if requested. The build is locally ad-hoc signed; it is not notarized for distribution.

The app, bridge, and driver must come from the same package. Rebuild and reinstall after updates; the installer refreshes the trusted signing hashes. Do not replace just the app with a development build. `bash scripts/build.sh` builds app/driver artifacts without making a package or installing anything. The build scripts never restart Core Audio or reboot.

This version replaces the process-tap backend with a virtual output and shared memory. It has no recording-input stream, process-tap calls, microphone capture, or network transport. Audio is never saved to disk. Absence of macOS capture prompts/indicators is a hardware acceptance check; see [verification status](docs/VERIFICATION.md).

## Use

1. Choose your physical speakers or headphones using **Output** in myEq, then enable EQ. myEq redirects the default media and system-sound mix through its virtual output.
2. Start with **Flat**, or **Botaniq1** for the seven reference bands. The eighth band is initially disabled. Edit numeric fields, faders, or graph points; save personal presets with **Save As**.
3. Closing or hiding the window keeps audio processing active. The menu bar provides output selection, presets, bypass, and quit. ⌘E toggles EQ; ⌘0 selects Flat in the editor.
4. Selecting a physical output in macOS bypasses EQ. If the current destination disconnects, myEq follows an available physical fallback and resumes when supported. It does not automatically switch back when the disconnected device returns.

Volume and mute follow the physical device where supported. Fixed-volume hardware remains fixed-volume; myEq never forces the hardware to full volume or applies the same attenuation twice. Quit eqMac before using myEq to avoid competing virtual-output routing.

The independent L/R output meters refresh at **30 Hz**, retain short transients, and measure after EQ and peak protection. Bars fall at 24 dB/second. White peak markers and their matching dBFS readings hold for one second, then fall together at 6 dB/second. Native layers avoid repeated SwiftUI layout. When the editor is hidden, minimized, closed, or fully occluded, visual polling, DSP peak measurement, and response calculations stop.

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
```

The native checks exercise ring concurrency and wraparound, real Apple AUVarispeed rendering, clock drift, output-only driver properties, and recovery with mocked hardware. Audio Unit tests need access to the system Audio Unit service and may not run inside a restricted sandbox.

After installation, `bash scripts/test-native.sh installed-ipc` checks the real bridge's identity and rejection of wrong-version/unauthorized clients. It sends only handshake messages and does not change audio routing.

Open `myEq.xcodeproj` for editor development. `--preview` uses Botaniq1 without enabling audio or saving settings. `--diagnose` prints output-device information. See [architecture](docs/ARCHITECTURE.md) and [verification results and outstanding hardware checks](docs/VERIFICATION.md).

The C++ DSP retains eight double-precision biquads, 20 ms parameter transitions, and a 1 ms lookahead limiter at −0.5 dBFS. This is a sample-peak limiter, not oversampled true-peak limiting. Hardware buffering, the shared ring, and clock conversion add latency beyond that 1 ms; the under-20-ms wired target must be measured end to end.
