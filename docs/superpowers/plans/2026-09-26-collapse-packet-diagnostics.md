# Collapse packet diagnostics implementation plan

**Goal:** Attribute the ordinary720 bandwidth-collapse loss to original or retransmitted SRT traffic before choosing a media fix.

**Design:** Reuse the existing bounded, payload-free packet observer and immutable exporter. Add an optional `origin: "constrain"` to the existing packet capture window; it requires explicit forward rate control and anchors to the exact constrained-phase receipt timestamp. Unset origin retains first-peer behavior. Count excluded traffic before/after the capture, preserve existing byte/event/parser limits and observer-error reporting, and never change queue, rate, admission or transport decisions. The recovery device lab explicitly enables a0–25000ms window at constrain; normal non-recovery labs stay unchanged. This covers the observed first loss and immediate fallback without guessing when adaptive ramping ends.

Fixed wall-clock capture is simpler but may miss a variable-time climb. Whole-run capture can exhaust the existing32MiB limit before the fault. Constraint anchoring is the smallest precise diagnostic change; it does not qualify media or claim a fix.

- [x] Add socket tests to `scripts/test/srt-packet-diagnostics-integration.test.mjs`: real baseline traffic excluded, exact receipt origin, constrained and restored packets captured with original/retransmit flags, terminal joined export, late traffic excluded, never-constrained closed capture empty, invalid origins/control combinations rejected. Observe causal red.
- [x] Implement validation/anchoring in `scripts/udp-impairment.mjs`; enable the explicit25s window in `scripts/device-lab.mjs` only inside publisherRecovery. No app/encoder/policy changes.
- [x] Run packet parser/integration, UDP control/socket/timeline, device-lab and ordinary-runner tests; format/check diff. Independently review the source and tests before capture and commit the reviewed slice.
- [ ] Run the same ordinary720/700ms source and faults after all test jobs join. Confirm packet origin equals the retained constrain receipt, no observer/capture overflow, and retain native/transport/geometry plus full three-output media results.
- [ ] Attribute first overflow burst, unique originals, retransmissions, NAK/ACK activity and affected MPEG-TS source intervals. Report observed facts and unresolved boundaries; select the next root-cause action. Failed results remain failed.

Evidence/session history: [current session](../../session-logs/2026-09-26-collapse-packet-diagnostics.md). Physical paired acceptance remains pending Watch unlock and takes priority if devices become ready before a new capture.
