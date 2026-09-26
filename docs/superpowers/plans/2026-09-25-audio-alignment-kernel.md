# Correct fractional audio alignment near the analysis band edge

> Use superpowers:subagent-driven-development with specification then quality review. Queue behind the active production-scheduling slice; keep one source implementer at a time.

**Goal:** Avoid measurement-induced correlation failures for valid fractional-delay audio near the8kHz analysis signal's Nyquist limit, without relaxing media thresholds or altering encoded audio.

**Current status:** Run12 failed one live waveform sample at sourceframe1817 (.979183<.98). Independent frozen-PCM calculation reproduces the original within1e-9. Increasing only the interpolation kernel from65to513taps raises correlation to.992534 at the same delay; finer delay resolution alone makes no difference. A separately generated lossless3950.3Hz multitone control scores.894072 with65taps and.999999 with513taps. This establishes a measurement limitation; remaining lossy-codec/resampling distortion is not isolated. Original failed reports remain unchanged.

## Design

Use a513tap Hann-windowed sinc interpolator with256real support samples on each side. Share the required support constant between estimator, qualification extraction and tests so dimensions cannot silently diverge. Retain the exhaustive1/32sample grid, integer search bounds, input limits, mean/energy normalization, competing-peak checks, delay/lag-spread bounds and0.98qualification threshold. Do not use local-peak refinement as a substitute for exhaustive search; the diagnostic refinement was localization only.

Require actual neighboring samples; do not zero-pad, extrapolate, filter away problematic content or exclude the failing anchor. Preserve integer-phase identity. State the finite-kernel limitation rather than claiming ideal interpolation or all-audio fidelity. Update method metadata so new reports distinguish the corrected estimator from earlier results.

## Tasks

- [ ] Reproduce a lossless near-band-edge fractional-delay failure in an independently generated deterministic test (both delay signs and non-integer phases), while preserving ambiguity/boundary/nonfinite/unrelated-signal tests.
- [ ] Implement the shared real-support constant and513tap kernel, updating all callers and bounds coherently. No media encoder, sample-rate or runtime pipeline changes.
- [ ] Run relevant alignment/natural-audio suites and review specification then quality. Retain original red logs, commands and artifact hashes.
- [ ] Re-run the complete frozen run12 waveform/glyph qualification into a new output directory, under the unchanged thresholds and full anchor set. Identify estimator version/source commit and media hashes; do not overwrite or relabel the original failed report.

This corrects sampled alignment measurement only. It does not prove all-audio fidelity, fix the older21ms live gap, or qualify automatic ramp, Watch, hardware or network recovery.
