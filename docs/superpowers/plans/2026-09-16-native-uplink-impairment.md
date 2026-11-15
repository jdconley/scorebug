# Native publishing-uplink impairment qualification

Execute in the validation worktree with red/green tests and bounded independent
source/design review. Parent owns sequential native, Swift and media execution.

## Scope and routing prerequisite

Checkpoint `c612ec7` connects local pressure to the simulator quality loop and passes
healthy motion qualification. Actual impaired-media adaptation and recovery remain
open. The existing single-peer UDP proxy cannot replace the shared control-plane
ingest endpoint: both the filming phone and the worker reader use that endpoint.

First qualify an isolated publishing route. Add an exact opt-in native fixture
profile (`passthrough` initially), validated before resources. It requires native
quality/processing/publication evidence, direct recording and the structured-motion
workload. The fixture owns a loopback UDP proxy forwarding to its owned ingest
container. The worker and control plane retain the actual ingest port. Only the
native filming publisher receives the proxy port through the existing Xcode →
UITest → app fixture environment chain.

A pure URL transformer validates the canonical port, existing observation/quality
opt-ins and an original loopback SRT URL, then changes only the port. Its runtime
call is confined to DEBUG simulator builds. Preserve stream identity, query bytes,
passphrase, clock and all transport options. Invalid overrides fail explicitly;
no silent fallback or production override. No credentials appear in proxy evidence.

Own and join proxy closure on normal collection, failure and interruption. Save
bounded scalar counters even on failure. Require one peer, bidirectional traffic,
no socket errors, no overflow/injected/oversize drops, and drained queues for the
pass-through profile. Independent packet conservation complements the existing
saved-media/receiver proofs; send counters are never receiver delivery evidence.

## Gates before introducing bandwidth pressure

- Pure configuration tests reject malformed/unsupported flags and missing fixture
  prerequisites before resource allocation.
- Swift URL tests prove port-only rewrite and reject foreign hosts/schemes,
  malformed ports and missing opt-ins; production call site remains compiled out.
- UDP fixture lifecycle tests cover ordinary forwarding, no-peer shutdown,
  foreign peer rejection, repeated close and invalid conservation/pressure evidence.
- Run full tooling and FilmModel tests, combined unsigned Apple Release and source
  review. Run actual 90-second confirmation-required motion through the new route.
- Preserve all current native media, archive, source, timing, scoring, workload and
  frame-loss gates. Proxy-path pass is not impairment/adaptation qualification.

## Subsequent pressure and recovery

Add bounded scheduled rate changes without replacing UDP endpoints or resetting
FIFO/counter ownership. Preserve queued packets and token accounting across rate
changes; record actual phase boundaries and counter snapshots, not nominal timer
intent. Initially target a 4 Mbps forward wire-rate phase bracketed by unlimited
baseline/recovery phases. Reverse control traffic remains independent. Native hold
must cover baseline, pressure and recovery, including complete receiver probation.

Freeze acceptance before the pressure run: clean local recording remains exact;
require native decrease receipts backed by raw pressure, no unsupported growth,
and later receiver-qualified confirmation. Add explicit clock/phase correlation
before claiming a bounded response time or associating confirmation with restored
bandwidth. Begin with existing strict live cadence/loss/A-V gates; retain failures
for diagnosis rather than silently relaxing them. If transient-loss acceptance is
needed, specify and review time-bounded transition budgets and sustained-period
24 fps/loss gates separately, while retaining whole-run accounting.

## Checklist

- [x] Publishing-only routing design/source review and deterministic tests.
- [x] Actual pass-through motion qualification with independent proxy evidence.
- [x] Scheduled pressure/recovery fixture with bounded phase accounting.
- [ ] Actual impaired-media decrease/recovery qualification.

Physical iPhone/Watch, longer adaptive soaks, resolution changes, production
activation and remote proxy hosts remain part of the overall plan.

## Verified pass-through checkpoint

The fixture now changes only the DEBUG simulator publisher's loopback port; the
control plane and worker retain their direct ingest address. Exact query encoding
is covered by Swift tests, while unsupported profiles, reserved port overrides and
missing qualification prerequisites fail before fixture allocation. Proxy shutdown
is joined before ingest removal and preserves final scalar evidence on failures.

All 180 FilmModel and 872 tooling tests pass, as does the unsigned combined
iPhone/Watch Release build. Independent design/source review found no blocker.
Actual confirmation-required 90-second structured-motion run
`artifacts/qa/native-app-gA96IZ` passes every existing media/observation gate:

- Clean archive: 3671 consecutive frames, source IDs 0–3670, 30 fps, zero loss.
- Acquired live: 3236 consecutive frames, IDs 219–3454, 30 fps, zero loss;
  the final encoded frame is delivered. Full decode, A/V sync, native score overlay,
  archive continuity and export checks pass.
- Local payload windows: 12.027–12.130 Mbps; live: 7.314–7.653 Mbps.
- Native quality: 16 source evaluations, two trials, one confirmed at 6.6 Mbps,
  no rollback; the subsequent 7.26 Mbps trial is unconfirmed at stop.
