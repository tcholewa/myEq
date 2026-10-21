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

Initial post-install discovery listed only physical outputs. On 2026-10-21, an administrator-authorized `killall -TERM coreaudiod` reloaded Core Audio without rebooting macOS. Subsequent `system_profiler SPAudioDataType -json` discovery enumerated **myEq**, with two output channels, virtual transport, and a 48 kHz sample rate. ADAM Audio D3V remained the default media and system-sound output. This verifies driver loading and enumeration through the real HAL host; it does not yet verify the active audio path. The earlier tap-backend CPU measurements above do **not** establish its CPU cost. No claim is made yet about absence of indicators, force-quit recovery, latency, or the 2%/6% CPU targets.

The subsequent “Audio helpers are not ready” report was traced to a running intermediate build at `build/Build/Products/Release/myEq.app`, confirmed by its process path and background-service logs. That copy lacks the packaged LaunchAgent; its recovery XPC lookup failed with “No such process”. The installed bundle contains the helper and its plist. An app startup guard now reports the correct installed path, disables audio/helper/login-item registration outside `/Applications/myEq.app`, and preserves editor preview mode. The guard compiles with `swift build`; Swift formatting lint and whitespace checks pass. Switching to the installed app still requires a live playback confirmation.

On 2026-10-21, 21 obsolete generated app bundles were removed and their Launch Services registrations cleared. The installed app, user settings, source files, and current installer were preserved. A fresh build with the revised scripts stores app products under `build/artifacts.noindex`, cleans packaging/installer staging directories automatically, and publishes only the installer in `dist`. Expanded-package signatures, pinned hashes, installation paths, shell syntax, and whitespace checks pass. After the fresh build, Spotlight and Launch Services each report only `/Applications/myEq.app`. The installed app's helper-startup error remains under investigation separately.

The installed app then reproduced the helper error. Logs showed `SMAppService` status 3 (`notFound`) for the bundled recovery agent, with no registration attempt. Startup had only registered status `notRegistered`. The app now registers either initial state after checking that the bundled helper/plist exist, preserves `requiresApproval`, and repeats setup from both Retry actions. Registration failures include the actual error domain/code instead of being hidden behind an XPC connection error. The Release installer builds and its expanded signatures/pinned identities verify; Swift formatting and whitespace checks pass. The update was installed successfully and the installed app/helpers match the new trust manifest. Driver, bridge, and recovery-helper code hashes were unchanged. The initial assumption that this avoided a Core Audio reload proved incorrect: replacing the driver bundle unloaded its host, as described below.

The upgrade's retained rollback copy also appeared in Spotlight. Its directory was renamed to `previous.noindex`, preserving its contents, and future installer/rollback backups now use excluded directories. The rollback script accepts both the new location and legacy installations. No personal settings were removed.

## Driver reload after upgrade

On 2026-10-21, the updated installed app's recovery agent was running under ServiceManagement, confirming that the registration fix took effect. Core Audio logs show the myEq driver being destroyed and device `com.tc.myEq.output` deactivated at 22:56:18 during the preceding package upgrade. Subsequent audio discovery contained only physical outputs, even though the signed driver was installed.

An administrator-authorized Core Audio-only reload at 23:08:42 restored the driver without rebooting macOS. The existing app connected to the recovery agent and bridge with the pinned signing requirements. Audio discovery then listed myEq as the default media and system-sound output, with stereo channels at 48 kHz; the driver host and both helpers were running. This establishes that routing activation succeeded, which requires the physical renderer to start. Audible playback, sustained rendering, and absence of indicators still require user confirmation.

The installer now packages a welcome screen explaining its audio interruption and reloads Core Audio after verifying the installed app/driver and starting the bridge. It refuses non-startup-disk targets before touching services. The app's unloaded-driver message and rollback/uninstall instructions also present Core Audio reload as an alternative to a full restart.

The revised Release app and product installer build successfully. Expanded payload signatures, app/bridge/recovery pinned hashes, the driver's bridge identity, exact packaged scripts, and the bundled interruption notice all verify. Both install scripts reject an alternate target before invoking system operations. Installer resolves the selected component for the startup disk and reports restart action `None`. Shell/XML syntax, Swift formatting, and whitespace checks pass. The revised package is staged at `dist/myEq.pkg`; it has not been installed over the now-active app, so its full upgrade/postinstall path still needs a live run. The same Core Audio reload operation has already succeeded manually on this Mac.

The user subsequently reported “perfect” after the no-reboot driver reload and requested destination names for the virtual output. This is positive feedback on the restored setup; it does not establish the remaining CPU, indicator, or crash-recovery checks.

## Virtual output destination name

The virtual device now receives the selected physical output’s name through the existing transport-open/attach control messages and publishes `myEq: {original name}`. The change applies only after accepted driver reconfiguration, follows session/output changes, and resets to `myEq` on detach. Tests exercise HAL property reads and synchronous name notifications, unchanged-name suppression, Unicode, rejected/aborted configurations, detach, and stable UID/manufacturer/stream properties.

The native driver, recovery, transport, and rendering suite passes. The driver tests also pass with AddressSanitizer. The Release app and installer build; expanded app/driver/helper signatures and all pinned hashes match the build artifacts, and the package contains the Core Audio reload script. Swift formatting and whitespace checks pass.

