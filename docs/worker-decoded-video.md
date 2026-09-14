# Worker decoded-video measurements

The worker now measures decoded video before frame capping, scaling, score overlay,
and output encoding. Optional `decodedVideo` snapshots travel through the existing
authenticated worker report and native status APIs. Older workers omit the field;
absence means unknown. Automatic quality changes remain disabled.

## Measurement and bounds

A separate FFmpeg filter branch normalizes timestamps to 90 kHz and emits a fixed
metadata marker with numeric frame headers to a dedicated descriptor. The existing
live filter branch keeps its original timebase. The guardian preserves separate
IPC, progress, and telemetry channels and always drains the telemetry descriptor.

The parser retains one ASCII line of at most 1,024 bytes and one pending header.
It requires consecutive frame ordinals and signed safe-integer timestamps. Invalid
framing, numeric values, missing records, overflow, clock reversal, or callback
failure latch an invalid result; subsequent input is discarded while draining.
Credentials and general FFmpeg diagnostics are never part of these observations.

The collector retains only the current and latest completed five-second window.
Strictly advancing presentation timestamps count as fresh; repeated and reordered
timestamps have separate counters. Long outages advance in constant time and yield
zero-progress windows. EOF discards the final partial window and preserves aging of
the last completed window. This measures timestamp cadence, not changing picture
content or delivery to a viewer. Timestamp gaps alone do not establish frame loss.

## Status semantics

Reports remain scoped to worker session, match, broadcast generation, and attempt.
Within an attempt, completed window contents cannot change, sequences/source ranges
cannot rewind, and terminality or invalidity cannot recover. Omitting telemetry
does not erase those guards. Copies at the reporter and API boundaries prevent
later mutations from rewriting stored evidence.

The API adds monotonic residence time to window age. Exact retries, new report
sequence numbers, and temporarily omitted telemetry cannot make a previously
reported window younger. Age remains a **lower bound**: worker-to-server transit
has not been measured. It is insufficient on its own to authorize an adaptive
increase. Swift uses Int64 for counters and source timestamps, including on 32-bit
Watch targets, and preserves explicit nulls within the new shape.

The API now also supports optional `timingToken` provenance and a separate
server-owned `decodedVideoAgeUpperBoundMs` status field. A worker must sample after
receiving the token and echo it with that observation. The server then adds the
entire monotonic interval from token issuance to receipt, plus status residence,
to the sampled decoder-window age. No cross-machine wall-clock comparison is used.
Current and previous tokens are bounded per session; lost acknowledgments and
exact retries do not refresh stored observations or token issuance times.

Upper bounds remain scoped to the match, generation, attempt, and decoder window.
Missing tokens cannot create a bound. Contradictory evidence or overflow makes
that window's bound unknown; clock failure disables timing evidence for the API
instance. Endpoints round outward before subtraction, and integer age additions
are checked before overflow. Legacy status responses retain their existing shape.

This API checkpoint passes 33 focused tests and the complete 240-test API suite,
plus protocol build and type checking. The shared `worker-report-age-v1.json`
fixture matches the complete deterministic HTTP response. Evidence is under
`artifacts/qa/worker-report-age-api-*`. The maintained worker now samples through a
synchronous supplier after token reception and resamples on session renewal with
a new sequence. It preserves marker provenance across lost acknowledgments, copies
the sample before asynchronous sending, and checks the total monotonic deadline
after synchronous work. Null observations do not report or log recovery. All 25
reporter tests and 132 total worker tests pass, as do worker/protocol type checking
and both reviews. Logs are under `artifacts/qa/worker-report-age-sampling-*`.

Swift now retains the optional upper bound and adds the full status request and
local ContinuousClock residence with exact checked Duration arithmetic. Immutable
evidence retains its match/generation/worker/attempt/window identity and expires
with process status. Missing, invalid, contradictory, ended or overflowing evidence
is unknown. Film clears it on lifecycle changes and ignores obsolete status errors
after Stop. All 119 Core and 50 Film model tests pass, as do the arm64_32 watchOS 10
Core and combined unsigned iPhone/Watch Release builds. Both reviews approve;
logs are under `artifacts/qa/native-worker-report-age-*`.

Running-app report-age qualification remains open; see
[the implementation plan](superpowers/plans/2026-09-14-worker-report-age.md).

The native proof exporter/comparator is implemented and reviewed, with 58 Film
model and 135 tooling tests passing. Its first isolated simulator attempt
(`native-app-mIqwM3`) failed due to a local recording queue overflow at 34.90 seconds,
before stop/export and media/report-age validation. That failure remains open;
it is not evidence that the report-age path or recording reliability is qualified.

