# Verification

## DSP and persistence milestone

`swift test` passed 9 tests on 2026-10-21 with Xcode 27.1 / Apple Silicon.

Verified: flat impulse and stereo separation; bell, shelf, and cut response anchors; overlapping boost compensation; rendered 690 Hz narrow-cut response within 0.03 dB of the plotted response at 44.1/48/96/192 kHz; finite results at parameter extremes; linked limiter ceiling; bounded parameter queue; non-finite input containment; factory preset values; atomic persistence and invalid-file recovery.

## Final automated verification

On 2026-10-21, `swift test` passed **14 tests**, and `swift test --sanitize address` passed the same 14 tests with no AddressSanitizer findings. Added coverage includes planar/interleaved buffer mapping, preferred-channel reversal, ignoring a duplex device's microphone input, dormant-tap silence, changed-layout fault reporting, and suspension policy for Bluetooth calls and unsupported routes.

`bash scripts/build.sh` successfully built and locally signed `dist/myEq.app`. `codesign --verify --strict` passed. `otool -L` showed only Apple system libraries, with no workspace-dependent runtime paths. The ICNS file was readable at 1024 × 1024. Swift formatting lint and `git diff --check` passed.

### Offline processing budget

An optimized C++ benchmark processed 12,000 blocks of 256 stereo frames per sample rate, using all eight bands and repeated parameter changes. All samples stayed finite and bounded, with zero DSP faults.

| Sample rate | Median block time | 99th percentile | 99th percentile / block budget |
|---|---:|---:|---:|
| 44.1 kHz | 6.75 µs | 14.00 µs | 0.24% |
| 48 kHz | 5.50 µs | 9.96 µs | 0.19% |
| 96 kHz | 7.17 µs | 10.00 µs | 0.38% |
| 192 kHz | 9.25 µs | 10.04 µs | 0.75% |

These numbers measure DSP execution only, not total app CPU, hardware latency, scheduling guarantees, or a real-time soak test. Reproduce with:

```sh
mkdir -p build
clang++ -std=c++17 -O3 -I Sources/CDSP/include Sources/CDSP/DSP.cpp scripts/dsp-benchmark.cpp -framework CoreAudio -o build/dsp-benchmark
build/dsp-benchmark
```

## Live check

Read-only output discovery on this Mac reported **ADAM Audio D3V (eqMac), stereo, 48 kHz**, with a supported virtual PCM format. The app did not change the selected output or stop eqMac.

The user subsequently opened the signed app, enabled processing, and explicitly confirmed: **“Equalizing, and audio plays.”** This verifies basic live startup and audible playback on this Mac. The exact output during that user check was not independently re-read.

Computer Use access to myEq was denied without a stated reason. Automated visual inspection, menu interaction, graph dragging, keyboard editing, and preset interaction were therefore not performed. The user confirmation is not treated as full UI test coverage.

## Stereo real-time meter update

On 2026-10-21, `swift test` passed **18 tests** after replacing the combined 4 Hz indicator with independent 60 Hz L/R meters. Four added tests verify stereo transient retention across silent blocks, non-destructive watchdog reads, interval reset after consumption, post-limiter readings, independent fast attack, frame-rate-independent decay, invalid-value handling, and immediate bypass reset. The existing interleaved/planar callback tests also now assert independent channel peaks.

The updated Release app built and passed local signature verification. Swift formatting lint and whitespace checks passed. Packaging staged the signed update and retained the previous app bundle instead of overwriting a potentially running executable. The meter update has automated DSP/display-envelope coverage but has not received a new live visual check; quit and reopen the app to load it.

## Slow peak markers

On 2026-10-21, `swift test` passed **21 tests** with independent peak-hold markers added to the stereo meters. Three added tests verify the one-second hold, 6 dB/second falloff, updates crossing the hold deadline, independent channel retriggering, equivalent timing at 30/60 Hz and after a delayed update, and invalid elapsed-time handling. Existing reset coverage also checks that peak markers clear on bypass and reach the meter floor after sustained silence.

The Release app rebuilt and passed local signature verification; Swift formatting lint and whitespace checks passed. The marker behavior is covered by automated display-envelope tests. A live visual check remains outstanding because Computer Use access to myEq was previously denied. Quit and reopen the packaged app to load the update.

## Peak dBFS readouts

On 2026-10-21, the numeric L/R dBFS readouts and accessibility values were connected directly to the held-peak values used by the white markers. Both now follow the same one-second hold and 6 dB/second decay. The existing **21 tests** passed, the Release app rebuilt and passed local signature verification, and Swift formatting lint and whitespace checks passed. Live visual verification remains outstanding.

## Visibility-based CPU optimization

On 2026-10-21, **25 tests passed** normally and with AddressSanitizer. Added coverage verifies that hidden metering starts disabled, produces no UI deliveries, resumes on show, stops when audio detaches, and discards deliveries already queued on the main thread. DSP tests compare every output sample against an always-metered reference while repeatedly toggling visibility, changing EQ, exercising the limiter, and injecting non-finite input. Audio samples match exactly and health counters continue advancing. Tests also cover hidden peaks, rapid hide/show cycles between callbacks, and the planar hardware callback with metering disabled.

