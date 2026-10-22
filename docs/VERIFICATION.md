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

## Helper startup and band selection fixes (0.3.1)

The user reported helper errors after first launch and after bypass/re-enable, cleared by Retry. Recent system logs show repeated helper reconnections and an interrupted bridge connection during a bridge restart. The old engine latched every startup failure until explicit Retry; helper registration also issued separate configure/retry operations. Separately, recovery restore, app close, and disconnect cleanup could each send driver detach even after the transport had already been revoked. These are confirmed code paths; the logs do not identify every individual failed enable attempt’s original error.

Temporary startup failures now retain their classification and detailed service error through XPC and the C/Swift boundary. The engine stays in Starting and permits four delayed reconnection attempts on its existing control tick. Explicit protocol/signature/configuration failures do not use this retry path. Disable and successful startup clear the pending retry budget. Registration completion submits one engine configure/retry operation, and pending registration no longer queues a spurious enabled configuration with false readiness. Bridge revocation emits only one detach per transport. No code-signing, active-user/session, or single-owner checks were removed.

Band selection now starts empty. A local event observer scoped to the editor selects a strip on mouse-down, clears selection and text-field focus outside band controls, and preserves original events for the controls. Graph node hit tests retain selection while dragging; blank graph space clears it. Clipped/scrolled strips cannot claim clicks in the fixed header/footer.

Verified on 2026-10-22:

- **30 Swift tests pass**, including new bounded-backoff, reset/cancellation, and permanent-error cases.
- The complete native suite passes normally and with AddressSanitizer. New isolated bridge tests cover exactly one detach per transport across repeated cleanup and distinguish transient XPC failures from protocol/signature rejection.
- Source-rendered editor/menu fixtures pass their visibility and selection assertions. Actual rendered hit regions match the editor bounds and all eight band centers in both window sizes. Initial unselected appearance was visually inspected. The selection cases include another band, a gap, the header, graph ownership, and a clipped strip behind the header.
- The Release app and 0.3.1 package build. Expanded signatures, trust hashes, driver bridge identity, version, icon, and installation scripts verify. Swift formatting, shell syntax, and whitespace checks pass.

The 0.3.1 package was installed successfully after myEq closed. The installed app, driver, and helpers match the verified signatures/trust hashes, the receipt reports 0.3.1, and a fresh installation UUID is present. Core Audio automatically loaded the replacement stereo 48 kHz driver; physical output remained ADAM Audio D3V while the app was closed. The installed bridge probe also passes: the bridge authenticates and rejects the wrong protocol and every unauthorized role, without changing audio routing. The implementation is committed as `b392153`. First launch, repeated off/on cycles without Retry, and real mouse/focus behavior still need a user-assisted live check; Computer Use access to myEq remains denied.

## Recovery helper launch constraint (0.3.2)

The user-assisted 0.3.1 launch failed before the helper could run. At 00:40:55, launchd reported a spawn constraint mismatch (`c[5]p[1]m[1]e[0]`) for the installed recovery executable. Background Task Management then invalidated the item; subsequent attempts reported `EX_CONFIG` and an unresolved relative program path. The installed executable exists and its signature matches the package/trust manifest. Thus missing files and transient XPC startup were not the cause of this particular failure. The evidence is consistent with a stale inferred ad-hoc constraint surviving unregister/register.

The 0.3.2 package generates an explicit recovery `SpawnConstraint` from the already signed embedded executable, before signing the enclosing app. It keeps the existing identifier, service name, registration/approval flow, and all XPC checks. The Release build and checked-in package verification script pass, validating the exact launch constraint as well as signatures, trust identities, versions, icon, and install scripts. Shell syntax and whitespace checks pass. Live registration with the revised constraint remains to be checked after installation.

The 0.3.2 installation completed at 06:19 on 2026-10-22. The receipt reports 0.3.2; launchd shows the recovery agent running under bundle version 5 with the explicit spawn constraint. Core Audio logs show myEq becoming the default media/system output. This confirms registration and route activation after the constraint change. It does not independently confirm audible playback or band focus behavior.

## Music skipping tracks after installation

