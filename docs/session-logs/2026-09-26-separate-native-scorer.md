# September 26 — Separate native scorer and physical camera

Start: `e2c4b1b`, branch `codex/local-validation`, authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`.

## Scope

Verify one native simulator scoring app can take over, award/undo/award while the real phone records and publishes through the overlay proxy to both live recordings. This is an unimpeded role-separation smoke, not adaptive recovery or another physical phone/Watch qualification. Existing runner LAN-privacy and Watch developer-connection questions stay separate.

## Implementation and review

Added two explicit UI roles, a bounded launcher that builds before capture and owns one temporary simulator, and an independent durable-receipt verifier. The simulator scores with normal native controls and refuses capture permissions. The camera checks live/recording status between remote score changes, then continues its archive after live stops and exports the actual new UUID. Capture failures preserve terminal cleanup.

Native specification review corrected an initial HOME-ack race and prevented shared permission helpers from granting capture permission to the scorer. Launcher review required failed-run scorer inventory retention and clean committed source/binary provenance. Evidence review bound start/stop ACK selections and recording identity/start timestamp/sequence through final stop. Native quality review required finite duration baselines and actual advancement throughout the final hold. These are verification safeguards; production streaming policy is unchanged.

The combined first regression run found one mini Swift test harness missing the new default-disabled permission helper (45/46 passed). The harness now models that default and retains its original recovery teardown assertions. Final focused checks: 55/55 pass, including the actual scoring API/SQLite integration and rejection of contradictory receipts. Logs: `artifacts/qa/separate-native-scorer-validation/`. Swift parsing and diff checks pass. Builds and device run are next; no new media result yet.
