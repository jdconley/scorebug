# Delivery deadline evidence implementation plan

> Use executing-plans and TDD inline; request independent review before freezing evidence.

**Goal:** Establish bounded individual decoder-arrival evidence and classify captured source frames by a configured delivery deadline without assuming synchronized phone/worker clocks.

**Architecture:** A worker timeline retains at most 256 decoder arrivals, including duplicate/reordered PTS, with consecutive local ordinals. Snapshots express arrival ages and the age of the complete retained coverage boundary relative to one worker sample. Dropping history advances that boundary; it can never imply missing frames outside retained coverage. Native classification consumes an explicitly scoped timeline, a conservative sample-age upper bound, and a complete native source window. It converts remote elapsed ages to native time intervals, uses each captured frame once, and returns on-time/late/missing/uncertain counts. Any uncertainty prevents complete healthy evidence. The latency budget is explicit and not an asserted industry constant.

**Scope:** This implements the evidence producers and conservative classifier, with real FFmpeg observation. Authenticated reporting, native PTS/configuration matching, source-window completeness and policy integration remain required next; this component alone cannot authorize a quality increase. Keep production automatic adaptation disabled. The optional pipeline timeline is enabled only by the new local experiment until its negotiated reporting is wired.

- [x] Add failing worker tests: 256-entry retention, dropped coverage, duplicate/reordered arrivals, monotonic sampling, malformed/ended states and immutable snapshots.
- [x] Implement shared version-one timeline model and optional worker pipeline observation, independently of five-second/cadence counters.
- [x] Add failing native Core tests: exact deadline boundaries, conservative remote clock bounds, 3/60 vs 4/60 missing/late, 23 vs 24 on-time frames, duplicate/reordered and buffered bursts, incomplete coverage, stale/ended/wrong-scope/invalid input.
- [x] Implement the pure native classifier. Admit only 1- or 2-second windows, <=240 expected frames, <=256 arrivals, strict source ordering and finite bounded times. Require complete coverage from before each capture through its deadline. Check integer ordinals and safe transport coordinates. Choose the first arrival for each source frame; later duplicates cannot change a missed deadline.
- [x] Use a shared golden JSON timeline in worker/native tests. Run protocol/worker/Core suites and worker/API typechecks, then Apple model/simulator/Release builds as appropriate to exported Core types.
- [x] Exercise the optional observer through actual FFmpeg with a controlled source pause and resume, inspect bounded timeline snapshots and exact source identities independently, and retain raw evidence. Classify synthetic native capture bounds separately; do not claim the fixture proves phone-to-worker latency.
- [x] Review, document next authenticated-source binding gate, freeze source/evidence hashes and commit.

## Classification contract

For native evaluation time N, authenticated conservative sample age A, and worker arrival age d, that arrival lies in [N-A-d, N-d]. It is proven on time only if the upper bound is <= capture+budget, proven late only if the lower bound is > that deadline, and uncertain otherwise. Complete source-window deadlines must precede N-A. The retained coverage boundary's latest possible native time must strictly precede the first capture, so an omitted earlier duplicate cannot be mistaken for a missing/late first arrival. Never use worker absolute timestamps in native comparisons. A missing reply remains unknown.

Expected frames come from an independently validated complete native source window; this classifier cannot infer omitted camera frames or configuration coverage from a supplied array. Its output explicitly separates known failures from uncertain frames, and cannot expose a complete on-time FPS/loss ratio until all frames are classified. Native capture-rate, receipt/profile and source-history validation remain the adapter's responsibility.


## Verified checkpoint

Real local FFmpeg fixture `decoder-delivery-native-AQldhi` passed with 478 decoded
video frames, 661 snapshots, and a 256-entry retained tail. The fixture uses loopback
UDP and pauses its owned source process; it does not inject SRT network impairment
or measure a physical phone's capture-to-worker latency. Decoder silence was observed
1,004.770 ms after source pause and progress resumed 26.068 ms after source resume.
The saved H.264/AAC output fully decoded without errors. Frame acquisition before
the observer's first frame is outside this completeness claim.

Independent reconstruction matches every observed ordinal and PTS to the existing
terminal decoder history, intersects arrival-time bounds across samples, checks
retired coverage against the removed arrival, and verifies the frozen terminal
sample. Six corruptions (PTS, ordinal, coverage, age, scope, size) are rejected.
The maximum compact snapshot is 14,492 bytes: at 10 Hz, full snapshots would consume
1,159,360 bits/s before HTTP overhead. Use bounded deltas/coalescing for reporting;
do not send the whole ring at the previously tested cadence-report frequency.

Review caught a deadline equality bug: missing-frame classification now requires
that the last deadline be strictly past, consistent with permitting an arrival
exactly at its deadline. The regression failed on the old implementation and passed
after the fix. Review closed with no remaining important findings.

Validation: 1 protocol, 371 worker, 358 Core, 1,272 tooling and 252 native model tests
pass, as do worker/API typechecks, ARM64 simulator build-for-testing and unsigned
combined iPhone/Watch Release build. Final Core/Apple checks followed the boundary
fix. Raw logs, initial failures, independent checks, source inventories and parent
exits are retained in `artifacts/qa/delivery-deadline-final-verification.json`.

## Next integration gate

Negotiate and authenticate compact delivery reports, bind them to the current
worker/publication/attempt and complete native source/configuration windows, and
carry a conservative sample-age bound. A missing reply or truncated source history
must stay unknown. Qualify that path through real capture before using these results
for reset/recovery decisions. Candidate bandwidth headroom, upward trials,
minimum reconnect, physical devices and remote workers remain separate gates.