The naming package was installed successfully after the user closed myEq. Its postinstall reloaded Core Audio automatically: the new driver host appeared without a separate reload or reboot, and ordinary output remained ADAM Audio D3V while the app was closed. Installed signatures and pinned identities matched the verified artifacts, and Spotlight still listed only `/Applications/myEq.app`. Reopening exposed a separate upgrade issue: `launchctl` had no recovery job, but the app's existing ServiceManagement registration prevented first-install registration from running. The app could therefore not attach a named session yet.

The installer now writes a fresh installation UUID to its trust manifest. On first launch after each install, the app refreshes an existing approved registration through awaited unregister/register, remembers the successful UUID per user, and gates audio on readiness. User-disabled services still require approval. This also handles reinstalling the same package; a build-only version stamp would not.

This follow-up builds and passes formatting/whitespace checks. Expanded-package verification confirms the UUID insertion preserves every signing hash. Installation succeeded, with installed app/driver/helper signatures matching the verified build and a valid fresh installation UUID present. Core Audio loaded the replacement driver automatically. The app was closed during these checks; live registration refresh and the visible destination name await reopening it.

## Studio redesign (0.3.0)

On 2026-10-22, the editor, menu bar panel, and app icon were redesigned together. The editor now has a graphite/ivory/gold palette, grouped response/preamp controls, eight color-coded strips with filter glyphs and width dials, and a fixed stereo-meter footer. The menu bar opens a 354-point panel with output choice, preset selection and quick presets, a static combined-response preview, preamp/sample-rate information, bypass, editor access, Options, and Quit. The smaller editor layout reduces graph/fader height and spacing to expose every normal control at 1040 × 740.

Verification completed:

- All **27 Swift tests pass**, covering DSP, stereo metering, hidden-state delivery invalidation, presets, and routing logic. Audio/DSP/transport behavior was not changed by this redesign.
- `bash scripts/render-design.sh` compiles and renders six Retina fixtures: editor at 1180 × 900, compact editor at 1040 × 740, and menu states for enabled, bypassed, attention required, and long names. The layouts and generated icon were visually inspected. Native menu label adaptation initially dropped multi-line content; regular SwiftUI buttons with anchored native menus now preserve the device/preset labels and filter glyphs.
- The same utility asserts that edits while both surfaces are hidden leave all cached curves unchanged, opening only the menu calculates its 128-point preview without refreshing the editor curves, and reopening the editor refreshes its eight curves. The menu adds no animation timer and never enables DSP metering. The existing 30 Hz native level meter remains separate from SwiftUI layout.
- The Release app and 0.3.0 installer build. Expanded payload signatures, app/bridge/recovery trust hashes, driver bridge identity, version, generated icon, and exact installation scripts match the build artifacts. Swift formatting, shell syntax, and whitespace checks pass. The known nonfatal `pkgbuild` write diagnostics were followed by successful payload verification.

These are source-rendered fixtures in never-shown windows, using synthetic settings/levels and no audio route. They do not establish live menu interaction, keyboard/VoiceOver behavior, traffic-light/title-bar placement, or actual CPU use. Computer Use access to myEq was previously denied, so those interactions require a user-assisted check. No live CPU improvement is claimed from the visual redesign.

The 0.3.0 package was installed successfully on 2026-10-22 while myEq was closed. The receipt reports version 0.3.0; installed app/driver/helper signatures and trust identities match the verified package, with a fresh installation UUID. Core Audio automatically loaded the replacement driver, enumerating a stereo 48 kHz myEq device while ordinary playback remained routed to ADAM Audio D3V. The source changes are committed as `c9e8bc3`. A user-assisted live check of the new output/preset menus, editor shortcut, and playback has been requested and is pending.

## Remaining hardware acceptance checks

These are not reported as passed:

- Test first launch from a clean installation and the revised installer’s complete upgrade/reload path, plus rollback/uninstall. Existing-installation helper registration, authenticated connections, and route activation have succeeded.
- With other capture apps stopped, verify EQ playback without system-audio or microphone permission and without a myEq capture indicator. Confirm two simultaneous playback applications are mixed exactly once.
- Verify close/reopen, minimize/restore, Hide/Unhide, Spaces, and full occlusion: audio continues, visual work stops, and fresh meters return.
- Test volume/mute, preferred stereo channels, Flat/bypass, Botaniq1 edits, and left/right separation on built-in, USB/HDMI, and Bluetooth outputs.
- Test output-menu changes, manual macOS bypass, destination disconnect/fallback, sample-rate/buffer changes, and Bluetooth microphone transitions.
- Independently terminate the app, bridge, recovery agent, and driver host. Verify ordinary playback returns, defaults chosen manually are preserved, and no stale audio is replayed. Include sleep/wake, logout/user switching, and audio-service restart.
- Run 30 minutes of playback/editing. Measure app + driver + helpers together and report Core Audio's incremental CPU separately; target approximately 2% hidden / 6% visible at 48 kHz and 256 frames on this Mac. Measure added wired latency against the under-20-ms target.
- Exercise preset management, fields, graph/faders, persistence, menu bar reopening, and launch at login in the installed app.