- Uplink: 79575 forward / 7557 reverse packets with exact packet/wire-byte
  conservation, no drops, foreign peer, socket errors, retained queue or pending send.

This proves the route only. No bandwidth pressure, decrease, or recovery has been
qualified. Evidence and source hashes are retained in the ignored
`artifacts/qa/native-uplink-final-verification.json` manifest.

## Scheduled-rate implementation contract

The next exact opt-in profile is `rate4m`, requiring the same native fixture
prerequisites plus a hold of at least 180 seconds. The first accepted publisher
datagram starts the schedule: unlimited at 0 seconds, 4,000,000 forward wire bits/s
at 60 seconds, unlimited again at 120 seconds. Reverse traffic stays unlimited.
The schedule accepts at most eight canonical, strictly increasing boundaries,
starting at zero and ending within 600,000 milliseconds, validated before sockets exist.

A queue rate update advances credits at the old rate through the actual update
time, then changes only the rate. It preserves FIFO ownership, delay deadlines,
counter totals and the remaining bounded token balance. Unlimited periods do not
manufacture refill credits for a later limited phase. Invalid rates/times and
post-close updates fail before mutation.

The proxy owns one schedule timer, starts it only on the first accepted peer,
records actual monotonic application times and full bounded directional snapshots,
and cancels it during joined closure. A late timer records late actual boundaries;
it never claims elapsed impairment that did not occur. No-peer or interrupted runs
keep partial schedule evidence and fail qualification. Rate changes repump queued
traffic using the existing bounded pending-send mechanism.

An independent schedule qualifier will validate every cumulative counter, phase
configuration, actual duration, conservation, rate ceiling (dequeue/send-attempt wire bytes plus initial
burst, without double-counting pending sends), and the final joined closure. Overflow under
pressure is recorded, not hidden. Existing strict native media gates remain intact.
Initial native pressure runs are diagnostic until measured phase/phone clock
correlation and raw native decrease/recovery receipts prove adaptation. A successful
old quality-confirmation gate alone cannot qualify this profile as recovered.

## First limited-rate result: live recovery fails

The bounded schedule and its independent checks are implemented; all 883 tooling
tests pass. Read-only design/source review approved the diagnostic run.
`artifacts/qa/native-app-u55lyM` used an iPhone 14/iOS 17.5 simulator, structured
motion and a 180-second requested hold. It failed the unchanged UI requirement
that publishing still be active after the hold.

The proxy applied 4 Mbps for 59,999.223 ms, forwarded 22,313,168 wire bytes during
that phase, and recorded 26,252 overflow packets (35,013,004 wire bytes).
It closed with no socket errors, foreign peers, retained packets or pending sends.
All three scheduled boundaries occurred, but publishing traffic ended before the
unlimited recovery phase. The independent schedule qualifier correctly rejects
the run for missing recovery traffic coverage.

The worker decoded 1746 frames before `output_timeout`, then exhausted its restart
budget. Native telemetry records a trial rollback and six accepted reductions:
4.8, 3.84, 3.072, 2.4576, 1.96608 and 1.572864 Mbps. Seven local-pressure windows
independently replay as elevated transport pressure. These raw local observations
do not qualify the full source/controller history or recovery. No cross-clock
response-time claim is made.

The UI failure interrupted recording before its normal finalization/export step.
The retained committed archive was cloned, recovered and exported using a freshly
built ArchiveHarness. It yields exactly 6600 consecutive frames (0–6599), 220
seconds at 30 fps, with complete decode, A/V coverage and 109 matched sync markers.
This proves a clean recoverable committed prefix, including capture after live
publishing stopped; it does not prove a normally finalized complete recording.

Read-only evidence review found no mismatch. Analysis and its exact replay script
are retained in `artifacts/qa/native-app-u55lyM/failure-diagnostic-analysis.json`
and `artifacts/qa/uplink-schedule-recovery-check.mjs`.

### Next diagnostic gate

The last roughly five-second transport samples show about 6.0 Mbps after subtracting
retransmitted bytes despite progressively lower accepted native bitrate settings.
That is not a raw encoder measurement and does not distinguish a content-dependent
encoding floor, ineffective dynamic settings, or buffering.

Measure actual encoded sample bytes tied to immutable encoder configuration and
source PTS under controlled high/low/high settings, without network pressure.
Compare a fresh low-rate encoder against a dynamically lowered encoder on the same
structured-motion frames. Qualify the simulator path used above, then the Mac
encoder where useful; do not infer simulator behavior from Mac-only properties.
Check frame continuity, completion timing and achieved payload separately from
property readback. Use that evidence to choose the correction or resolution
fallback; do not lower the workload or relax native loss/cadence gates to get a pass.

The failed UI path also reveals a fixture-evidence gap: cleanup closes the status
collector but only normal `collect()` writes its bounded publication/processing
maps. Preserve those maps during failure cleanup in the next diagnostic work.
Local recording should be stopped/exported before reporting an end-of-hold live
failure where possible, while keeping that failure explicit. Phase/phone clock
correlation remains required before claiming bounded response or recovery.
