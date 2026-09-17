# Authenticated decoder cadence reporting

Continue the progressive-streaming measurement path through the existing worker
session, private pipeline-read identity, scoped media status and native decoder.
Negotiate `decoder-cadence-v1`; legacy APIs receive no new field. The existing
five-second report remains unchanged. Short snapshots are optional and never make
source-loss, timeliness, capacity or viewer-delivery claims.

The API validates bounded shape, immutable scope, monotonic progress/window
sequences and terminal invalidation. Retain history across omission to prevent
replay, but omit current evidence/freshness when omitted by the worker. A fresh
snapshot receives a server-owned age upper bound only with the recognized timing
token that preceded worker sampling. Add server residence and the phone's entire
request duration; never infer a new stall merely because a report went missing.
The phone requires the expected publishing-attempt identity and valid current
publication before exposing age-qualified cadence evidence.

- [x] Add failing negotiated reporter, schema/progression and authenticated route
      tests (legacy, mismatched scope, replay after omission, missing timing token,
      stale/failed clocks and contradictory windows).
- [x] Share cadence wire types, attach the atomic pipeline sample to the supervisor,
      negotiate reporter capability, validate/store/age snapshots at the API.
- [x] Add native optional decoding and a conservative freshness helper; test shared
      golden JSON, malformed evidence, wrong attempt and age/overflow boundaries.
- [x] Run protocol/worker/API/tooling tests, typechecks, Swift Core tests and both
      Apple builds. Verify actual worker measurements round-trip through authenticated
      route fixtures without changed content or invented freshness.
- [x] Freeze evidence and document remaining expected-source/lateness, short report
      scheduling and quality-controller integration before committing.

## Verified outcome

Shared `decoder-cadence-v1` types now carry optional one-/two-second snapshots and
progress through the pipeline's atomic sample, supervisor and negotiated reporter.
The API requires the current explicit private read identity and known transport
coordinates, checks source/window progression and permanently retires cadence
scopes within a worker session. Omission removes visible current cadence/age while
retaining anti-replay history. The existing five-second reports are unchanged.

The server-owned `decoderCadenceAgeUpperBoundMs` bounds the snapshot age using a
recognized pre-sampling timing token and server monotonic residence. It is separate
from the snapshot's window/frame ages. Missing/foreign tokens and failed monotonic
clocks provide no bound. Repeated status reads do not alter the worker's observed
stall flag. The native `WorkerDecoderCadenceFreshness` requires a valid current
publication and the caller's expected publishing-attempt UUID, adds the entire
request duration and local monotonic residence, checks overflow, and reports an
observed stall only within the caller's explicit snapshot-age budget. Malformed
optional cadence data leaves the surrounding status usable but cadence unknown.

Verification: 445 API tests, 361 worker tests, 323 Swift Core tests, one protocol
contract test and 1,205 tooling tests pass. Both TypeScript services typecheck.
The ARM64 simulator build-for-testing and unsigned combined iPhone/Watch Release
build pass. Node and Swift share byte-identical golden status JSON. Boundary tests
cover explicit null coordinates, wrong attempts, malformed/closed/invalid reports,
age limits/overflow, replay after omission, scope reuse and legacy negotiation.

Replay of all 661 actual samples from `decoder-cadence-native-Q8lxKX` through the
production authenticated API routes preserves their complete measured contents
and reconciles every snapshot-age bound under deterministic transit clocks. Both
unauthorized requests reject. The replay does not fabricate relay association:
its status has no publication claim; publication checks are separately covered by
existing association tests and native expected-attempt tests. This is route-level
replay of real decoder measurements, not a new physical-device or live SRT run.

The initial replay harness used an expired broadcast-command timestamp and was
correctly rejected before reporting; the rerun uses a current command timestamp.
The observed null-coordinate round-trip failure was fixed by explicitly encoding
nullable coordinates in the native wire model. All running process parents joined.
Sources/evidence are frozen in `artifacts/qa/cadence-report-final-verification.json`.

Remaining: qualify short report/poll reaction time (production worker reporting
still defaults to 1,000 ms), reconcile expected source identities and lateness,
then connect scoped evidence to the priority minimum-reset/recovery controller.
Two-second arrival counts are not a source-loss ratio, and startup bursts are not
proof of healthy on-time delivery. The phone can decode and validate this evidence;
the automatic quality driver does not consume it yet. No automatic increases,
production low-start behavior, physical Watch routes or remote-host readiness are
claimed by this checkpoint.
