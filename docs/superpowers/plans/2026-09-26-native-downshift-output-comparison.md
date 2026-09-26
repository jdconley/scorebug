# Native downshift output comparison

**Goal:** Identify a measured intervention for the encoder/output burst during720p bandwidth collapse, while preserving recording, guarded receipts and bounded lifetime.

**Status:** Reviewed host and simulator comparisons completed at frames180/181. Preliminary bitrate reduction can shrink one pending frame, but the benefit is phase-dependent: simulator frame181 produces identical output and the host's100ms burst peak does not improve there. No network/A/V qualification. Earlier100ms pressure sampling remains enabled; full720p recovery remains unqualified. The guarded bitrate-first experiment also failed complete live media verification and is reverted.

## Comparison

Use independently owned native cases with the existing deterministic footage and real720 encoder at the current3Mbps recipe:

1. Ordinary720→360 replacement.
2. Verified same-encoder3Mbps→600kbps update with continued input.
3. The same verified bitrate update immediately followed by360 replacement.

Existing submitted/compressed-output/mux callbacks should retain native generation/configuration IDs, exact PTS, bytes, sync status and monotonic callback times. Record mutation admission, bitrate receipt, resize request and format receipt. Measure old-encoder tail bytes, actual output bursts, first reduced-rate output and replacement duration. Bound source duration and record count; fail on overflow or incomplete evidence and join finish/cancellation.

A mocked successful transport sink may isolate native encoder/mux behavior. It cannot qualify actual delivery or full adaptive recovery. Do not run another full recovery capture until this experiment supports a concrete intervention.

- [x] Inspect/reuse existing native harness and callbacks; choose finite duration/event bounds without changing production behavior.
- [x] Test trace validation, case ownership and bounded shutdown; preserve failed evidence.
- [x] Run all three cases with the same source/configuration and compare measured output, including frames already admitted before mutation.
- [x] Review results independently before selecting the production change.
- [x] Repeat resize/rate-resize with the native iOS simulator encoder; check an adjacent non-keyframe mutation phase before generalizing the host keyframe result.
- [x] Design an experimental pre-rate candidate with receipt chaining, intermediate native-effect ownership, one original deadline and no recovery credit for partial state. Cover refusal, stale resize after successful rate change, cancellation, timeout and receipt disagreement.
- [ ] If only bitrate-only operation helps, design rate-first adaptation with deferred geometry explicitly; the fixed min=max profile ladder cannot silently acknowledge a temporary720p/600kbps state.
- [ ] Retain a bounded first-downshift cause/ACK record to remove the recurring UI sampling blind spot. This is complementary evidence, not a substitute for measured output bytes.

The verified bitrate API reports configuration acceptance, not achieved rate or frame-boundary effect. Already-produced compressed frames cannot be made smaller by a subsequent property write. Preserve all policy/media/transport buffers and acceptance limits until a reviewed design justifies a change.

Evidence: [earlier sampling result](../../session-logs/2026-09-26-earlier-pressure-sampling.md). Earlier failures retain their original contracts.

Harness: one case per process,360frames/12seconds,20,000scalar-event cap. Native trace data must pass exact frame/receipt reconciliation and stable input cadence before interpretation. See [current log](../../session-logs/2026-09-26-native-downshift-comparison.md).

Reviewed candidate: one existing downward-resolution application and original deadline; old verified receipt → target bitrate on old encoder → resize using that new receipt → final verified rate → one final Core acknowledgment. Treat any successful native write as a native effect: later refusal/failure/cancellation must stop and join, never settle as untouched. Host data alone do not enable this path.


Completed candidate and acceptance outcome: [guarded downshift experiment](2026-09-26-guarded-downshift-experiment.md). The simulator's fourteen-frame flush remains unresolved; preliminary-rate acceptance alone neither drains it nor guarantees smaller pending frames. [Simulator and adjacent-phase evidence](../../session-logs/2026-09-26-simulator-downshift-comparison.md).
