# Measured native adaptation through an impaired link

> Execute inline with `superpowers:executing-plans` and test-first verification.
> The user authorized autonomous implementation. Reuse installed simulators and
> retain all existing production gates and failed evidence.

**Goal:** Carry the representative native file route through an owned UDP impairment
proxy, measuring candidate admission, complete local recording and delivered A/V
under explicitly recorded packet loss and delay.

**Architecture:** Reuse the existing bounded UDP proxy and staged candidate route.
Allow only complete file/measured/staged/no-decoder-fault combinations with an
explicit `passthrough` or `loss0p2-delay30` uplink. Forward both validated profile
and generated loopback port into the DEBUG simulator. Production stays unchanged.

**Tech stack:** Swift, XCTest, SRT/MPEG-TS H.264/AAC, Node UDP, local relay and proxy,
FFmpeg decode and existing independent media/policy validators.

## Design and scope

A second source-content-only run would not exercise the missing network boundary.
A severe timed outage immediately requires a different media-loss acceptance
contract. Start with continuous modest impairment on the complete measured route,
then add causal capacity drops/outages separately. This does not replace that work.

`loss0p2-delay30` configures each direction with 30ms delay, every 500th datagram
removed (0.2% by ordinal, including control traffic), no rate limit, and the existing
2048-byte datagram/16KiB burst/256-packet/256KiB queue caps. These are reproducible
laboratory parameters, not standards-derived production thresholds or a claim of
real cellular behavior. Keep the sparse 100ms payload-free timeline. Require
actual injected drops in both directions, exact conservation, zero unintended loss,
complete timeline accounting and joined cleanup. Configuration plus queue tests
establish the delay mechanism; sparse maxima are not per-packet timestamp traces.

Use a 90-second hold with a validated prepared source at least180 seconds long.
No decoder fault or repeated campaign is mixed into this first link test. Require
the existing full staged measured admission and confirmation, 240→360 profiles,
recording ownership/continuity, source/receiver/worker clocks, score raster evidence,
all decoded frames and expanded natural-audio anchors. Failure must remain failure;
do not weaken admission, deadline, cadence or media limits to obtain a pass.

## Tasks

- [x] Add pure immutable uplink configuration and a complete static-impairment
      validator in `scripts/native-measured-uplink.mjs`; test exact configuration,
      omitted evidence, malformed counters, missing drops, unintended loss and
      timeline disagreement. Preserve behavioral red/green checks.
- [x] Extend host leaf file contract and existing measured/uplink selectors to
      accept only complete explicit staged file combinations. Keep user-supplied
      ports, mixed sources, incomplete probes and combined fault modes rejected.
      Add compositional tests before implementation.
- [x] Add a nonrecursive native route predicate and exact profile/port forwarding
      through project.yml, NativeStreamingTests and VideoObservationFixture. Keep
      production and all other experiment routes unchanged. Add native invalid-
      combination tests, run full tooling/model tests and independent review.
- [x] Execute and preserve frozen installed-runtime real-file impaired attempts;
      join owners, assess failure evidence, verify hashes and cleanup, and update
      the main plan. The three attempts below remain failed full qualifications.
- [ ] Qualify a measured increase under this impaired link after network-aware
      admission and pressure work. Require full media/audio/policy checks and
      matched images; static impairment does not prove causal outage recovery.

Next after this slice: causal bandwidth drop/outage with observable recovery,
production controller/provider integration and wider profile selection; physical
phone/Watch/camera and other proxy hosts retain their separate acceptance gates.

## Preflight checkpoint

Behavioral red/green tests cover both the packet contract and complete host/native
route composition. All 3,656 tooling tests, 73 focused native selector tests and
522 app-model tests pass. Code review found one remaining candidate UI assertion
that prohibited proxy ports; it now permits only the explicit file/headroom/profile
combination and retains rejection for other candidate routes. Admission and media
thresholds are unchanged.

The required staged relay tag was absent locally. Its exact historical build
context was restored from commit 693f962 (vendor/MediaMTX), without changing the
current vendor tree or retagging a newer relay. Build and version checks joined
with exit 0; version is `v1.21.0-scorebug-staged-probe-hd-v2`, image ID is
`sha256:ca29df4c78ce6c0b3cda955bda17ec32c576d1894eb839110561f3c794a30d47`.
Provenance, context hashes and commands are retained in
`artifacts/qa/staged-measured-relay-lo6wvont/`. This is a source-matched rebuild,
not a claim of bit identity with an unavailable historical image.

