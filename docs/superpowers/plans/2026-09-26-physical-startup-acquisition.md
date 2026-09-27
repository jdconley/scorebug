# Physical recovery startup acquisition

Goal: qualify real-phone progressive recovery without treating worker output as completed source-health acquisition. Existing physical failures remain failures; no production health or adaptation policy changes in this slice.

Evidence: MJj7dD sampled too late; bUx6EQ observes startup from +11.786s but the ten-second source gate expires before acquisition. The worker uses five-second completed decoder windows; WorkerSourceIntervalTracker needs two consecutive windows. A later cadence-freshness reset remains a separate runtime question. Details belong in the September26 evening session log.

## Explicit physical contract

- Version the physical recovery evidence separately from format 2 ordinary and simulator evidence. Ordinary qualifiers must reject the new physical contract and retain their existing ten-gate/ten-second startup rules.
- Observe initial encoder acknowledgment within 10 seconds of observed local publishing, before waiting for worker output. Require actual 240p30 / 350,000 bps ACK, revision 0, same attempt, open/unencumbered state and inactive trial. This proves acknowledged encoder configuration, not source health; record explicit clock anchor/gate/milestone.
- After observed worker producing_output, allow 30 seconds for initial source acquisition. Require the existing complete owner/freshness/inactive-trial predicate and the exact initial acknowledgment/revision/attempt, so a later reset cannot substitute. Record the separate phase and timing anchor.
- The 30-second test acquisition budget covers two required 5-second windows, another acquisition boundary, 3.5-second capture-age allowance, 2-second observation cadence and 5-second accessibility bracket, rounded up. It changes no production timer, freshness limit or startup encoding behavior.
- Continue the complete adaptive sequence immediately and contiguously. Preserve later 150/30/60-second gates, 540-second recording budget, sample ordering/bounds, request clock brackets, causal receipts, no retries, cleanup and export.
- Preserve failure evidence/cleanup for an initial ACK failure as well as acquisition or later adaptive failure. Normal/default/ordinary/Watch/separate-scorer lane order remains unchanged.

## Work and acceptance

- [x] Implement explicit physical evidence and native observation phases, with independent physical native/geometry qualifiers as needed; keep shared strict checks without accepting a caller-supplied relaxed budget.
- [x] Add meaningful fixture/regression tests for valid physical evidence, missing/late ACK, missing/late acquisition, wrong initial revision/attempt/ACK, reset substitution, ordinary/physical contract confusion, and unchanged later guards.
- [x] Independent spec and quality reviews approve the six-file startup slice; all 182 focused tests pass, including 49 physical fixture tests.
- [x] Signed Debug phone/Watch and Release builds pass with the cadence diagnostic; positive Debug and negative Release binary checks pass for both diagnostic and bridge.
- [x] Run the lit-scene physical comparison and collect only its actual new archive plus both live MP4s. Initial encoder/source observations pass; inputs stay unchanged and shutdown joins. All three files fully decode with continuous encoded A/V and visible changing content/overlay.
- [ ] Qualify the complete ramp/collapse/recovery sequence: the current attempt stays240p and fails initial360 increase before impairment. Full native/transport/geometry recovery remains unqualified.
- [ ] Investigate the actual candidate admission and readiness blockers before another unchanged run. The first probe lacks demonstrated headroom; a retry rejects receiver-time bounds. Earlier cadence-freshness resets remain a separate unqualified path.

Root owns physical runs and media work. Freeze source and join builds/media analysis before capture. No privacy resets or permission requests are needed.