## Qualification

Host software, host VideoToolbox, and the existing CPU container's FFmpeg 5.1.9
passed the same five timestamp fixtures: 30, 60, and 25 fps, a source gap, and an
acquisition lead. Decoder counts were 90/180/75/78/90; output counts remained
90/90/75/78/90. Exact source timestamps rescaled to 90 kHz matched telemetry, and
the existing cadence, A/V sync, and coverage gates passed unchanged.

An initial implementation normalized the live filter's timebase and dropped 30 of
90 frames in the 30 fps fixture. Moving normalization to the observation branch
fixed that regression without changing the acceptance gates. Full software worker
qualification also passed scoring, process restart, API/source outage recovery,
and match-end shutdown. Evidence and CPU reproduction instructions are under
`artifacts/qa/worker-decoded-video/`.

The wire tests cover shared TypeScript/Swift fixtures, large timestamps, malformed
data, retries, age, omitted telemetry, resets, and nested-copy ownership. The shared
Core package builds for arm64_32 watchOS 10. Independent specification and quality
reviews approved both the parser/pipeline and the wire. Final regressions passed:
187 API tests, 114 worker tests, 63 tool tests, one protocol test, and 89 Swift Core
tests. Type checking passed. Logs use the `artifacts/qa/decoded-status-` prefix.

The iPhone 14/iOS 17.5 native workflow (`native-app-C4vGTv`) also passed local
recording, live publication, native scoring/overlay update, stream stop while the
archive continues, export, and full decode of both MP4s. It retained all 1,273
archive frames and all 891 live frames within the live source interval, at 30 fps.
Five decoder windows reached the authenticated API: a startup burst of 245 frames
followed by four windows of 150 frames, with no duplicate or reordered timestamps.
Buffered startup processing is distinct from sustained source or viewer cadence;
source-time interval correlation remains necessary before policy integration.

The final rerun with the corrected invalidation checks (`native-app-bajC50`) also
passed: 1,301 archive frames and 861 live frames, 30 fps and zero source-frame loss
within each recorded interval. The API received a 240-frame startup window and three
150-frame steady windows, all valid with no repeated/reordered timestamps. The
archive continued 214 source frames beyond the live stream. Maximum measured live
A/V offset was 65.92 ms and final track-end separation was 14.13 ms; the existing
100 ms gates were unchanged. The Release iPhone build also passed.

Capture and encoder counters, correlation across source intervals, qualified
capacity estimates, complete transport-age bounds, resolution transitions,
impairment tests, and sustained hardware qualification remain open. See the
[runtime telemetry contract](adaptive-telemetry.md).

The transit-inclusive report-age slice now passes the maintained iPhone 14/iOS 17.5
fixture with the local Mac VideoToolbox worker (`native-app-yCntsf`, `9679081`). Both
native helper proof windows match independent API readings, including exact request
and local-residence additions. All existing media gates pass: 1,225 archive frames,
799 acquired live frames at 30 fps, and four steady observation windows matching
600 decoded frames. Maximum live marker offset is 65.25 ms; end alignment is
−17.567 ms. This closes that report-age checkpoint, not adaptive enablement.

Thirteen terminal frames completed by the native encoder are absent from the sink.
The next diagnosis must distinguish transport receipt, worker decoder completion,
and output drain; synchronized track ends alone cannot establish full delivery.
The earlier archive overflow remains unresolved. See the
[native tail evidence and plan](superpowers/plans/2026-09-14-native-tail-diagnosis.md).


The optional terminal diagnostic now retains a separate lifetime decoder aggregate,
final validated output progress, genuine encoder exit evidence and telemetry EOF.
It leaves the five-second report snapshot unchanged. The owned native fixture saves
bounded sanitized lifecycle events after worker close, including failure cleanup.
153 worker tests, 163 tool tests and type checking pass; both reviews approve.

At `4884734`, native run `native-app-VrXKA9` passes all existing gates with 1,252
archive frames and 856 live frames at 30 fps. The worker decoded 869 fresh frames
and reported 869 packets at output progress, then exited 0 without a stop signal.
The sink therefore has a 13-frame count deficit after decoder ingress. An independent
short-burst replay supports MediaMTX recorder shutdown loss: 120 encoded/submitted
video packets yield 112 saved frames with immediate EOF versus 119 with a one-second
EOF delay. This is diagnostic evidence, not an application fix or exact attribution
of the native deficit. The next step is an independently qualified test recorder;
see the [tail investigation](superpowers/plans/2026-09-14-native-tail-diagnosis.md).
