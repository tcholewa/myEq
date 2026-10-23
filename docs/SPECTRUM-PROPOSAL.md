# Output spectrum and falling peaks — design proposal

Status: approved and implemented for 0.5.4/build 19. Images below retain the synthetic design proposal; the live implementation and verification are described in [architecture](ARCHITECTURE.md#output-spectrum-and-source-ghost-054) and [verification](VERIFICATION.md#054-output-spectrum-and-source-ghost).

## Proposed presentation

- The main 64 sage LED bars show the measured output after preamp, EQ correction, and peak protection.
- Refined styling makes the output quieter beneath the EQ curve: bars occupy 50% of band spacing, with 1.75-point segments on a 4-point pitch. The sage gradient retains its light top and dark base with reduced opacity (0.44, 0.34, 0.22, 0.12). Peak markers are one point high at 0.30 opacity. Ghost geometry, color, and motion remain unchanged.
- Each bar attacks immediately and falls at 24 dB/s. Its separate light peak marker holds for one second, then falls at 6 dB/s, matching the stereo level meter timings.
- A faint neutral outline shows the source spectrum with the current preamp applied, but without EQ correction. It uses the same frequency positions and dBFS scale. The ghost has no additional held-peak markers.
- The EQ response curve stays above both spectra. Spectrum levels retain their own −90–0 dBFS mapping; the graph's gain labels still describe the EQ curve.

The output-only variation remains available for comparison; the user accepted the source ghost's visual treatment while requesting subtler output bars.

## Preview artifacts

- [Animated falling bars and peak markers](images/spectrum-proposal-motion.gif)
- [Full editor with source ghost](images/spectrum-proposal.png)
- [Full editor with output only](images/spectrum-proposal-output-only.png)

Run `bash scripts/render-design.sh --spectrum-proposal` to render full-size and compact editors, an output-only editor, and a six-second looping animation under `build/artifacts.noindex/design-preview`.

Verification: the preview renderer completed successfully, including all 60 animation frames. Full-size and compact layouts and representative motion frames were visually inspected. Swift formatting and whitespace checks passed. Live audio behavior is outside this preview's validation scope.

The preview uses a deterministic synthetic spectral shape, adds the displayed preset's effective preamp to the source ghost, and adds its calculated EQ response to derive illustrative output levels. No limiter activity is simulated. A one-second signal burst followed by a 22 dB drop demonstrates both fall rates. This is not a measurement of audio passing through the app.

The proposal lives entirely in the design-rendering scripts. It decorates offscreen editor views and does not change production rendering, capture, FFT analysis, saved preferences, or the installed app. The animation prioritizes reproducible design review, not runtime performance measurement.

The production implementation captures actual post-processing samples and a time-aligned source-plus-preamp stream. It retains cached 64-band rendering, visibility gating, Reduce Motion behavior, and bounded capture. The default display includes the approved ghost; the output-only image above remains a design comparison, not a separate user preference.
