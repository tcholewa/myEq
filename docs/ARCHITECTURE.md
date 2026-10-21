# Architecture

## Ownership and signal path

System clients → HAL mixed stereo output → `myEq.driver` WriteMix → shared-memory ring → app physical-output callback → Apple AUVarispeed clock correction → existing preamp/EQ/limiter → physical output.

The SwiftUI app owns presets and the editor. `AudioEngine` serializes session changes on its control queue. `VirtualOutputSession` opens only the physical output and disables every physical input stream before starting IO. The output callback is C++ and does not call Swift, allocate, lock, log, or perform IPC. There is no capture-tap fallback.

The output-only C++ AudioServerPlugIn publishes UID `com.tc.myEq.output`, one interleaved Float32 stereo stream, and hardware-proxy volume/mute controls. The host supplies the already mixed stream via WriteMix. Nominal rate changes follow the physical device using the host configuration-change handshake. The driver advertises no input and never calls the client HAL APIs from inside the driver. A host-time clock supplies zero timestamps at a 16,384-frame period.

`myEqBridge` is a system LaunchDaemon running as `nobody`. Its global Mach service is listed in the driver's `AudioServerPlugIn_MachServices`, following [Apple QA1811](https://developer.apple.com/library/archive/qa/qa1811/_index.html). It brokers an anonymous `MAP_SHARED` mapping through XPC; samples never travel in messages or through the bridge's event loop. The installer records app/helper code hashes in a root-owned trust manifest. The driver carries the bridge hash in its own bundle, which is readable inside its sandbox. Incoming clients complete a two-message handshake: the first sets an XPC code-signing requirement, and the second must pass that requirement before a role or memory mapping is granted. Driver peers must be the Apple-signed audio-driver host; app and recovery peers must be the active console user in the same audit session. Only one app and recovery session are accepted.

## Transport and clocking

`Transport.hpp` defines protocol version 1: immutable format/size/generation fields, cache-line-separated atomic cursors and telemetry, lease state, and 16,384 stereo frames. A single driver WriteMix producer owns `written`; the app owns `read`. Acquire/release ordering protects ordinary sample storage. The writer drops incoming blocks when full and never overwrites unread samples or changes the reader cursor. Mapping headers, sizes, versions, rates, and generations are checked before use. Audio mappings remain alive until IO has stopped.

The physical callback starts after two output blocks are buffered (minimum 256 frames). A preallocated Apple AUVarispeed unit makes slow PI corrections around unity, bounded to ±0.2%, to compensate independent clocks at the same nominal rate. Discontinuities, overruns, and underruns discard buffered history, render silence, and reprime; a 5 ms input fade avoids abrupt restart. Non-finite source samples are contained. All buffers and the converter are prepared before IO; output callbacks larger than the supported storage are rejected and reported. The hardware buffer size is observed, not changed globally.

The driver applies no digital volume. The app proxies master volume/mute or paired channel controls to the physical device, retaining channel balance. Outputs without writable hardware controls remain fixed-volume. Controls are exchanged outside the audio callback.

## DSP contract

The C API in `CDSP.h` is shared by the audio engine, graph/model, and offline tests. `meq_prepare` and layout configuration require a stopped callback. A bounded single-producer/single-consumer queue transfers prepared coefficient banks from the control queue to the callback. If full, the latest desired preset remains pending and is retried by the next control tick. The callback drains to the newest bank when the previous 20 ms crossfade finishes. Filter coefficients are never interpolated through unstable intermediate values.

Eight double-precision biquads use the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) equations. Bell gain is ±24 dB with 0.05–5 octave bandwidth; shelf slope is 0.1–1; cut Q is 0.1–10, defaulting to Butterworth Q. Frequency is constrained to 20 Hz–min(20 kHz, 0.45 × sample rate). Stored frequencies survive output changes, while processing and graph positions use the effective frequency.

Auto preamp searches the combined response from DC through Nyquist, adds every band's center frequency to the search, and rounds attenuation upward to 0.1 dB. It can attenuate more than the manual control's −60 dB lower bound. The graph uses the same coefficient code and shows the linear response, including preamp; it does not depict the signal-dependent limiter.

The limiter has a 1 ms delay, linked left/right gain, a monotonic lookahead peak queue, a −0.5 dBFS sample ceiling, and 50 ms release. It is a sample-peak limiter, not an oversampled true-peak limiter. Its delay is in addition to Core Audio and hardware latency. All storage is allocated before audio starts; the callback does not allocate, lock, log, perform file IO, or call Swift. Telemetry atomics are asserted lock-free at compile time. Null tap data means silence; changed buffer topology and non-finite samples increment fault counters.

## Stereo output metering

While the editor is visible, each callback accumulates separate left/right post-limiter sample peaks in one packed, lock-free 64-bit atomic. `meq_take_meter` atomically drains both channels together, retaining transients across all callbacks since the previous display poll. The shared gain-reduction reading also retains its maximum until consumed. `meq_meter` remains non-destructive so the health watchdog cannot steal a meter interval.