The subsequent playback report was investigated against Music and Core Audio logs. Music process 61004 remained running across the 06:19 installer audio-service restart. Between 06:19:46 and 06:20:25, its AudioQueue startup failed 18 times with `268435459` (`0x10000003`, `MACH_SEND_INVALID_DEST` in the SDK's `mach/message.h`). Music also reported the same invalid destination on HAL property requests. The virtual route activated successfully during this period. These observations point to Music retaining a dead audio-service connection; a driver format or DSP fault has not been established.

A user-assisted full quit/reopen of Music followed by playback with EQ enabled was requested. The installer welcome/completion text and README now explain reopening playback apps after Core Audio reload. A standalone `installed-playback` probe checks fresh, silent AudioQueue clients against the already enabled virtual output without changing routes. It compiles and correctly refuses to run while EQ is bypassed.

Music then reopened as process 98056 and EQ became active. The fresh-client probe passed at all three input rates: 44.1 kHz (64 callbacks), 48 kHz (69 callbacks), and 96 kHz (139 callbacks), with successful startup, no enqueue errors, and advancing sample times. The default media/system output remained `myEq: ADAM Audio D3V` at 48 kHz. The reopened Music process also rendered 1,146,368 frames through the virtual output (about 23.9 seconds at 48 kHz). A later route reconfiguration produced one generic HAL startup error, followed two seconds later by successful `AudioDeviceStart` on the myEq output; the original repeated invalid-destination failures were not observed in the new process. These checks confirm fresh-client playback works through the installed driver. Audible Music playback and whether track skipping has stopped still need the user's confirmation. The installer guidance is a source change for the next package; no additional reinstall is needed for this diagnostic.

The user subsequently confirmed the Music result with **“perfect”** and moved on to the remaining first-band highlight issue.

## Initial editor focus (0.3.3)

The empty selection model did not address AppKit's automatic first-field focus. Also, numeric binding writes unconditionally selected their band, including unchanged values committed during focus transitions. The editor now supplies a neutral initial responder and clears selection on initial presentation or reopening after close. Returning to the same open editor preserves editing focus; real mouse-down cancels a pending initial reset. No-op binding writes now leave selection/settings untouched.

The offscreen source-rendering check passes with real native numeric fields: initial/reopened focus is neutral, Tab reaches a control, direct field editing works, ordinary key-window notifications preserve ongoing edits, outside clicks clear focus, and unchanged binding writes leave the model unselected. All six layout fixtures and existing hidden-graph checks pass. These fixtures use never-shown windows and simulated lifecycle notifications; the installed-window result is confirmed separately below.

The 0.3.3 Release installer builds and expanded-package verification passes, including component signatures, XPC trust hashes, the recovery spawn constraint, version 6, icon, and exact install scripts. Swift formatting, shell syntax, and whitespace checks pass. The compact editor fixture was visually inspected with no band or numeric field highlighted. Audio/DSP/driver code is unchanged.

The 0.3.3 package was installed successfully on 2026-10-22 after myEq closed. The installed receipt reports 0.3.3/build 6; app, driver, and helper signatures match the verified package, the recovery spawn constraint matches its helper, and a fresh installation UUID is present. Core Audio automatically loaded the replacement driver at 48 kHz. With myEq closed, default playback remained on ADAM Audio D3V. Music was also closed by the end of installation. The focus implementation is committed as `4bad521`.

After being asked to open the installed app and close/reopen its main window, the user replied **“confirmed”** on 2026-10-22. The live check that the editor opens without a highlighted band or numeric field is therefore passed. This was user verified; Computer Use access to myEq remains denied.

## MIT license and DSP acknowledgment

On 2026-10-22, the project adopted the MIT License with copyright attributed to Tomasz Cholewa. `THIRD_PARTY_NOTICES.md` credits Robert Bristow-Johnson and the W3C Audio EQ Cookbook edited by Raymond Toy, identifies the C++ coefficient adaptations, and preserves the original document notice and full W3C Software and Document License (2015). The README, architecture, and DSP source link to these notices.

The Release installer rebuild passes. Expanded-package verification confirms that `LICENSE` and `THIRD_PARTY_NOTICES.md` in the app's resources match the repository files byte for byte, alongside the existing signature, XPC identity, recovery constraint, version, icon, and installer-script checks. Shell/Python syntax, local documentation links, and whitespace checks pass. The source change to DSP is a comment only; no audio or UI behavior changed, and no hardware tests or installation were performed for this licensing update.

## Public repository preparation

On 2026-10-22, the README was organized for new users, retaining both screenshots and the MIT/DSP notices. Installation and troubleshooting details moved into `INSTALLATION.md`; contribution, security-reporting, and release guides were added alongside GitHub issue forms, a pull-request template, and a build/test workflow. Ignore rules now cover local tool caches, environment files, signing material, and packaged products.

A read-only review of the 31 existing commits (252 unique file blobs) found no matches for the checked private-key, common service-token, credential-URL, or personal absolute-path patterns, and no credential or packaged-binary paths in history. This was a limited pattern/provenance review, not a guarantee that every possible secret format was detected. Commit history contains the author's name and personal email; history was preserved. Screenshots were inspected, including their text metadata, and retained as supplied.

Local verification passes on macOS 27.0.1 with Xcode 27.1: all **30 Swift tests**, the native suite normally and with AddressSanitizer, Swift formatting, Release installer build, expanded-package verification, shell/Python/plist/XML syntax, and local documentation-file links. The repository checker was also exercised against broken/escaping links and a missing license. GitHub YAML parses, issue field IDs are unique, and the workflow has read-only contents permission and a commit-pinned checkout action.

The workflow uses GitHub's hosted `xcode-27` Apple Silicon image and selects Xcode 27.1. Its test/build commands were verified locally; the first hosted execution remains pending. No GitHub repository was created, remote added, history rewritten, package installed, or release published during this preparation. Enabling private vulnerability reporting and repository rules remains part of GitHub setup, documented in `RELEASING.md`.

## Public GitHub publication

On 2026-10-22, the prepared repository was published at [tcholewa/myEq](https://github.com/tcholewa/myEq), preserving its existing history on the default `master` branch. GitHub recognizes the MIT license; both screenshots and the DSP notice are present in the public source. Private vulnerability reporting, secret scanning, and push protection are enabled. The repository's default Actions permissions are read-only, with workflow approval of pull requests disabled.

The [first hosted CI run](https://github.com/tcholewa/myEq/actions/runs/39729969504) passed on source commit `ed52292`: repository checks, Swift tests, native tests normally and with AddressSanitizer, Swift formatting, installer build, and expanded-package verification. This resolves the hosted-run check left pending during repository preparation. The README now links to the live CI status and includes the repository's clone URL; the security policy links directly to private reporting.

Publication did not install the package, change audio routing, upload a binary release, or add Developer ID signing/notarization. Hardware acceptance checks below remain separate from the successful hosted build.

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

## Security hardening — runtime and persistence

The protocol-v2 changes were tested with 30 passing Swift tests and the native suite under AddressSanitizer plus UndefinedBehaviorSanitizer. New checks use anonymous XPC endpoints (not installed services) to exercise actual runtime signature rejection, accepted signatures, one-way requests, and stale generation rejection. A fixed-seed 25,000-case loop exercises malformed message versions and adversarial ring cursors/metadata; file fixtures cover size bounds, symbolic links, and hard links. Driver tests assert that expired leases copy no frames. The test fixture substitutes console-user discovery, so these checks do not establish real multi-user isolation.

The installed app and audio services were not changed or interrupted. Full multi-user, crash-recovery, installer, CPU and clean-Mac distribution validation remains required before a public binary release. No root escalation or unauthorized audio capture has been demonstrated by this review.

## Security hardening — installer and release tooling (0.4.0)

On 2026-10-22, the complete Swift suite passed **31 tests**. The final native suite passed with AddressSanitizer and UndefinedBehaviorSanitizer, including actual anonymous XPC authentication/rejection, typed reply/schema checks, expired driver leases and mocked recovery retirement/settlement ordering. Late replies, an active bridge generation, malformed replies and timeouts do not authorize route restoration in those fixtures. Clang static analysis reported no warnings across the bridge, recovery helper, driver, client, DSP and maintenance utility.

The Release app and ad-hoc installer built successfully. Expanded-package verification passed for signatures, all component trust hashes (including driver and maintenance), recovery launch constraint, version 0.4.0/build 7, packaged scripts, permissions, icon and notices. The local package SHA-256 is `8211b570e5a7a7642cf6495957ecf8b2acaab2a8f06ce7a931adec736af86595`. This package was not installed or notarized.

Unprivileged maintenance fixtures passed with ASan/UBSan: valid postflight, fresh preflight, upgrade snapshot, rollback and uninstall, plus rejection of symbolic links, hard links, writable files, ACLs, corrupted recovery code, mismatched hashes, altered launch configuration, truncated manifests and missing components. Shell launcher fixtures additionally exercise unsafe ancestor/executable rejection before exec. These use private directories and suppress service operations; they do not validate root execution or Apple Installer's actual deployment. The shell fixtures substitute UID/path checks in a private copy and use a signed, harmless executable.

Swift formatting, shell/Python/plist/XML syntax, workflow YAML parsing, documentation links and whitespace checks passed. The release script rejected absent signing credentials before building; the CI release gate rejected a missing clean-Mac record. No Developer ID certificates, notarization credentials or fabricated validation record were supplied. The signed-release workflow has not been exercised on GitHub. Normal CI now includes sanitizer, installer-fixture and static-analysis checks.

No installed app, service, audio route or system permissions were changed during this work. Clean-Mac installation/upgrade/removal, actual multi-user isolation, live crash recovery, driver-host sandbox compatibility, signed/quarantined distribution, and hidden/visible CPU checks remain outstanding. The release candidate upload is gated on maintainer-recorded validation. See [security review](SECURITY-REVIEW.md) and [release setup](RELEASING.md).

## 0.4.0 installation and remote verification

On 2026-10-22, commits `bb72948` and `0a0a839` were pushed to `master` and the verified 0.4.0/build 7 package was installed on the development Mac. Music was quit before the Core Audio reload and reopened afterward. The installer completed successfully; installed component hashes, signatures, recovery launch constraint and receipt match the package. The bridge runs as `nobody`, and the replacement driver loaded without a reboot. The installed IPC probe authenticated the bridge and confirmed wrong-protocol/unauthorized-role rejection.

First launch encountered another cached macOS recovery launch constraint failure (`CODESIGNING`, Launch Constraint Violation), despite matching on-disk signatures. Quitting myEq, refreshing its LaunchServices record, clearing only its `recoveryRegistrationID` preference and reopening triggered a fresh ServiceManagement registration. The helper then ran under bundle version 7 with no exit. No signature checks were relaxed. This manual registration refresh remains an upgrade limitation; the source does not yet automatically detect this specific cached failure.

After that refresh, the active route was `myEq: ADAM Audio D3V`, stereo at 48 kHz. Fresh silent AudioQueue clients passed at 44.1 kHz (64 callbacks), 48 kHz (69), and 96 kHz (139), with no startup or enqueue errors and advancing sample times. The route stayed unchanged. This establishes fresh-client playback and route activation, not an independent listening check or the full crash/multi-user/CPU acceptance matrix.

The first hosted security-update run passed Swift/native/sanitizer tests but failed package verification: macOS Bash 3.2 rejected expansion of an empty optional signing-arguments array under `set -u`, so no product archive was created. Packaging and notarization now use nonempty argument arrays. The correction is verified with an explicit `/bin/bash` build and expanded-package verification; it changes packaging tooling only and does not require reinstalling the working runtime.

## Adaptive menu panel draft (superseded before release)

On 2026-10-22, the menu was reduced to a 344 × 282 pt control panel: status/native switch, output, preset, Open Equalizer and utility footer. It follows system appearance and uses semantic materials/colors, with explicit Reduce Motion, Reduce Transparency and Increase Contrast handling. The editor retains its existing design. Removing the menu graph also removes all menu-only response calculation; the visibility fixture verifies that opening/editing through the menu leaves editor curves parked until the editor appears.

All **31 Swift tests** passed. The source renderer produced **16 fixtures**: two editor sizes and seven menu variants in each of light/dark appearance (running, bypassed, starting, attention, paused, long names and reduced-effects/increased-contrast policy). The standard panels are 282 pt tall, representative paused panels 342 pt and attention panels 372 pt. Normal light/dark, long names, error/paused states and increased-contrast previews were visually inspected. Representative small Output-label pixels measure 4.80:1 light, 7.61:1 dark, 12.45:1 increased-contrast light and 11.60:1 increased-contrast dark against the rendered background. These are fixture measurements, not a claim covering every wallpaper, accent color or antialiased edge.

An initial optimized render run stopped at the existing editor-focus assertion before rendering the menu. A debug replay and the final optimized run with debug symbols passed the editor focus/selection and visibility checks. The renderer now retains debug symbols to make any recurrence diagnosable. Offscreen accessibility-tree enumeration did not expose SwiftUI controls in never-shown windows, so it is not reported as a VoiceOver test.

The 0.4.1/build 8 Release installer builds under `/bin/bash`; expanded-package verification, Swift formatting, repository/documentation checks and whitespace checks pass. Package SHA-256: `c0b2a03674133e9936b3f3034b636f651399193c254435be85eed9375dd5ffd1`. No DSP, driver or helper implementation changed. The installed app/audio route was not modified, and this UI revision has not been installed or pushed during this task.

Live menu tracking, arrow/Tab navigation, native focus rings, VoiceOver reading order, system accessibility settings and wallpaper-dependent vibrancy remain installed-window checks. The source-rendered previews deliberately do not show native outer popover chrome or claim active-window switch appearance. See the [layout and interaction specification](MENU-DESIGN.md).


## Studio menu refinement (0.4.1)

The adaptive draft above was rejected before installation or publication. The original studio panel is restored, with only the Flat/Neutral and Botaniq1/Reference quick-preset cards removed and Open equalizer switched to the shared subdued button style. The main preset selector and static response preview remain. The final source diff against installed 0.4.0 changes only those menu elements; graph visibility logic and editor presentation match 0.4.0.

The source renderer passed existing focus, selection and hidden-visual-work assertions and produced six fixtures. The standard menu now measures 354 × 498 pt, with the representative attention state at 354 × 606 pt. Enabled, attention and long-name fixtures were visually inspected. README preview and the menu specification match this refinement. Live interaction was not rechecked, and the installed app/audio route was not changed.

The 0.4.1/build 8 Release installer builds under `/bin/bash`. Expanded-package verification, Swift formatting, repository/documentation checks and whitespace checks pass. Final package SHA-256: `a0ea4b00f4dd255b3862725e34daee0bf2a591e22d3edd05f303aeb322f211b9`. This revision has not been installed or pushed.
