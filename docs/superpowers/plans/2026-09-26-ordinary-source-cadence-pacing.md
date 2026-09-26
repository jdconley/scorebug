# Ordinary source-cadence pacing comparison

**Goal:** Reduce replacement bursts in the actual publishing path and verify whether full720recovery preserves live media.

**Comparison design (completed, activation reverted):** Reuse the existing immutable `pacesEncodedVideo` option in SRTMediaPublisher. The ordinary production factory passes true, both with and without observation availability; low-level and legacy fixture defaults remain unchanged. Expose the option through the existing injectable factory seam so constructor tests verify propagation together with minimum startup, shared AAC observation, bounded measured admission and no lifetime cap. No new pacer or app environment selector. This is a controlled production-path comparison, not prior media qualification.

The existing source clock preserves its anchor through replacement, delays only early encoded output, and retains the16queued-frame/2MiB-per-item bound plus one consumer-held frame. Audio remains independent. Finish/cancellation/restart/overflow retain existing terminal joins. Pacing cannot erase already-built network backlog or enforce a byte rate; current evidence may still require earlier pressure scheduling.

- [x] Add constructor assertion for pacing through the existing test seam. Introduce only the false-valued seam plumbing needed to execute a causal failing assertion, then run focused factory test.
- [x] Select true in both ordinary construction branches; preserve explicit minimum and candidate plumbing.
- [x] Run CaptureStreamingModel and owned-candidate/driver regressions, existing SDK SourceCadenceClock/Finish/VideoReplacement and startup tests, DebugUI and Release builds. Review exact source blobs before committing.
- [x] Run the same ordinary720/700ms/3000ms profile, verified600s source,750kbps cap and packet capture. Join then verify native/transport/geometry plus all media and packet attribution. Do not qualify improved burst numbers as media success.
- [x] Compare against unpaced uDznjI: original185688wire bytes in800–1000ms,261overflow packets,2796ms maxqueue residence and100missing live frames. If loss persists, retain failure and proceed to earlier sampling/local evaluation with existing250ms evidence windows and thresholds; do not widen buffers/deadlines.

Files: `ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift` and
`ios/FilmModelTests/CaptureStreamingModelTests.swift`. Existing SDK code is unchanged.
History/evidence: [session log](../../session-logs/2026-09-26-ordinary-source-cadence-pacing.md).

**Outcome:** No demonstrated benefit; live continuity still fails while the independent archive passes. Ordinary activation is reverted to isolate the next sampling comparison. Retain the optional SDK pacer and all failed evidence. See the session log for measurements.