A separate 30 Hz control-queue timer in `OutputMeterMonitor` supplies `OutputLevels` to the main actor; the 250 ms HAL/health tick is unchanged. Meter polling is parked while capture is stopped or the editor is not visible. Bypass and suspension immediately reset display levels and peak markers. `OutputMeterEnvelope` provides immediate attack and elapsed-time-based 24 dB/second decay over −60 to 0 dBFS. Separate white peak markers hold each channel's peak for one second, then fall at 6 dB/second. New peaks refresh only their own channel's hold; an update crossing the hold deadline applies decay only to the remaining elapsed time. Numeric dBFS readings and accessibility values use the same held-peak values as the markers. At the meter floor, the markers disappear and the readouts show −∞ dBFS. This display smoothing does not affect audio.

`StereoOutputMeter` is a fixed-size `NSViewRepresentable` with no SwiftUI observation of the meter model. Its native view subscribes directly to envelope changes and updates persistent Core Animation layers with implicit animations disabled. Bar masks and markers change geometry; text layers update only when their displayed value changes. Live samples never invalidate intrinsic size or rebuild the SwiftUI meter hierarchy. The view handles display scale changes and exposes the peak values to accessibility. UI scheduling is best-effort, independent of the real-time audio deadline.

## Visibility and CPU use

An `NSViewRepresentable` observes only the editor's actual `NSWindow`. It combines ordered visibility, miniaturization, application hiding, and [AppKit occlusion notifications](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification). A partly visible editor continues updating even when another app is active; a closed, minimized, hidden, or fully occluded editor stops visual work. Menu-bar windows do not activate the observer.

Visual DSP metering defaults off. `meq_set_metering_enabled` changes an atomic epoch once per visibility transition. At the next block boundary, the audio thread chooses a compiled render path that omits output-peak accumulation, minimum-gain tracking, dB conversion, and meter publication when hidden. EQ, limiter processing, callback counters, and fault detection run in both paths. Epochs discard prior readings even if a complete hide/show cycle occurs between callbacks; an old in-flight callback cannot publish a peak accepted by the new interval.

`OutputMeterMonitor` parks its timer and invalidates queued main-thread deliveries on hide or session changes. Its delivery-validation lock is used only by the control and main queues, never the real-time callback. The app also rejects meter updates while hidden, cancels pending graph work, skips graph drawing, and recalculates the response from current settings when shown. Engine snapshots are published only when user-facing status changes; callback/fault counters remain internal to the watchdog, eliminating unchanged 4 Hz editor/menu invalidations.

## Lifecycle and recovery

`myEqRecovery` is an independent per-user LaunchAgent registered by `SMAppService`. It is the sole owner of default-route writes. Before activating it writes a routing-only recovery journal, asks the bridge to activate the prepared renderer's lease, waits for driver availability, then redirects both default media and system sounds. The original alerts destination is preserved separately. Bypass/quit restores the current physical destination before the app stops its renderer. Cleanup changes a default only if it still points at myEq.

The app and recovery agent send health checks every 250 ms. The bridge revokes the session if either peer disappears, the console user changes, a heartbeat is older than 1.5 seconds, or render progress stalls. The driver independently expires the two-second lease and becomes unavailable. The recovery agent restores defaults on connection loss, sleep, or a failed heartbeat. If its journal survives a crash, it retries restoration when it next runs. No samples are journaled.

A manual media-default change bypasses and updates the app's enable preference. A destination disconnect instead allows fallback: preserve a physical destination already selected by macOS, otherwise select available built-in output, then another available physical output. This fallback is not restricted to EQ-compatible formats; ordinary playback is restored first, and EQ resumes only on a supported stereo route. The previous disconnected destination is not automatically reclaimed. Bluetooth hands-free mode remains suspended until stereo returns.

Rate, buffer size, device topology, sleep/wake, and audio-service changes rebuild the session. Driver/helper failures leave ordinary playback restored and expose Retry. Visual metering remains gated independently of audio health monitoring.

## Persistence, installation, and validation

Settings schema 2 adds an optional preferred output UID. Version-1 presets and enable preference migrate in memory; the next atomic save writes version 2. Invalid or unknown schemas retain the existing preserve-before-reset behavior.

The personal package installs `/Applications/myEq.app`, `/Library/Audio/Plug-Ins/HAL/myEq.driver`, the global bridge, its launchd plist, and the trust manifest. The recovery executable and LaunchAgent plist are embedded in the app. Package components are not relocatable, so Installer cannot upgrade a development copy by mistake. App/driver/helper signatures are verified during packaging and installation. Installing requires administrator authorization and targets the current startup disk. The installer welcome screen discloses a brief system-wide audio interruption. After signature verification and bridge bootstrap, postinstall sends TERM to Core Audio once; macOS relaunches it and loads the new driver. This also handles upgrades with unchanged driver code hashes, since replacing the bundle can unload the previous host. Building a package does not reload audio. Manual recovery, rollback, and uninstall can use `sudo killall -TERM coreaudiod`; a full Mac restart is an alternative. Upgrade/removal invokes the previous recovery helper as the console user before unloading services. A previous package is retained for rollback, and uninstall preserves user presets.

Build products and temporary packaging files live under `build/artifacts.noindex`; temporary packaging trees are removed on exit. Installer rollback copies also use `.noindex` directories. This keeps generated apps and retained backups out of Spotlight while preserving `/Applications/myEq.app` as the launchable installation.

This is locally ad-hoc signed, not notarized distribution. The architecture uses no recording-input or process-tap API; the expected absence of capture indicators must be verified on the target macOS release. The initial tests cover offline rendering and mocked recovery, not installed-system crash recovery, real-device performance, or end-to-end latency. See VERIFICATION.md for the current acceptance status.
