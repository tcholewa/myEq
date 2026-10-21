# myEq

A native, local macOS menu bar equalizer for the system stereo output. Eight parametric bands, a response graph, presets, automatic preamp, and stereo-linked peak protection. Target: Apple Silicon, macOS 27+.

## Development

Requires Xcode 27 or newer. Run `swift test` for numerical DSP and persistence tests. The app and hardware integration are being implemented; passing unit tests does not establish system-audio compatibility.

## Audio design

The C++ core runs eight biquads using the [W3C Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) formulas, 20 ms transitions, and a 1 ms lookahead sample-peak limiter at −0.5 dBFS. Auto preamp is derived from the combined response, not the largest individual boost. Audio remains stereo. The real-time callback allocates no memory and uses a bounded single-producer/single-consumer parameter queue.

Flat and Botaniq1 are recoverable factory presets. Bell width is in octaves, shelves use slope, and 12 dB/octave cuts use Q. Settings are versioned JSON under `~/Library/Application Support/myEq` and saved atomically. Invalid settings are preserved before resetting.