## First impaired attempt: insufficient negotiated recovery delay

Frozen `native-app-6nexd8` / `measured-link-freeze-r87zoolw` is a failed full
qualification. UI passed in 166.688s, but the quality export grew to 17,126,924 bytes
and exceeded its unchanged 8MiB parser bound. It contains 479 events, 456 of them
local-pressure decisions; there were no upgrades. All 458 unique transport samples
have RTT 62.885–100ms with negotiated sender delivery delay 120ms, violating the
existing four-RTT guard in every sample. This is not evidence to relax the guard or
raise the export bound. Persistent full-history diagnostic duplication remains a
separate pressure-path limitation to address before long impaired runs.

An independent UDP-only replay passes: 34 forward and 15 reverse datagrams were
injected drops, with no overflow, oversize or close discard, complete accounting,
closed queues and no socket errors. All 1,206 frozen hashes stayed unchanged; owned
simulator/container, API listener and case processes are absent. The failure and
app exports are retained. UI and UDP accounting do not qualify adaptive media.

Correct the experiment's SRT configuration: the loss/delay route now requires the
existing explicit host peer-latency option set to 400ms, and the native loopback URL
validator requires exactly one `peerlatency=400` query item. It preserves all query
encoding and credentials while changing only the owned proxy port. Other file
routes keep their previous no-override selection. This accommodates the measured
RTT and startup estimate within the existing four-RTT guard without changing the
1.5s delivered-frame deadline, buffer/RTT/retransmission limits or admission policy.
[Haivision's latency guidance](https://doc.haivision.com/SRT/1.5.3/Haivision/latency)
recommends approximately four RTTs for a link with 0.1–0.2% loss without significant
bursts. 400ms is this experiment's explicit budget, not a universal production default.
Behavioral host/native tests reject absent, 120ms, noncanonical or duplicated latency
settings before another run. A fresh complete run remains required.

## 400ms attempt: delivery latency remains above the deadline

`native-app-Lmh1Pk` / `measured-link-freeze-2jp5cwvs` remains a failed full
qualification (joined exit 1). The UI passes in 164.148s, but no candidate
measurement is created. All 437 retained transport samples negotiate 400ms and
none violates the four-RTT guard. The bounded quality export has 145 events:
105 delivery failures, 18 local-pressure decisions, three time rejections and no
candidate or application. All 157 delivery buckets have zero on-time frames.
Matching 3,149 present source IDs to their retained arrival evidence gives lower
latency bounds of 1.626–1.658s and upper bounds of 1.648–1.780s. These exceed the
unchanged 1.5s deadline; this is not merely stale-feedback uncertainty.

The independent file-recording lifecycle check passes; full adaptive/natural-audio
qualification is incomplete. UDP accounting passes with 34 forward and 16 reverse
injected drops, no unintended loss or socket errors. All 1,206 frozen hashes match;
owned simulator/container, API listener and case processes are absent. See its
`failure-assessment.json` for exact scope and retained evidence.

The next controlled experiment changes only worker input decoding to the existing
explicit slice mode. [FFmpeg documents](https://ffmpeg.org/ffmpeg-codecs.html#Codec-Options)
additional decoder delay from frame threading. Earlier project evidence in
[the decoder-threading plan](2026-09-16-worker-decoder-threading.md) observed about
0.5s less receiver age with slice mode, but does not prove the cause of this run.
Allow `SCOREBUG_TEST_DECODER_THREADING=slice` only on the complete loss/delay file
route; absent retains automatic decoding so this failed configuration remains
reproducible. All other file routes retain their no-override contract. Test route
composition first, then rerun with the same transport, deadline and media limits.
A pass or failure must still be decided by complete evidence; retransmission
pressure and probe admission may expose further limitations after decoder delay.

Pre-run review found a separate admission incompatibility in the existing native
`SRTBandwidthProbe`: it requires RTT at most 50ms and no retransmission-counter
increase. This link measures at least 63ms RTT, so correcting decoder delay alone
cannot qualify the full measured route. Preserve those existing gates for this
single-variable diagnostic; its purpose is to measure whether slice mode removes
the observed deadline failure. Then design network-aware probe admission and
sustained pressure handling from the measured evidence, rather than labeling this
experiment a likely complete pass or silently relaxing its verifier.

## Slice diagnostic: deadline restored, admission still fails

`native-app-0DZ6v4` / `measured-link-freeze-9x8b7uat` is also a failed full
qualification (joined exit 1, missing candidate measurement). UI passes in
163.612s. Its recorded configuration selects slice decoding, 400ms publishing
recovery delay, the same loss/delay profile and the unchanged 1.5s deadline.
All 157 retained delivery buckets now have 30 on-time fps, zero late/missing/
uncertain frames. All 6,270 matching observations have lower latency bounds
1.127–1.179s and upper bounds 1.148–1.283s. The approximately 0.5s improvement
versus automatic decoding supports the decoder-buffering hypothesis in this local
workload; it is not a universal host/codec latency guarantee.

The staged probe records `operationFailed` with no events. All 438 retained
transport samples show RTT 62.718–100ms and negotiated delay 400ms, with no
four-RTT violations; the native probe still requires both RTT <=50ms and sender buffer <=50ms.
418 of 438 retained buffer samples also exceed 50ms (maximum 67ms). The export
does not retain the exact throwing admission snapshot, so it does not identify
which guard threw; these are source-supported incompatibilities. Twenty-five
local-pressure rows independently replay from raw evidence. Their transport
pressure comes from retransmitted-byte fractions of 1.118–8.519% over short
enclosing intervals, with no sender drops or exceeded buffer/RTT limits. These
pressure decisions coexist with the passing delivery buckets. The record does
not support enabling production upgrades or changing acceptance thresholds just
to pass this fixture.

Independent decoded-media checks retain all 3,814 archive IDs 0–3,813 and all
3,398 live IDs 200–3,597, 30fps cadence, and AAC timestamp continuity (maximum
cumulative error <0.5ms). Recording continues 7.2s after the saved live span.
The independent recording lifecycle check passes. UDP accounting passes with
34 forward and 16 reverse injected drops, no unintended loss or socket errors.
All 1,206 frozen hashes match, and owned simulator/container, API listener and
case processes are absent. Matched source/archive/live frame 746 was visually reviewed: the archive
preserves the source scene without a score, the lower-resolution stream shows
the same moment with the score, and score crops change from 0–0 to 1–0.
Full natural-audio/adaptive qualification is still incomplete. Evidence: `failure-assessment.json`, `partial-media-assessment.json`,
`local-pressure-replay.json` and `local-retransmission-assessment.json` in the case.

Latest verification: 3,657 tooling tests pass. The unchanged native correction
passes 522 app-model tests; the added slice-route composition test was observed
failing on the previous blanket rejection before the host exception was added.
Code review finds no blocker in the bounded route extension. Native production
behavior, the quality thresholds, 8MiB export bound and worker default remain
unchanged.

## Next implementation boundary

1. Define explicit network-aware probe admission instead of silently changing the
   existing loopback probe's 50ms/no-retransmission assumptions. Carry negotiated
   recovery delay, fresh same-generation transport observations and actual
   delivered probe bytes through native authority, admission and independent
   verification. Preserve immediate revocation for unavailable/stale evidence,
   actual sender drops, exhausted recovery/queue budgets and obsolete ownership.
2. Separate sustained retransmission evidence from immediate hard-pressure
   signals. A recovered packet is not itself a dropped video frame. Keep the
   existing source/decoder delivery checks and rapid response to real deadline
   failures. Select and document a statistically meaningful observation window;
   test sporadic recovered loss, sustained congestion, loss bursts and recovery,
   counter resets, missing feedback and generation changes before another run.
   [SRT's socket-option guidance](https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md)
   explicitly budgets extra bandwidth for retransmission; this does not justify
   treating an estimated bandwidth gauge as usable capacity or inventing a
   universal packet-loss percentage threshold.
3. Bound pressure-path exports without duplicating every retained history at each
   tick. Keep sufficient independently replayable evidence and reject omitted
   history; do not raise the parser limit to conceal the first failure.
4. Repeat complete static-link qualification, then causal capacity loss/outage,
   production integration and wider profiles. The current work is a diagnosed
   laboratory boundary, not physical/cellular/remote-host qualification.
