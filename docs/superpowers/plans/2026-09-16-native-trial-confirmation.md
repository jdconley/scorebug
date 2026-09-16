# Native trial confirmation timing

Execute inline with red/green tests and bounded independent design/source review.
Run Swift, native/media and build commands sequentially in the validation worktree.

## Evidence and design

The previous native pass (`native-app-r29PCh`, checkpoint `fb9b3d6`) applied the
6→6.6 Mbps trial successfully. The first two uniform post-acknowledgment source
windows covered 9.999979750 seconds. Their final evaluation preceded the fixed
15-second deadline by only 33 ms; no third window could complete before rollback.
Changing frame counts or rounding measured coverage would weaken the evidence.

Use a bounded trial budget derived from the existing window contract:

- Up to 5.25 seconds from acknowledgment to the first uniform source-window start.
- At least ten actual seconds of contiguous strong post-change coverage.
- Up to one additional 5.25-second window to exceed ten seconds without rounding.
- The existing two-second evidence-arrival allowance.

This gives a 22.5-second hard deadline from native acknowledgment. Also explicitly
require the first probation window to start no later than acknowledgment+5.25;
a later start is unknown coverage and makes rollback sticky. This prevents the
larger deadline from quietly admitting an arbitrarily long initial evidence gap.
Weak/unknown/disconnected/rejected or gapped probation still requires immediate
rollback. Deadline polling remains independent of receiver reports. The trial step,
30-second qualification, ten-second confirmation, freshness, receipt ownership,
recording isolation and 60-second post-rollback cooldown remain unchanged.

The budget can wait longer for missing evidence than the previous 15 seconds, but
never establishes health from absence. Production remains disabled. Review the
bounded tradeoff and initial-gap rule before implementing.

## Work and gates

- [ ] Replay the measured source/ack/evaluation timeline as a failing Core regression.
  Add exact first-window-start and deadline boundaries, no-receiver rollback,
  sticky invalidation and late-evidence checks.
- [ ] Implement named coverage/deadline constants and the bounded initial-gap rule.
  Update actor tests and the independent JavaScript verifier consistently; its
  timing assertions remain independent of claimed exported deadlines.
- [ ] Add a fixture-only requirement for at least one confirmed native trial, so
  the previous timeout-only pass cannot satisfy this gate. Preserve basic trial/
  rollback qualification for explicitly requested older scenarios.
- [ ] Run Core, FilmModel and tooling tests, then an actual native simulator trial
  with raw pressure/source replay, full saved A/V decode, score and archive checks.
- [ ] If confirmation passes, run the structured-motion fixture with the same
  adaptive-control and recording gates. Preserve failures and diagnose them.
- [ ] Run relevant Apple builds, obtain source review, retain evidence hashes and
  commit a verified checkpoint. Physical phone/Watch and remote hosts remain open.
