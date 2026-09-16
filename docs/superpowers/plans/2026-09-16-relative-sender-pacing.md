# Qualify explicit relative sender pacing

Continue from 5407dde (progress). Queue timelines identify 374 KB arriving in a
100-ms bin, 1190 overflow packets, and 526 ms queue residence despite 400 ms
recovery. No prior workloads remain live. This supports a bounded sender-pacing
experiment; it does not establish which packets contain particular damaged frames.

Design: optional API `SRT_PUBLISH_PACING=relative` adds `maxbw=0` only to the native
publish URL. Unset preserves current behavior, read URLs and capability identity.
Leave inputbw at its native automatic default and recovery allowance at its native
25% default. No quality-policy, encoder, queue or freshness changes. SRT documents
relative pacing and cautions that abrupt bitrate changes complicate estimation:
https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md#SRTO_MAXBW .

Retain actual native `mbpsMaxBW` and `usPktSndPeriod` on existing timestamped
transport samples as optional validated diagnostics. They are effective pacing
measurements, not estimates of available network capacity or delivery evidence.
The current baseline has no explicit maxbw setting; its exact runtime gauge was
not retained. Do not claim a measured baseline value from the library default.

- [x] Red configuration/grant/HTTP/fixture and scalar/export/verifier tests.
- [x] Implement explicit option and actual native pacing evidence. Preserve all
      existing sample freshness/counter semantics and independent quality gates.
- [x] API tests/build, media/streaming/app-model tests, tooling, unsigned combined
      Apple Release build and read-only review. Heavy Apple workloads sequential.
- [x] Snapshot source and repeat 240-second native rate4m fixture with slice decoding,
      400 ms recovery, relative pacing as the only behavior-setting change.
- [x] Independently verify archive, live media, native receipts/raw pressure replay,
      effective pacing, queue timing and partial relay counters. Preserve failures.
- [x] Join owners, verify cleanup, hash terminal evidence, document and commit.
      Promote no default or production adaptation without full qualification.

## Verification before the native run

Causal red tests cover missing API option/URL forwarding, absent fixture parser,
missing native scalar properties and ignored malformed raw pacing evidence. Final
checks pass: 391 API tests and API build, 254 media tests, 61 streaming tests, 209
app-model tests, 1009 tooling tests, unsigned combined iPhone/Watch Release build
and read-only review. No vendored SDK code changed. Runtime source is snapshotted
against 5407dde before the native experiment.

## Native result

`native-app-d4raOd` differs from the preceding queue-timeline run only by explicit
relative pacing in saved native/media/network settings (plus the new scalar
observations in source). Native UI workflow succeeds; the full runner fails on
non-monotonic decoded source identities. Supplemental analyses preserve this gate.

- Archive: all 8195 consecutive 1080p/30 frames over 273.167 seconds, all 136 audio
  markers, 5.3 ms end-coverage difference and zero rejected/dropped queue samples.
- Native: 7826 consecutive published frames; all 85 local pressure windows replay;
  all four profile applications bind to real native receipts within admission and
  completion budgets. First decrease acknowledgment is 60.787 seconds after
  bootstrap; the upward trial rolls back after about 1.30 seconds.
- Effective pacing is measured on all 1000 retained native samples: bandwidth
  ceiling 4.782–12.238 Mbps (median 7.946), packet interval 794–1964 microseconds.
  Settled 1080p phases have median ceilings about 8.04 Mbps and 540p phases about
  4.82–4.83 Mbps. The brief upward trial temporarily retains a lower ceiling; these
  measurements support the documented adaptation lag but do not by themselves
  establish its causal contribution to missing frames. Actual publishing recovery
  remains 400 ms, read-leg delay 120 ms, and source evidence median age 1.598 seconds
  (range 1.487–1.728) under the unchanged two-second limit.
- Both queue timelines reconcile without omissions (2623 sparse bins each).
  Forward overflow falls from 1190 to 898 packets, largest receive bin from 373780
  to 138244 wire bytes, but maximum residence remains 525.55 ms. Reverse drops stay
  zero. Overflow clusters span about 60.84–62.34 and 113.44–115.64 seconds after the
  first proxy packet. These are local bin bounds, not native callback alignment.
- Live: 7624 pictures across 7766 source positions (142 count deficit), 174 absent
  unique identities, 32 repeated observations, 12 non-increasing barcodes and 14
  identity/cadence anomalies. The worst receiver window falls from 22 to **14.6 fps**.
  A/V end coverage passes; positive audio-PTS gaps total 128.6 ms. The worker reports
  218 decode-error messages and the relay reports one lost/recovered timing episode.
  Neither those message counts nor PTS freshness establish picture integrity.

Decision: keep relative pacing opt-in, never promote it to a reliability default.
It demonstrably reduced bursts/overflows in this run while worsening delivered
cadence and unique frame loss. Sequential runs do not establish a general ranking,
but this candidate does not meet the existing requirements.

Before another pacing/latency setting, retain **actual pre-mux frame byte size and
random-access/keyframe evidence** through geometry transitions, and compare recovery
with the next available clean IDR. Current format receipts establish dimensions and
encoder continuity but omit those facts. The prior native-property checkpoint has
already found MaxFrameDelayCount unsupported and low-latency session creation
unavailable on the simulators; do not repeat those knobs or assume requested
bitrate equals output. Physical encoder behavior still needs device qualification.
Keep source freshness, packet queues, floor cadence and archive gates unchanged.
Production adaptation, physical Watch/iPhone networking, long soaks and other hosts
remain open. Available disk after this run was about 18 GiB; avoid unnecessary
media/build duplication in further local validation.

Evidence: `artifacts/qa/sender-pacing-*`, source snapshot and native artifact analyses.
All test, build, native and supplemental analysis owners are terminal/joined. Final
verification checks exact simulator/container cleanup, stopped collection, runtime
source equality and stopped-QA equality before hashing terminal evidence.
