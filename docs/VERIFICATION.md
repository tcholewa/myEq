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

## Virtual-output migration (0.2.0)

The process-tap backend has been replaced in source by an output-only AudioServerPlugIn, anonymous shared-memory transport, physical-output renderer, global bridge, and per-user recovery agent. The UI now selects physical outputs and settings migrate from schema 1 to 2. The native driver and helper binaries compile and are locally signed. A local installer, uninstall script, and rollback script are included.

Verified so far:

- **27 Swift tests pass normally and with AddressSanitizer**, including preservation of presets and enable preference during schema-1 migration, output UID round-trip/validation, and the existing DSP/meter tests.
- Native output-only driver property/operation checks pass: no input stream and no ReadInput operation.
- Two distinct XPC mappings share atomic state correctly with page-rounded allocation. Bounded overflow, sanitization, wraparound, and 20,000 concurrently transferred blocks preserve exact stereo ordering.
- Real Apple AUVarispeed → DSP rendering passes at 44.1/48/96/192 kHz, including simulated 0 and ±300 ppm clock drift at 48 kHz, with no underruns/overruns, no crosstalk, finite output, and bounded buffering over 12,000 blocks per case. Planar and reversed stereo outputs pass using the new renderer, with deliberately invalid microphone input ignored. Mismatched output-buffer sizes produce silence and a health fault. These tests are accelerated/offline and do not measure hardware latency.
- Mocked hardware tests verify restoration of separate media/alert defaults, preservation of manual selections, and a usable physical fallback after disconnect.
- The native suite also passes with AddressSanitizer. Audio Unit discovery failed in the restricted sandbox; the successful run used access to the system Audio Unit service.
- The Release app, driver, and helpers build and pass local signature verification. The installer expands successfully: signatures, pinned hashes, driver service declaration, embedded plists, script syntax, and fixed installation locations are verified from its payload. `pkgbuild` emits four `write: Permission denied` diagnostics while still exiting successfully; no missing or damaged signed payload was found during expansion and verification.
- Swift formatting lint and whitespace checks pass. Source inspection finds no process-tap creation/destruction, ScreenCaptureKit, or audio-capture usage description in the shipping sources and resources.

The package was installed successfully on 2026-10-21. Installed app and driver signatures and the 0.2.0 package receipt verify. The global bridge is registered as an unprivileged `nobody` service. An installed-system XPC probe authenticated the bridge and confirmed rejection of a wrong protocol version and unauthorized app, recovery, and driver roles. This probe sends only handshake messages and does not change audio routing; reproduce with `bash scripts/test-native.sh installed-ipc` after installation.

Read-only post-install discovery still lists only the physical outputs; the new driver awaits a manual macOS restart. ADAM Audio D3V remains the default media and system-sound output at 48 kHz. The driver has not yet been exercised through the real HAL host. The earlier tap-backend CPU measurements above do **not** establish its CPU cost. No claim is made yet about absence of indicators, force-quit recovery, latency, or the 2%/6% CPU targets.

## Remaining hardware acceptance checks

These are not reported as passed:

- Restart macOS, allow the recovery agent, and confirm the output-only device loads and valid app/driver/recovery authentication and shared-memory setup succeed. Test update/rollback/uninstall.
- With other capture apps stopped, verify EQ playback without system-audio or microphone permission and without a myEq capture indicator. Confirm two simultaneous playback applications are mixed exactly once.
- Verify close/reopen, minimize/restore, Hide/Unhide, Spaces, and full occlusion: audio continues, visual work stops, and fresh meters return.
- Test volume/mute, preferred stereo channels, Flat/bypass, Botaniq1 edits, and left/right separation on built-in, USB/HDMI, and Bluetooth outputs.
- Test output-menu changes, manual macOS bypass, destination disconnect/fallback, sample-rate/buffer changes, and Bluetooth microphone transitions.
- Independently terminate the app, bridge, recovery agent, and driver host. Verify ordinary playback returns, defaults chosen manually are preserved, and no stale audio is replayed. Include sleep/wake, logout/user switching, and audio-service restart.
- Run 30 minutes of playback/editing. Measure app + driver + helpers together and report Core Audio's incremental CPU separately; target approximately 2% hidden / 6% visible at 48 kHz and 256 frames on this Mac. Measure added wired latency against the under-20-ms target.
- Exercise preset management, fields, graph/faders, persistence, menu bar reopening, and launch at login in the installed app.
