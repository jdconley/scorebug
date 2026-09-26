# Native downshift output comparison

**Goal:** Identify a measured intervention for the encoder/output burst during720p bandwidth collapse, while preserving recording, guarded receipts and bounded lifetime.

**Status:** Harness and analyzer implemented, tested and reviewed; native comparison pending. Earlier100ms pressure sampling remains enabled. Full720p recovery is still unqualified. No production bitrate-before-resize behavior is authorized by evidence yet; investigate it locally under the user's standing implementation authorization.

## Comparison

Use independently owned native cases with the existing deterministic footage and real720 encoder at the current3Mbps recipe:

1. Ordinary720→360 replacement.
2. Verified same-encoder3Mbps→600kbps update with continued input.
3. The same verified bitrate update immediately followed by360 replacement.

Existing submitted/compressed-output/mux callbacks should retain native generation/configuration IDs, exact PTS, bytes, sync status and monotonic callback times. Record mutation admission, bitrate receipt, resize request and format receipt. Measure old-encoder tail bytes, actual output bursts, first reduced-rate output and replacement duration. Bound source duration and record count; fail on overflow or incomplete evidence and join finish/cancellation.

A mocked successful transport sink may isolate native encoder/mux behavior. It cannot qualify actual delivery or full adaptive recovery. Do not run another full recovery capture until this experiment supports a concrete intervention.

- [x] Inspect/reuse existing native harness and callbacks; choose finite duration/event bounds without changing production behavior.
- [x] Test trace validation, case ownership and bounded shutdown; preserve failed evidence.
- [ ] Run all three cases with the same source/configuration and compare measured output, including frames already admitted before mutation.
- [ ] Review results independently before selecting the production change.
- [ ] If evidence supports immediate pre-rate, design receipt chaining, intermediate native-effect ownership, one original deadline and no recovery credit for partial state. Cover refusal, stale resize after successful rate change, cancellation, timeout and receipt disagreement.
- [ ] If only bitrate-only operation helps, design rate-first adaptation with deferred geometry explicitly; the fixed min=max profile ladder cannot silently acknowledge a temporary720p/600kbps state.
- [ ] Retain a bounded first-downshift cause/ACK record to remove the recurring UI sampling blind spot. This is complementary evidence, not a substitute for measured output bytes.

The verified bitrate API reports configuration acceptance, not achieved rate or frame-boundary effect. Already-produced compressed frames cannot be made smaller by a subsequent property write. Preserve all policy/media/transport buffers and acceptance limits until a reviewed design justifies a change.

Evidence: [earlier sampling result](../../session-logs/2026-09-26-earlier-pressure-sampling.md). Earlier failures retain their original contracts.

Harness: one case per process,360frames/12seconds,20,000scalar-event cap. Native trace data must pass exact frame/receipt reconciliation and stable input cadence before interpretation. See [current log](../../session-logs/2026-09-26-native-downshift-comparison.md).
