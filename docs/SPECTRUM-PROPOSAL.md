# Output spectrum and falling peaks — design proposal

Status: awaiting user approval. This is a synthetic preview, not an implemented live audio feature.

## Proposed presentation

- The main 64 sage LED bars show the measured output after preamp, EQ correction, and peak protection.
- Each bar attacks immediately and falls at 24 dB/s. Its separate light peak marker holds for one second, then falls at 6 dB/s, matching the stereo level meter timings.
- An optional faint neutral outline shows the source spectrum with the current preamp applied, but without EQ correction. It uses the same frequency positions and dBFS scale. The ghost has no additional held-peak markers.
- The EQ response curve stays above both spectra. Spectrum levels retain their own −90–0 dBFS mapping; the graph's gain labels still describe the EQ curve.

The output-only variation lets the user compare the visual density before deciding whether the source ghost should be shown by default.

## Preview artifacts

- [Animated falling bars and peak markers](images/spectrum-proposal-motion.gif)
- [Full editor with source ghost](images/spectrum-proposal.png)
- [Full editor with output only](images/spectrum-proposal-output-only.png)

Run `bash scripts/render-design.sh --spectrum-proposal` to render full-size and compact editors, an output-only editor, and a six-second looping animation under `build/artifacts.noindex/design-preview`.

Verification: the preview renderer completed successfully, including all 60 animation frames. Full-size and compact layouts and representative motion frames were visually inspected. Swift formatting and whitespace checks passed. Live audio behavior is outside this preview's validation scope.

The preview uses a deterministic synthetic spectral shape, adds the displayed preset's effective preamp to the source ghost, and adds its calculated EQ response to derive illustrative output levels. No limiter activity is simulated. A one-second signal burst followed by a 22 dB drop demonstrates both fall rates. This is not a measurement of audio passing through the app.

The proposal lives entirely in the design-rendering scripts. It decorates offscreen editor views and does not change production rendering, capture, FFT analysis, saved preferences, or the installed app. The animation prioritizes reproducible design review, not runtime performance measurement.

After approval, production output data must come from an actual post-processing tap, not from applying a response curve to the input FFT. The source and output displays must be time-aligned, and the existing cached 64-band renderer, visibility gating, Reduce Motion behavior, and bounded audio-thread capture must be retained. Runtime performance and audio isolation will require verification at that stage.
