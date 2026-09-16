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

- [x] Replay the measured source/ack/evaluation timeline as a failing Core regression.
  Add exact first-window-start and deadline boundaries, no-receiver rollback,
  sticky invalidation and late-evidence checks.
- [x] Implement named coverage/deadline constants and the bounded initial-gap rule.
  Update actor tests and the independent JavaScript verifier consistently; its
  timing assertions remain independent of claimed exported deadlines.
- [x] Add a fixture-only requirement for at least one confirmed native trial, so
  the previous timeout-only pass cannot satisfy this gate. Preserve basic trial/
  rollback qualification for explicitly requested older scenarios.
- [x] Run Core, FilmModel and tooling tests, then an actual native simulator trial
  with raw pressure/source replay, full saved A/V decode, score and archive checks.
- [x] If confirmation passes, run the structured-motion fixture with the same
  adaptive-control and recording gates. Preserve failures and diagnose them.
- [x] Run relevant Apple builds, obtain source review, retain evidence hashes and
  commit a verified checkpoint. Physical phone/Watch and remote hosts remain open.


## Review and deterministic evidence

Independent design and source reviews approve the bounded tradeoff. The captured
native timeline first failed seven Core assertions under the old behavior, then
passed with the new deadline and initial-gap rule. All 281 Core and 162 FilmModel
tests pass; the targeted verifier/options set passes 49 tests. The original
9.999979750-second coverage still does not confirm until a third strong window.
`SCOREBUG_TEST_NATIVE_CONFIRMATION=1` explicitly requires a confirmed trial in
addition to the existing native quality fixture prerequisites; timeout-only traces
remain acceptable only to the older basic trial/rollback gate.

Before subsequent impairment qualification, test adaptation when remote receiver
windows expire altogether. The current driver evaluates matched source intervals;
trial deadline rollback alone does not cover bitrate reduction outside an active
trial when no fresh matched receiver window is available. Any local-pressure
fallback requires its own aligned evidence, review and native impairment proof.


## Barcode confirmation pass

`native-app-3Tq0lq` passes the complete 90-second confirmation-required fixture on
iPhone 14 / iOS 17.5. Seventeen evaluated windows produced two native bitrate
trials: the first 6→6.6 Mbps trial was confirmed after sufficient actual coverage;
the second 6.6→7.26 Mbps trial began near the end and was still unconfirmed at stop.
No rollback occurred. Do not label the final 7.26 Mbps setting as confirmed.

All 3645 archive frames (0–3644) and 3236 acquired live frames (226–3461) survive,
with the live file reaching the final encoded source frame. Both fully decode at
30 fps with zero qualified loss. Native scoring, overlay, export, A/V, source,
processing, raw pressure, publication/age and archive gates pass. The recorded
configuration explicitly requires confirmation. Structured-motion qualification
also passes below with the same controls and unchanged workload/continuity gates.


## Structured-motion confirmation pass

`native-app-UN3C23` passes the complete 90-second `blocks16` confirmation-required
fixture. It also records 17 evaluated windows, two native trials, one confirmed
6.6 Mbps trial and no rollback; the second 7.26 Mbps trial remains unconfirmed at
stop. All 3696 clean archive frames (0–3695) and 3266 acquired live frames (216–3481)
survive at 30 fps with zero qualified loss. The live file reaches the final encoded
source frame 3481. All scoring, export, A/V, publication/age, raw pressure/processing
and archive gates pass, including the frozen structured-motion payload bands.

Across complete five-second packet windows, clean archive video measures
12.0265392–12.1295472 Mbps (24 windows); live video measures 7.33804–7.6498384 Mbps
(20 windows). These are actual saved packet payload rates, distinct from the native
6.6 Mbps target receipt and the worker's configured target. This demonstrates the
control path under substantial synthetic video demand; it does not establish a
network ceiling, subjective sports-video quality or physical-device capacity.

The barcode confirmation occurred 19.959536 seconds after acknowledgment with
14.999625 seconds of actual strong coverage, beyond the former deadline. This is
an actual regression proof, not only a changed unit-test expectation.

Final verification: 281 Core, 162 FilmModel and 842 tooling tests pass; combined
unsigned iPhone/Watch Release, arm64_32 watchOS 10 Core compilation and formatting
checks pass. Independent source and saved-evidence review finds no material issue.
The local manifest `artifacts/qa/trial-confirmation-final-verification.json` hashes
source and retained native/media/test evidence. Network impairment, local-pressure
fallback when receiver evidence is unavailable, longer adaptive soaks, resolution
changes, production activation, physical phone/Watch and remote hosts remain open.
