# Correct fractional audio alignment near the analysis band edge

> Use superpowers:subagent-driven-development with specification then quality review. Queue behind the active production-scheduling slice; keep one source implementer at a time.

**Goal:** Avoid measurement-induced correlation failures for valid fractional-delay audio near the 8 kHz analysis signal's Nyquist limit, without relaxing media thresholds or altering encoded audio.

**Current status:** Run12 failed one live waveform sample at source frame 1817 (0.979183 < 0.98). Independent frozen-PCM calculation reproduces the original within 1e-9. Increasing only the interpolation kernel from 65 to 513 taps raises correlation to 0.992534 at the same delay; finer delay resolution alone makes no difference. A separately generated lossless 3950.3 Hz multitone control scores 0.894072 with 65 taps and 0.999999 with 513 taps. This establishes a measurement limitation; remaining lossy-codec/resampling distortion is not isolated. Original failed reports remain unchanged.

## Design

Use a 513-tap Hann-windowed sinc interpolator with 256 real support samples on each side. Share the required support constant between estimator, qualification extraction and tests so dimensions cannot silently diverge. Retain the exhaustive 1/32-sample grid, integer search bounds, input limits, mean/energy normalization, competing-peak checks, delay/lag-spread bounds and 0.98 qualification threshold. Do not use local-peak refinement as a substitute for exhaustive search; the diagnostic refinement was localization only.

Require actual neighboring samples; do not zero-pad, extrapolate, filter away problematic content or exclude the failing anchor. Preserve integer-phase identity. State the finite-kernel limitation rather than claiming ideal interpolation or all-audio fidelity. Update method metadata so new reports distinguish the corrected estimator from earlier results.

Implementation now passes independent lossless signed-delay regressions, all 89 relevant tests, and specification/quality reviews. Complete frozen run12 waveform/glyph requalification now passes in a new report: 40 archive and 38 probes per live output, including the original failing live anchor at correlation 0.992534. Original failed reports remain unchanged. Run14 also passes all waveform/glyph checks.

## Tasks

- [x] Reproduce a lossless near-band-edge fractional-delay failure in an independently generated deterministic test (both delay signs and non-integer phases), while preserving ambiguity/boundary/nonfinite/unrelated-signal tests.
- [x] Implement the shared real-support constant and 513-tap kernel, updating all callers and bounds coherently. No media encoder, sample-rate or runtime pipeline changes.
- [x] Run relevant alignment/natural-audio suites and review specification then quality. Retain original red logs, commands and artifact hashes.
- [x] Re-run the complete frozen run 12 waveform/glyph qualification into a new output directory, under the unchanged thresholds and full anchor set. Identify estimator version/source commit and media hashes; do not overwrite or relabel the original failed report.

This corrects sampled alignment measurement only. It does not prove all-audio fidelity, fix the older 21 ms live gap, or qualify automatic ramp, Watch, hardware or network recovery.