The Release app built and passed local signature verification. Swift formatting lint and whitespace checks passed. The implementation parks the 60 Hz meter timer, skips visual calculations in the audio callback, defers graph work, and avoids unchanged 4 Hz status publications while retaining audio health monitoring. Live window-notification behavior and whole-app CPU/wakeup measurements remain unverified because Computer Use access to myEq was previously denied.

The optimized offline benchmark now runs both metering modes, each with 12,000 blocks of 256 frames, eight filters, and repeated parameter changes. All samples remained finite and bounded with zero faults:

| Sample rate | Metering on median / p99 | Metering off median / p99 |
|---|---:|---:|
| 44.1 kHz | 5.79 / 11.46 µs | 5.54 / 10.00 µs |
| 48 kHz | 5.54 / 10.00 µs | 5.42 / 9.75 µs |
| 96 kHz | 7.12 / 10.08 µs | 6.96 / 9.75 µs |
| 192 kHz | 9.12 / 10.04 µs | 8.96 / 10.17 µs |

This is a single-run DSP measurement, not an end-to-end CPU comparison. It excludes the eliminated timer wakeups, main-thread meter formatting/updates, and graph work, and tail timings include scheduling noise. Reproduce with the benchmark command above.

## Live CPU investigation and native meter renderer

On 2026-10-21, the user prepared the running Release app for profiling, first with the editor open and audio playing, then with the window hidden. The running executable and packaged app had the same UUID (`D49C0C76-32A3-3F0E-A298-B34A88D28DF4`), confirming that this was the visibility-optimized build, not a stale Debug build.

The open-window process read **47.6% CPU**. An eight-second `sample` profile showed extensive SwiftUI/AttributeGraph layout and display work driven by the live meter, while the audio callback was a small part of the sample. No `ResponseGraph` work appeared. The hidden process read **1.3% CPU**, then **1.0% and 1.1%** in successive `top` intervals after sampling ended. Its eight-second profile contained no `OutputMeterMonitor`, `OutputMeterModel`, or `ResponseGraph` frames; the main thread was predominantly waiting. The user's earlier approximately 10% hidden observation was not reproduced in this run. These are process CPU measurements on this Mac, not a controlled end-to-end comparison with eqMac or a guarantee across devices.

Local stack reports are retained in `build/cpu-window-open.txt` and `build/cpu-window-hidden.txt` (ignored build artifacts). Profiling only sampled call stacks; no audio was recorded. A benchmark linked against the actual packaged `DSP.o` also remained well below 1% of the block-time budget at the 99th percentile. Its compiler flags used `-Os`; the excess UI CPU was not caused by an unoptimized C++ Debug build.

The live meter was then replaced with a fixed-size native view and persistent Core Animation layers. Its direct Combine subscription updates layer geometry and changed numeric text, without a SwiftUI `@ObservedObject` or per-frame layout invalidation. At the user's request, meter polling was reduced from 60 to 30 Hz. Peak hold and falloff remain elapsed-time based, with existing tests covering identical behavior at both rates. The DSP and hidden-window gate are unchanged. The existing **25 tests** passed again after the cadence change, the Release app rebuilt and passed local signature verification, and formatting/whitespace checks passed.

After restart into the new executable (UUID `73337BF5-F024-3848-B220-79133F0085A3`), three successive three-second `top` intervals measured **3.2%, 3.7%, and 3.6% CPU**. A subsequent eight-second profile confirmed that both audio processing and live meter updates were active. The main thread spent 5,360 of 5,510 samples waiting in `mach_msg2_trap`; the previous SwiftUI/AttributeGraph layout hotspot was absent. The report is retained locally in `build/cpu-native-meter-30hz.txt`. This measures the combined renderer and cadence change; it does not isolate the benefit of 30 Hz alone. User confirmation of the native meter's appearance and a second hidden-window measurement are pending.

## Remaining hardware acceptance checks

These are not reported as passed:

- Verify close/reopen, minimize/restore, Hide/Unhide, switching Spaces, and fully covering/uncovering the editor during playback. Confirm fresh meters and the latest preset graph on return, continued audio while hidden, and no meter work when opening only the menu bar. Compare whole-app CPU and wakeups in Activity Monitor or Instruments before/after hiding.
- Compare Flat/bypass playback for doubled audio, volume/mute behavior, and stereo separation; then compare Botaniq1 and an audible narrow-band edit.
- Verify built-in speakers, physical USB/HDMI stereo, and Bluetooth stereo individually. The inspected output included an eqMac route, so it is not proof of direct physical-device compatibility.
- Switch outputs while playing; disconnect/reconnect the selected device; change between 44.1/48/96/192 kHz where hardware supports them.
- Enter/leave Bluetooth headset microphone mode; confirm suspension/resumption and test AirPods handoff separately.
- Sleep/wake, quit, and force-quit during playback; verify ordinary playback returns and no private devices remain. Test audio-service restart during a controlled development session.
- Run a 30-minute real-time playback/editing session and measure end-to-end added latency. The design target is under 20 ms on built-in/wired output; only the limiter's 1 ms algorithmic delay and offline DSP runtime are currently established.
- Exercise preset Save As/update/rename/delete, numeric entry, graph dragging, faders, menu bar reopening, relaunch persistence, and launch at login in the native interface.
