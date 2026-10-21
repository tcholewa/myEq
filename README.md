# myEq

A native, local macOS menu bar equalizer for the system stereo output. Eight parametric bands, a response graph, presets, automatic preamp, and stereo-linked peak protection. Target: Apple Silicon, macOS 27+.

## Build and use

Requires Apple Silicon, macOS 27+, and Xcode 27+. No external packages or installed audio driver are needed.

```sh
bash scripts/build.sh
open dist/myEq.app
```

The build script creates a locally ad-hoc-signed app at `dist/myEq.app`. This is a personal-use build, not a notarized distribution. Rebuilds stage and sign a new bundle before moving the previous bundle into `build/package.*/previous-myEq.app`, preserving its executable if it is still running. Quit and reopen myEq to use an update. For launch at login, put the app in a stable location such as `~/Applications` and enable **Launch at Login** from its menu bar menu.

1. Open the app and turn on **Enable EQ**. macOS requests system-audio recording permission; myEq uses this only to process playback. No audio is recorded or uploaded, and no microphone or screen capture is used.
2. Start with **Flat**, or select **Botaniq1** to use the seven reference bands. The eighth slot is disabled until you enable it.
3. Edit numeric fields, drag gain faders, or drag graph points. Each band supports bell, shelves, and 12 dB/octave cuts. Use **Save As** for personal presets and the adjacent menu to save changes, rename, delete, or restore a preset.
4. Closing the editor leaves audio processing running. Use the menu bar icon to reopen it, change presets, bypass, or quit. ⌘E toggles EQ; ⌘0 selects Flat when the editor is active.

The output indicator has independent **L/R meters and dBFS readings**, refreshed at 60 Hz. They measure peaks after EQ and peak protection and retain short transients between display updates. The level bars use immediate attack with a smooth 24 dB/second falloff. Each channel's white peak marker and numeric dBFS reading hold together for one second, then fall slowly at 6 dB/second; a new peak restarts that channel's hold. Bypass clears both meters and peak readings. The shared Guard reading shows stereo-linked limiter activity.

myEq follows the macOS-selected output. When replacing eqMac, quit/bypass eqMac and select your physical output in macOS so the equalizers do not process the signal twice. myEq shows a reminder when the output name contains “eqMac”.

## Audio behavior

Built-in/wired, USB/HDMI stereo, and Bluetooth stereo routes are implemented. Surround, multi-output, AirPlay, and virtual-device routes are outside v1. Unsupported formats leave normal playback in place. Bluetooth headset microphone use suspends the whole EQ and resumes it when stereo playback returns. Source applications explicitly routed to another output are outside the selected system mix.

The app uses a private Core Audio aggregate and a device-scoped tap, excluding its own process. The original stream is muted only while the tap is consumed. Bypass, quit, or a handled startup/runtime error stops the tap and releases its resources. Physical microphone input streams are disabled in the aggregate. macOS output selection, volume, and mute remain under system control.

If audio cannot start, follow the in-app error, allow myEq in **System Settings → Privacy & Security → Screen & System Audio Recording**, then use **Retry**. Privacy authorization may need renewal after rebuilding an ad-hoc-signed app. The app never silently installs a driver or changes system output selection.

## Development and verification

Open `myEq.xcodeproj` and run the **myEq** scheme, or use the build script above for the signed bundle with its generated icon. The project consumes the local Swift package; tests are run with SwiftPM:

```sh
swift test
swift test --sanitize address
swift format lint --strict -r Sources/MyEqCore Sources/MyEqApp Tests
```

`python3 scripts/generate-project.py` regenerates the committed Xcode wrapper after app source files are added or removed. `dist/myEq.app/Contents/MacOS/myEq --diagnose` prints read-only output-device information without enabling processing or saving settings. `--preview` opens Botaniq1 for interface development without capture or persistence.

See [verification results and outstanding hardware checks](docs/VERIFICATION.md) and [architecture](docs/ARCHITECTURE.md). Twenty-one tests pass; the earlier 14-test baseline also passed AddressSanitizer. The user confirmed “Equalizing, and audio plays” on this Mac; device switching, Bluetooth call transitions, long playback, and full UI interaction coverage are not yet verified on hardware.

## Audio design

The C++ core runs eight biquads using the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) formulas, 20 ms transitions, and a 1 ms lookahead sample-peak limiter at −0.5 dBFS. Auto preamp is derived from the combined response, not the largest individual boost. Audio remains stereo. The real-time callback allocates no memory and uses a bounded single-producer/single-consumer parameter queue.

Flat and Botaniq1 are recoverable factory presets. Bell width is in octaves, shelves use slope, and 12 dB/octave cuts use Q. Settings are versioned JSON under `~/Library/Application Support/myEq` and saved atomically. Invalid settings are preserved before resetting.
