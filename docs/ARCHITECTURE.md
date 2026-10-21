# Architecture

## Ownership and signal path

SwiftUI owns the editor and menu bar. `AppModel` holds the current eight-band configuration, presets, selected band, and engine telemetry on the main actor. `AudioEngine` serializes all HAL operations on a dedicated control queue. Only the C++ callback touches real-time filter state and audio samples.

Signal path: selected system-output mix → preamp → eight stereo biquads → linked sample-peak limiter → the same output device. Left and right share coefficients but retain independent filter histories. No recording, network access, app-specific controls, or separate microphone input is part of this path.

`TapSession` creates a device-scoped private `CATapDescription`, excludes myEq's audio-process object, and sets `mutedWhenTapped`. The tap and physical output form one private aggregate with the output as clock source and tap drift compensation enabled. A single C IOProc reads the trailing tap buffers and writes the physical stereo output. Microphone buffers belonging to duplex hardware are explicitly disabled and never read. Output preferred-channel assignments are honored.

The device-scoped/single-clock design follows Apple's process-tap and aggregate-device APIs. [Apple's process-tap overview](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) and [CoreAudioTapKit's topology discussion](https://github.com/CJStanfield/CoreAudioTapKit) informed the design; no third-party runtime dependency is included.

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

The engine exposes bypassed, starting, running, suspended, and error states. Property listeners handle default-output/device-list changes and audio-service restarts; a 250 ms control tick also observes rates, formats, Bluetooth microphone activity, and telemetry. Parameter edits submit settings without re-enumerating devices.

Route changes, sleep, Bluetooth hands-free use, bypass, and shutdown stop IO before destroying the IOProc, aggregate, tap, and DSP storage. A normal application exit waits for control-queue cleanup. Fatal buffer faults or a stalled callback during external playback release capture and expose Retry. Silence alone is not a failure. After an audio-service restart the engine recreates its private resources; unexpected format changes suspend processing until a supported route returns.

Unsupported output transports, non-stereo configurations, multiple hardware output streams, and non-Float32 virtual formats remain bypassed. The app currently accepts 32–192 kHz stereo PCM and does not claim support for every device exposing those formats. Force-quit restoration and physical Bluetooth transitions still require the hardware checks in VERIFICATION.md.

## Persistence and packaging

Version-1 Codable settings contain the working preset, personal presets, and desired enable state. Validation rejects non-finite/out-of-range values, malformed band arrays, duplicate preset IDs, and unsupported schema versions. Writes are debounced and atomic. Unreadable settings are preserved under a unique filename before resetting; if preservation fails, saving is disabled rather than overwriting the original.

Factory presets are immutable templates. Editing one changes the working copy; Save As creates a personal preset. Launch at login uses `SMAppService.mainApp` and remains off unless selected by the user.

The Xcode app target links the local Swift package statically. `scripts/build.sh` builds a Release arm64 bundle, generates its icon from code, applies local ad-hoc signing, and verifies the signature. Only Apple system libraries are dynamically linked. There is no installer, privileged helper, notarization, or update service in this personal-use version.

## Proposed virtual-output backend

The current process-tap backend requires system-audio capture permission. macOS identifies system-audio capture with a purple privacy indicator, including when the app processes audio in memory without saving a recording. This follows [Apple's tap permission model](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) and [Control Center indicator documentation](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac).

To replace capture with explicit output routing, a future backend would publish an output-only `myEq` virtual device through an AudioServerPlugIn, transfer its mixed stereo output to the app through authorized shared memory, run the existing DSP, and play to the selected physical device. This avoids using the process-tap or recording-input API for the routed mix. The expected absence of a capture indicator must still be validated on supported macOS releases. [eqMac documents a similar shared-memory driver architecture](https://github.com/bitgapp/eqMac#technology); its public repository describes an older release, not the current private implementation.

Required work includes:

- Add a backend boundary around audio sessions, retaining the tap option during development and reusing the DSP, presets, and editor.
- Build a stereo output-only driver and an authenticated, bounded shared-memory transport with no allocation or blocking inside either real-time callback.
- Coordinate physical-device clocking, buffering, drift correction, rate changes, volume/mute, and output switching.
- Preserve the previous default output and provide restoration on bypass, quit, disconnect, and app crash; crash recovery requires an independent supervisor or equivalent tested recovery mechanism.
- Package installation, updates, and removal with administrator authorization. Apple's [virtual-driver sample](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in) installs under `/Library/Audio/Plug-Ins/HAL` and requires a reboot. This is a user-space driver, not a kernel extension.

This backend is a proposal, not part of the current build. Installing a generic loopback device alone does not establish an indicator-free path: applications recording its input may still need microphone access, as documented by [BlackHole](https://github.com/ExistentialAudio/BlackHole#why-is-nothing-playing-through-blackhole).
