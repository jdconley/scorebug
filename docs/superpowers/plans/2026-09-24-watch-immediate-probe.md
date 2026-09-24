# Watch immediate-message diagnostic

**Goal:** determine whether actual WCSession immediate messages work when the
Watch reports reachability but rejects setup application context with WC7018.
This is a diagnostic, not a setup fallback or a pairing authorization change.

The existing paired harness provides one fresh experiment after unit checks and
review. Opt in separately with `SCOREBUG_WATCH_CONNECTIVITY_PROBE=1` in the two
companion UI tests. Only DEBUG watchOS code may initiate the probe, after a context
publication failure and while activation/reachability are true. Send exactly one
fixed byte (`0x00`) per adapter lifetime. This is deliberately invalid for both
production relay codecs; the existing phone delegate returns an empty rejection
reply before any scoring/bootstrap handler. A native empty reply proves a message
round trip only, not acceptance of a valid application command or context delivery.

A lock-protected gate reserves the single attempt before dispatch and admits one
terminal outcome (empty reply, unexpected reply, native failure, or two-second
monotonic timeout). Late/duplicate callbacks cannot change the result; losing
callbacks retain no payload. No credentials, endpoints, identities, message bytes
or error descriptions are logged. Existing diagnostic caps and explicit overflow
remain. Record the fixed probe's inbound observation on an opted-in phone, without
changing its existing invalid-message response. The paired run may still fail.

Use notice-level logging for the bounded diagnostic rows. Apple documents
[notice persistence and info memory-only defaults](https://developer.apple.com/documentation/os/generating-log-messages-from-your-code).
This is a retention hypothesis for the missing phone trace, not a proven cause.
No production retry/routing behavior changes. A successful probe could inform a
later authenticated setup-notice design; a rejected probe rules out that immediate
route for this experiment without declaring physical hardware unsupported.

- [x] Add gate regression tests: no opt-in/ineligible states, first eligible
  attempt only, invalid request cannot reach production relay, deadline/clock
  failure, duplicate/late callback and concurrent terminal claims.
- [x] Implement gate, native DEBUG-only send and fixed inbound observation.
  Keep callback epochs/peer revocation ahead of logging. Switch capped logs to
  notice and explicitly enable the probe only in companion UI tests.
- [x] Run Watch models; review; freeze sources; run one actual paired case using
  the existing owned simulator harness. Inspect raw events, API counts and cleanup.
- [x] Verify combined Release build and absence of both opt-in keys/subsystem;
  update plans with the actual result. Retain the previous failed paired attempt.


## Result: immediate route also rejected

The gate's six regression tests first fail against the empty implementation
(20 assertions), then all **64 Watch model/gate/diagnostic tests pass**. Independent
review approves the bound, terminal race handling, invalid-message rejection,
production exclusion and evidence scope. Both native simulator builds pass.

The fresh run `artifacts/qa/paired-watch-WWMaEj` **fails paired setup**. Notice-level
logging retains three phone rows and the 129-row Watch prefix including overflow:

- Phone activation succeeds; paired and Watch-app-installed are true. A later
  activation request sees reachability true.
- Watch activation succeeds, but companion-installed is false. Reachability is
  true by the first notice publication, which is rejected with WC7018.
- Watch row 6 is the single `probeStarted`, and row 7 is `probeFailed`, also WC7018.
  No successful reply or local timeout is recorded. The captured phone trace has
  no probe-received row. The native error, rather than mere absence of a receipt,
  establishes failure of this immediate attempt.
- Watch notice retries continue to be rejected. Row 129 is the explicit overflow
  marker; later activity is unobserved. ACX43 / “App database is out of sync” is
  still retained in the Watch system log. Improved phone-log retention is observed;
  this alone does not prove why its earlier info-level rows were absent.
- Watch UI fails waiting for setup after 183.562 seconds. Owned cleanup stops the
  waiting phone. The isolated database contains zero Watch pairings, score commands
  and media commands. No completed archive or scoring pass is claimed.

All **1,178 frozen source hashes** remain unchanged, and both owned simulators are
deleted. The combined unsigned Release phone/Watch build passes. Both executables
lack the diagnostic key, probe key and logging subsystem. Original rows, counts,
source comparison and Release fingerprints are in `probe-assessment.json`; joined
commands/results are in `artifacts/qa/watch-probe-verification.json`.

This rules out an immediate-message fallback for this observed simulator state.
Do not implement a setup fallback based on reachability alone, relabel the failed
paired workflow, or infer unsupported physical hardware. Older/newer simulator
and installation-order failures remain in `docs/native-watch-app.md`. A further
paired attempt needs a concrete companion-registration configuration change or
an independently minimal framework reproducer; physical-device testing remains
necessary. Continue independent local streaming endurance work meanwhile.
