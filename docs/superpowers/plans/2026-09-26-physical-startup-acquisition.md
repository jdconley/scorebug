# Physical recovery startup acquisition

Goal: qualify real-phone progressive recovery without treating worker output as completed source-health acquisition. Existing physical failures remain failures; no production health or adaptation policy changes in this slice.

Evidence: MJj7dD sampled too late; bUx6EQ observes startup from +11.786s but the ten-second source gate expires before acquisition. The worker uses five-second completed decoder windows; WorkerSourceIntervalTracker needs two consecutive windows. A later cadence-freshness reset remains a separate runtime question. Details belong in the September26 evening session log.

## Explicit physical contract

- Version the physical recovery evidence separately from format2 ordinary/simulator evidence. Ordinary qualifiers must reject the new physical contract and retain their existing ten-gate/ten-second startup rules.
- Observe initial encoder acknowledgment within10seconds of observed local publishing, before waiting for worker output. Require actual240p30/350000 ACK, revision0, same attempt, open/unencumbered state and inactive trial. This proves acknowledged encoder configuration, not source health; record explicit clock anchor/gate/milestone.
- After observed worker producing_output, allow30seconds for initial source acquisition. Require the existing complete owner/freshness/inactive-trial predicate and the exact initial acknowledgment/revision/attempt, so a later reset cannot substitute. Record the separate phase and timing anchor.
- The30second test acquisition budget covers two required5second windows, another acquisition boundary,3.5second capture-age allowance,2second observation cadence and5second accessibility bracket, rounded up. It changes no production timer, freshness limit or startup encoding behavior.
- Continue the complete adaptive sequence immediately and contiguously. Preserve later150/30/60second gates,540second recording budget, sample ordering/bounds, request clock brackets, causal receipts, no retries, cleanup and export.
- Preserve failure evidence/cleanup for an initial ACK failure as well as acquisition or later adaptive failure. Normal/default/ordinary/Watch/separate-scorer lane order remains unchanged.

## Work and acceptance

- [ ] Implement explicit physical evidence and native observation phases, with independent physical native/geometry qualifiers as needed; keep shared strict checks without accepting a caller-supplied relaxed budget.
- [ ] Add meaningful fixture/regression tests for valid physical evidence, missing/late ACK, missing/late acquisition, wrong initial revision/attempt/ACK, reset substitution, ordinary/physical contract confusion, and unchanged later guards.
- [ ] Independently review spec and quality; run focused tests and signed Debug build. No production change means the already verified Release bridge exclusion remains applicable.
- [ ] Run one physical recovery comparison with the now-confirmed lit moving scene, collect only its actual new archive UUID and both live MP4s, verify unchanged execution inputs and joined shutdown, then independently assess workflow/transport/geometry/media.
- [ ] Investigate any later cadence-freshness reset using its actual admission/capture/decoder timing before changing production behavior.

Root owns physical runs and media work. Freeze source and join builds/media analysis before capture. No privacy resets or permission requests are needed.
