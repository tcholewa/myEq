# Output spectrum and falling peaks — design proposal

Status: historical proposal, superseded by the user's request to remove the source ghost and outlines. The current implementation displays processed output only; see [architecture](ARCHITECTURE.md#output-spectrum) and [verification](VERIFICATION.md#processed-output-only-spectrum). The images below preserve the earlier design review.

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

The source ghost shipped in 0.5.4, then was removed at the user's request because it added outlines without a useful visual distinction. Current source retains only actual post-processing output, cached 64-band rendering, held peaks, visibility gating, and Reduce Motion. The proposal renderer remains an archived design comparison; normal editor previews render the current output-only implementation.
