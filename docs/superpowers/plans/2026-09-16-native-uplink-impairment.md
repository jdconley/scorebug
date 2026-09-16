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
- [ ] Scheduled pressure/recovery with bounded phase accounting.
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
