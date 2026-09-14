# Motion calibration failure evidence and recovery

Use systematic debugging, TDD and bounded subagent implementation with independent
specification and quality reviews. Continue the motion plan without altering its
source, encoder profiles or acceptance gates while recovering useful evidence.

## Observed failure

The first motion calibration at `879404d`, `native-app-24AFo1`, failed the second
worker-producing-output UI check after scoring and the short hold. The worker's
first pipeline decoded 616 frames then ended naturally; it attempted restarts.
The receiver also ended naturally. Its saved video fully decodes but has corrupted
static barcode pixels and nonconsecutive decoded identities. Three complete
five-second video payload windows average 46.278 Mbps against the requested 6 Mbps.
The rate overshoot and stream interruption require separate causal investigation.

The original archive preservation manifest contains zero copied files and marks
container resolution incomplete. State lookup succeeded, no boot was attempted,
and get_app_container then failed with exit149. Cleanup five seconds later reported
CoreSimulator405/current Shutdown (405 mod256 =149). Xcode's earlier diagnostic
snapshot showed Booted. These facts support a shutdown transition race; raw error
text was suppressed, so the exact first failure cannot be proven. Normal cleanup
then deleted the owned simulator. Preserve this failed verdict and evidence.

## Bounded preservation repair

- [ ] Extend only the failure helper and focused tests. Retain existing allowlisted
  Recordings/QA copying, limits, original sources, safe metadata and owned UUID.
- [ ] Use a single total budget: at most two get_app_container resolutions and one
  boot/bootstatus sequence (including initial Shutdown). Read fresh owned state
  after the first lookup failure. Boot only on confirmed Shutdown; never reboot
  Booted or operate on another simulator. Missing/unknown states fail safely.
- [ ] Handle ShuttingDown with at most five 200 ms polling delays and six state
  reads per wait. Bound each state/lookup/boot command to10seconds and bootstatus
  to30seconds. Use an injected delay in unit tests. Exhausted transitions and a
  second resolution failure produce an incomplete manifest, without masking the
  original native workflow failure. A repeated shutdown cannot spend another boot.
- [ ] Retain a bounded resolution metadata object with allowlisted stage/state and
  counters (state reads, lookup attempts, boot attempts). No raw output, paths,
  credentials or arbitrary errors. Existing command logs retain exit/timeout.
- [ ] Reproduce booted→shutdown lookup failure red, then green; cover initial
  shutdown, stablebooted, unrelatedlookupfailure, repeatedshutdown, transition
  polling/exhaustion, missing/unknownstates and failedbootstatus. Run focused and
  full tools, then independent spec/quality reviews. No native builds needed.

The bounded design passes independent review. Parent owns media experiments;
implementation agent must coordinate any tests to avoid overlap with timed media.

## Next experiments

- [ ] Re-encode the saved clip with the unchanged worker VideoToolbox settings to
  isolate rate overshoot from live transport. Keep experimental options separate
  from production; measure packets and document failure/unsupported results.
- [ ] After preservation repair, repeat the same short native motion workload and
  capture archive/QA evidence. If interruption recurs, add bounded diagnostics at
  the missing transport/decoder boundary before guessing at a product fix.
- [ ] Return to motion calibration and three-/ten-minute holds only after failures
  are understood and unchanged continuity/media gates pass.
