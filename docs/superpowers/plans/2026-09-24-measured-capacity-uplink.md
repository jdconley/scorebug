# Measured capacity drop and restoration plan

> Use `superpowers:executing-plans`. Autonomous implementation and routine design choices are authorized. No production switch or complete recovery claim is implicit in transport accounting.

**Goal:** Exercise real upload capacity reduction/restoration with the representative match pipeline, prove the applied fault, then independently prove native quality reduction, recovery and continuous clean recording.

**Architecture:** Reuse the owned loopback UDP queue and its timed rate schedule. A new explicit profile holds the existing 30 ms bidirectional delay and every500th-packet loss constant, starts unlimited, limits forward wire rate to550,000bps at60s, and restores unlimited capacity at120s. Record at least 60 s after restoration. Native policy receives its normal SRT/receiver evidence; the proxy never tells it to change quality.

**Tech stack:** Node UDP impairment fixture, Swift native publisher, existing lossless pressure evidence and raw media/deadline replay.

## Design decisions

- 550 kbps is a laboratory stimulus between the current350kbps and600kbps video settings plus audio/protocol overhead, not a promise about actual payload or an industry threshold. The transport verifier must observe offered load above the limited rate, bounded forwarding below its ceiling, and increased queue residence or overflow. Insufficient offered traffic cannot qualify congestion.
- Reuse the existing timer/queue rather than add another proxy or a system-wide network conditioner. A readiness-triggered schedule could avoid runs whose upgrade finishes late but adds a live control/clock boundary. First support the existing fixed schedule; later native qualification must independently prove its baseline confirmation preceded the fault. Never infer causality solely from requested offsets.
- Keep this new profile separate from `measuredUplinkProfiles` until the native route, evidence capacities, clock binding and full causal qualifier are ready. Existing static/full-trial success paths must reject it. A transport-only pass must explicitly deny native adaptation/recovery qualification.
- Use existing bounded queue sizes and token bucket, retaining IPv4/UDP28-byte overhead, SRT header bytes in payload, capped16KiB burst and no change to real production networking. Expected configured drops remain distinct from congestion overflow. Reject oversize, socket errors, foreign peer traffic, queued/pending data at closed join, timeline omission or close-discard.
- Validate every applied phase (not just the last snapshot), monotonic cumulative counters/timeline prefixes, unchanged reverse rate, schedule order/duration, all packet/byte conservation, configured deterministic loss, and the actual limited forwarding budget. Show baseline, constrained and restored traffic spans. Queue observations prove send-attempt accounting, never remote receipt.

## Stage1: applied fault evidence

Files: new `scripts/measured-capacity-uplink.mjs`; new `scripts/test/measured-capacity-uplink.test.mjs`. Reuse `udp-impairment.mjs` and `datagram-timeline-qualification.mjs` without altering existing defaults.

- [x] Write a synthetic monotonic simulation using the real `DatagramImpairmentQueue`, with exact rate changes, sustained offered load, sufficient drain and bidirectional traffic. Write positive/negative tests before implementation: weak traffic, incorrect rate, early/late/missing phases, altered delay/loss, reversed counters, corrupt/past prefix, rate ceiling, omitted timeline and unjoined closure.
- [x] Implement immutable configuration factory and independent phase qualifier. Require at least180s observed route,60s constrained phase and60s restored traffic. Return explicit transport-only scope and false native/network recovery flags.
- [x] Run focused/full tooling tests and read-only review. Run a real loopback UDP180s campaign using the same configuration and bounded joined sockets, qualify its saved result and retain the requested settings/output/source hashes. This proves the fault mechanism only.

## Stage2: native integration (must remain incomplete after transport-only work)

- [x] Enable explicitly selected recovery-budget confirmed-prefix policy replay in `scripts/measured-trial-policy.mjs`. Preserve format/policy/lifecycle/admission joins and the original complete raw history. Test successful two-phase input, later synthetic reset suffix, exact boundary, input immutability, recovered-retry handling and every pre-confirmation failure. This proves the first confirmed upgrade only; the whole native recovery route remains closed until all following gates are implemented. Verify against the real successful match artifacts.

- [x] Extend the raw three-phase lifecycle/admission replay under an explicit `recovery: true` plus `recovery-budget-v1` option. Require exactly one360p trial and one240p reset, sequential revisions, native receipt/bitrate/encoder/time joins, original source/media validation and full unchanged history. The downward reset must have no active candidate/probe authority and must retain the exact old binding/current/terminal snapshots; historical preflight times never become fresh capacity permission. Propagate the selected policy through terminal retirement joins. Test with recorded three-phase media plus explicitly synthetic recovery metadata; this proves verifier composition only. Keep full static-trial, decoder-fault, repeated and capacity routes separate.

- [x] Add an explicit native capacity recovery selector, mutually exclusive with steady successful-trial and decoder-fault modes; validate host and Swift fixture selectors before resource creation. Select recovery-budget transport policy explicitly. The host runner currently denies this mode before resources; forwarding and causal qualification remain below.
- [x] Provide bounded 180 s cadence/delivery/quality export formats without reusing a misleading repeated-decoder flag. Reuse512-row/byte budgets where appropriate, preserve historical formats/defaults and fail overflow closed. Native count/byte tests and host raw replay cover the new explicit capacity envelope; a fresh180s app export remains part of the end-to-end run below.
- [ ] Bind applied proxy phase times to native observations with independently bounded clock evidence or an equivalent causal source-frame proof. Prove confirmed360p before the actual limit, a subsequent owned pressure/deadline reset, lower240p stable delivery after restoration, and later fresh measured ramp-up. Do not convert stale/unknown windows to healthy or grant credit during the fault.
- [ ] Run the frozen real-match app workflow, full archive/live decoding, scoring/glyphs and phase audio checks. Preserve failed artifacts, fix actual defects from evidence, rerun only for changed code or a distinct experiment.
- [ ] Add a true outage campaign after capacity recovery; do not label a positive-but-small bitrate as a complete outage. Qualify production integration/wider ladder and physical devices separately.

## Verified checkpoint

The final transport campaign, `artifacts/qa/measured-capacity-uplink-Jjaq9q`, joined with exit 0. The source factory, queue, verifier and runner were saved with the artifact; all five hashes match after shutdown. Across a 60,000.320 ms constrained phase, the proxy forwarded 4,140,864 wire bytes within the 550 kbps ceiling plus the capped 16 KiB burst. Peak offered load was 978,432 bps. It observed 2,085 congestion-overflow packets and 3,814.666 ms maximum queue residence, followed by at least 60 seconds of restored traffic and a clear final queue.

All 16,449 sent packets reached the proxy. All 14,332 forwarded packets reached the receiver; configured drops plus congestion account for the difference. All 2,866 replies reached the reverse proxy; 2,861 reached the client, exactly matching its configured drop accounting. Client/reply/proxy pending sends and queues ended at zero. Reply callbacks have an explicit 64-send/6,400-byte bound; both endpoint peaks were one. Every hop is joined by counters and callbacks, with no settling sleep. No native media, recording or adaptation claim follows from this UDP experiment.

Review found and prompted fixes for a missing per-bin minimum-delay check and untracked reply callbacks. The delay regression reproduced before repair. The earlier `measured-capacity-uplink-yLaXg3` exploratory run remains preserved with a limitation note; the reviewed run above is the accepted transport evidence. Focused transport tests pass 31; the complete tooling suite passed 3,940 after those repairs.

The first Stage 2 prerequisite now supports `recovery-budget-v1` in confirmed-prefix replay. It retains all envelope/policy/admission/lifecycle joins, pressure and cadence checks, and the exact original event boundary. Tests prove that later reset history remains unqualified, recovered retries are accepted, and pre-confirmation defects still fail. All 112 focused policy/trial tests and 3,957 full tooling tests pass. Independent replay of the real `native-app-G0kJLr` artifacts finds confirmation at event 11 after 10.000033 seconds of contiguous probation; the record and source hashes are in `artifacts/qa/recovery-budget-prefix-replay-oEZYVy`.

The raw three-phase lifecycle/admission prerequisite now supports explicit `recovery: true` with `recovery-budget-v1`. It proves the original240p→360p→240p media and native writes, ordered revisions, candidate correspondence, unique bitrate configurations and completed application times. The reset retains the exact original binding/current/terminal snapshots with inactive probe and candidate authority. Historical preflight timestamps remain historical. Both raw retirement and full native lifecycle reject changing a retained campaign. Quality format6 expands through the same replay without changing evidence.

The tests use the recorded `measured-recovery-mnaRRb` three-phase fixture with **synthetic recovery-policy metadata**. They establish verifier composition, not a new recovery-policy media or network experiment. Existing full static-trial, decoder-fault and repeated routes still reject this three-phase recovery-policy context. No capacity mode is enabled and no recovery success or production authorization is returned by the shared evidence helper. An initial negative test removed only the final archive-tail ID; that is outside this helper's observed interval, so the test now removes required archive coverage. Complete archive durability and audio remain harness obligations.

Read-only review found a standalone terminal-retirement campaign mismatch that the composed lifecycle already rejected. The targeted mutation reproduced before repair; exact historical terminal equality now closes the standalone gap. All4,009 tooling tests pass (`repeated-live-checkpoint-recovery-native-raw-reviewed-tools.log`). The focused lifecycle/raw/native-trial/legacy-recovery/retirement set passed227 before the final dictionary/options/campaign tests; the final raw-recovery file passes29 tests. Independent full successful-trial and confirmed-prefix replay of unchanged `native-app-G0kJLr` still passes all154 delivery windows. Saved results are in `artifacts/qa/recovery-native-raw-baseline-replay-NEk9yN`; all7 saved source hashes and17 original artifact/input hashes match after replay. This reuses earlier static impaired-link evidence and does not claim a new native run.

Next: wire an explicit capacity mode with bounded180-second audits and causal fault binding. The normal static native route still rejects `capacity550k`. The fresh app run must establish baseline confirmation before the actual capacity change, owned reduction, stable minimum recovery and a separately fresh measured re-ramp. True outage remains a subsequent requirement.

## Capacity route/export implementation contract

Use a distinct `SCOREBUG_TEST_CAPACITY_RECOVERY=1` opt-in, paired with `capacity550k`, staged probe, recovery-budget policy, exactly180s, the prepared file route and explicit400ms SRT peer latency. Reject every decoder/repeated/manual-quality/pacing mode and user-provided proxy port. Host checks run before artifact/resource creation; Swift independently validates the forwarded route with its generated loopback port. Keep steady profiles unchanged. Until the causal native qualifier is wired, an explicit harness guard must stop this route before resources rather than fall through to successful-trial qualification.

Select version2 cadence/delivery envelopes with `mode: capacity`, cadence3,072rows/16MiB and delivery512rows/32MiB, using the existing per-row accounting and sticky overflow behavior. Match exact caller-selected mode at replay; raw metadata must never authorize larger budgets. Native selection requires the entire capacity route. Preserve legacy/repeated formats and bounds. Test full routes, missing/malformed/conflicting selectors, row and byte exhaustion, history prefix immutability and original raw cadence/deadline reconstruction. The format6 quality dictionary already supplies the bounded pressure export; no threshold changes.

## Selector and bounded-audit checkpoint

Host `nativeCapacityRecovery` and the existing file/measured option parsers accept only the complete capacity route; the static profile registry remains unchanged. Swift's independent leaf `capacityFileUplink` selects the same forwarded contract. The actual SRT URL additionally requires loopback and exactly one canonical400ms peer-latency parameter. Cadence and delivery writers now select `mode: capacity` only after full native fixture validation. Tests retain complete ordered prefixes at row/byte exhaustion, latch overflow, propagate unavailability, and reject further writes after serialization failure. Release delivery behavior retains the original default budget; cadence export is DEBUG-only.

All4,066 tooling tests pass, including actual child-process verification that the harness denial occurs before any new native artifact directory. All56 focused Swift tests and the full548 app-model tests pass (`repeated-live-checkpoint-capacity-native-route-film-models.log`); both runs joined with exit0. Independent review found no actionable issues. The red preflight test before the denial was added reached the runtime-availability check and left only configuration/diagnostic/runtime logs in `native-app-IJ0QFd`; it did not launch an app or install a runtime. That failed experiment remains preserved.

Remaining integration work is explicit: forward the new capacity flag through Xcode/UITest/app launch; pass caller-selected capacity envelope modes through full native evidence and confirmed-prefix replay (these still default to legacy); launch the owned capacity queue; capture independently bounded host/native clock correspondence; qualify baseline confirmation before the actual limit, the subsequent owned downward action and stable minimum delivery. Do not assume Node performance time and native uptime are interchangeable. Remove the harness denial only when the complete causal qualifier is connected. The current staged fixture proves at most the first trial/reset; a later fresh campaign and re-ramp requires its own native/controller evidence and must not be inferred from restored UDP traffic.

## Causal clock bracket design

Use four owned request/reply challenges: one before and one after each actual rate change (limit and restoration). Each request carries the publishing scope, sequential index and fresh UUID nonce. The native responder records its current monotonic uptime only after reading the request, retains at most four samples and exports a closed audit at teardown. The host saves the exact request, returned native sample and monotonic send/read bracket. A reply must match the nonce, sequence and scope, complete within250ms, and match the later closed native audit unchanged.

For each rate change, the before reply must arrive strictly before the proxy's applied timestamp and the after request must start at or after it. Native samples then bracket the fault without assuming equal epochs, clock rates or a constant offset. Require both host and native brackets at most1.5s, all sequences/times ordered, and no overflow/invalid/extra samples. Qualification returns timing bounds only; transport accounting and native media/controller recovery remain separate. Baseline confirmation must precede the conservative lower limit boundary; credited post-fault or post-restoration events must follow the corresponding upper boundary. A missed challenge fails closed; never freshen an old sample, widen the budget or infer an offset.


## Clock prerequisite and native lifecycle checkpoint

Implemented four-sample causal bracket qualification, a bounded host exchange sampler,
and a DEBUG native file responder. The sampler awaits each write/read and cancellation;
its 250ms budget never resets. The responder accepts only ordered, scoped UUID
challenges, retains original timestamps on duplicate reads, and rejects malformed,
oversized, non-regular or symlink request files. Its closed audit is exported during
joined publisher teardown. It uses the existing control poll and starts no extra timer,
network operation or camera work. The simulator default factory requires the complete
capacity route; physical-device and Release behavior do not activate it.

The original capture observation scope has `appliedProfileRevision: "1"`.
This is distinct from the quality controller's initial revision `"0"`. Source inspection
and the saved real-match artifacts exposed that distinction; red/green regressions now
require scope1 in Swift and JavaScript. Do not substitute a controller revision for this
original capture identity.

All4,107 tooling tests and554 app-model tests pass, including actual responder file I/O,
malformed-file rejection, publisher teardown, immutable closed exports and continued
recording ownership. Logs are `repeated-live-checkpoint-capacity-clock-tools-full.log`
and `repeated-live-checkpoint-capacity-clock-film-models.log`. Read-only review found
no additional actionable issues. These tests establish the diagnostic mechanism, not
actual clock brackets captured around a native network fault.

The host's bounded atomic file adapter, scheduling around actual proxy phase changes,
flag forwarding, capacity envelope propagation and full causal media/controller replay
remain open. Keep the pre-resource harness denial until these are composed. The
four-sample verifier returns timing qualification only; independently qualify the same
raw transport schedule and the clean archive/live media before crediting recovery.

The iOS simulator Debug build passes for this Mac's arm64 architecture
(`repeated-live-checkpoint-capacity-clock-ios-arm64-build.log`). The initial generic
multi-architecture build failed linking the bundled SRT library for x86_64;
`nm -arch x86_64` confirms no exported `_srt_startup`, while arm64 exports it.
The source binary and the copied build product have the same missing Intel symbol.
This is an unresolved Intel-simulator dependency limitation, not a deleted-runtime
problem. No simulator/runtime was created or reinstalled for these checks, and no
persistent architecture exclusion was added.


## Host file exchange and scheduling contract

Use an existing, explicitly supplied absolute app QA directory; never create or search
for another app container. The host writes only its fixed request name using a private,
exclusive temporary file and atomic rename, and reads only the fixed response name.
Bound requests to4KiB and responses to16KiB; reject non-regular files, symlinks,
malformed UTF-8/JSON and changing/oversized reads. Every descriptor and temporary
file is joined/cleaned before returning, including errors. The sampler owns the
250ms exchange deadline; exceeding it fails rather than detaching file work.

Schedule the four challenges against the owned proxy's original start time, without
changing its rate timers. Start each before challenge500ms before the requested
change. Wait for the actual applied phase to appear before issuing the after challenge.
Reject a late start, changed schedule/original phase times, cancellation, incomplete
phase or a host bracket exceeding1.5s. Save the exact exchanges for the independent
closed native audit/transport replay. Scheduling success alone grants no recovery
qualification. Integration must derive the capture scope from owned native evidence
and reconcile it with the final media artifacts.


## Host clock adapter and scheduler checkpoint

`capacity-clock-files.mjs` now supplies bounded, serialized real file I/O to the
nonce sampler. Tests verify atomic replacement, private permissions, fixed paths,
missing replies, malformed/oversized/non-regular/symlink replies, invalid UTF-8,
request byte limits, failed-rename cleanup and rejection of overlapping operations.
`capacity-clock-schedule.mjs` observes the independently running UDP proxy schedule,
samples500ms before each due change, waits for its actual application, then collects
the corresponding after sample. It pins the original schedule/origin and all observed
phase timestamps; cancellation and all injected operations are joined. It never sets
or delays a rate, renews a deadline or grants adaptation permission.

All25 new focused tests and4,132 complete tooling tests pass
(`repeated-live-checkpoint-capacity-clock-host-tools.log`). The synthetic schedule
uses a different native clock epoch and its four replies pass the independent closed
native audit bracket verifier. Actual file-I/O composition uses a JavaScript reply
stand-in; it does not claim a Swift responder or native network experiment. Read-only
review found no actionable issues. The initial missing-implementation red run had a
test-only cancellation barrier that could wait forever; that exact process was stopped
and joined, then the test gained an early-rejection race and a2s timeout. The corrected
red run fails for the missing API and the green run completes normally. No simulator,
runtime installation or physical device was involved.

Next integration: derive the scope from the owned match/recording/publication, resolve
its existing simulator QA directory once, invoke this collector from the native worker
fixture and save its exact exchanges. Forward the capacity flag through Xcode/UITest,
propagate explicit capacity audit modes through full raw native and prefix replay, and
compose timing with transport, controller, archive/live and audio evidence. Keep the
harness denial until that complete causal route is connected. Fresh measured re-ramp
and true outage remain separate open gates.


## Native harness wiring and capacity replay checkpoint

The host now forwards `SCOREBUG_TEST_CAPACITY_RECOVERY` through the generated
Xcode test environment and the UI test's app launch settings. The UI test separately
requires the file route, capacity550k, recovery-budget policy and exactly 180s. The
native worker fixture validates the exclusive capacity configuration before resources,
creates the independently timed capacity UDP proxy, and starts clock collection only
from a freshly authenticated relay publication record. The publication collector now
returns a detached copy of that current public record; a disconnected/cached owner
cannot start collection. No private relay query or credential enters the clock scope.

The host resolves the owned simulator's existing data container, passes its QA directory
to the file adapter and saves the four raw exchanges. The collector uses the existing
owned fault task: shutdown aborts and awaits it, propagates failure, and rejects a route
whose clock collection never started. The closed native clock artifact is copied with
its 16KiB/non-regular-file bound. These paths remain behind the existing pre-resource
harness denial until the full causal qualifier is connected.

The shared raw native evidence helper now accepts `capacityRecovery: true` only with
`recovery: true` and `recovery-budget-v1`. It forwards both capacity envelope modes
through original cadence/deadline reconstruction, media, native lifecycle and admission
checks. Confirmed-prefix policy replay separately requires explicit capacity cadence
mode and recovery-budget policy. It retains full raw history, all pressure/continuity
checks and the exact confirmation boundary; no suffix or recovery success is implied.
Tests use existing recorded media with synthetic policy/envelope metadata, not a fresh
capacity network experiment. Legacy/default and repeated routes remain separate.

All 4,172 tooling tests pass (`repeated-live-checkpoint-capacity-harness-tools.log`),
including 117 focused raw/prefix tests and fresh-publication ownership tests. The
arm64 iOS simulator UI test target builds successfully with Xcode 26.2
(`repeated-live-checkpoint-capacity-harness-ios-build.log`), without booting, creating
or reinstalling a simulator. The resource-entry test deliberately throws before Docker
image inspection; it proves route selection and early rejection, not real worker startup.

Remaining before removing the denial: compose independently replayed transport and
closed clock evidence with confirmed 360p before the limit, the actual owned downward
pressure/deadline action after it, and stable 240p delivery after restoration. Update the
harness's route-specific qualification and saved result fields, preserving archive/live
full decoding, scoring and phase audio checks. Native capacity reduction may have a
transport-pressure trigger rather than the existing decoder-pause trigger; do not forge
an owned decoder pause or reuse its proof as evidence of a network fault. Then run the
frozen real-match workflow. A later fresh candidate campaign/re-ramp and true outage
remain open and must not be credited by this three-phase experiment.

Review found a false-positive risk in the incompatible-option tests: their shared
recorder prerequisite was missing. Each now starts from the valid environment.
Removing only the worker-output-profile exclusion makes its targeted test fail at
resource entry, as intended; the exclusion was restored. The mutation failure is
preserved in `repeated-live-checkpoint-capacity-worker-guard-mutation-red.log`.
No further implementation findings were reported.
The corrected complete tooling suite again passes all 4,172 tests
(`repeated-live-checkpoint-capacity-harness-reviewed-tools.log`).


## Diagnostic capture before causal qualification

Refine the execution order to gather actual native fault behavior before completing
its causal verifier. Add an explicit host-only `--capacity-diagnostics` flag, valid only
with the complete existing capacity route. Ordinary capacity qualification remains
blocked before resources. The diagnostic path runs the same UI/recording/publisher
workflow, joins status, worker, UDP and recorder collection even when an earlier
collector fails, and saves raw evidence plus explicit false qualification fields.
It then deliberately exits nonzero through the existing bounded app-data preservation
and cleanup path, before any steady-trial or recovery PASS branch. This is an experiment,
not a relaxed acceptance gate. Do not label collected files or a successful UI workflow
as successful adaptation, clean media or recovery without independent replay.

Use the prepared real-match input unchanged, freeze all sources and input hashes,
reuse installed iOS26.2, and preserve every failed clock/media/transport observation.
The actual response will determine which native pressure/deadline trigger needs to be
joined to the fault. This avoids designing the remaining proof around an assumed
trigger or fabricating decoder-pause evidence.

## First native capacity diagnostic — failed, preserved

`artifacts/qa/native-app-rQQICD` ran the prepared 270-second real-match source
with a 180-second hold and the existing 550 kbps capacity route. Xcode built
successfully, but the UI workflow failed its final live qualification assertion:
local publishing remained active while the worker was starting. The UI stopped
and exported local recording before asserting that failure. The process joined
with exit1 and cleanup removed its owned temporary simulator. The iOS26.2 runtime
was reused. The source freeze at `capacity-diagnostics-freeze-b5btaaff` verifies
all 1,244 hashes unchanged; the runtime source state is committed as `a9e2c37`.

Preserved observations:

- `diagnostic-clock-transport-inspection.json`: all four host/native exchanges
  match the closed native clock audit. Boundary widths are 0.504s and 0.498s.
  This qualifies timing only. Transport replay rejects `Missing phase traffic
  coverage`; do not treat packet counters alone as a qualified transport run.
- The app stayed at revision0/240p: zero profile requests, zero candidate admission
  events, and no applied upgrade. Nine healthy source evaluations reported
  `missingCapacity` before the fault. There is no demonstrated step-down or recovery.
- The 121-frame candidate completed at native uptime1960031.1162350834. Stage3
  retirement was requested at1960031.1378159584, only21.58ms later. It bound3.905s
  after stage3 began. The last accepted receiver interval preceded completion by
  about0.93s. This identifies a narrow admission window, not the cause of delayed
  readiness; the one-shot route currently lacks the repeated route's wait trace.
- With the probe retired and still at240p, offered wire traffic is roughly600kbps.
  The550kbps limit therefore also constrains the minimum profile. Re-measure actual
  video/audio/transport costs before selecting a recoverable capacity test; the
  configured350kbps video rate alone does not describe total wire traffic.
- Worker pipeline1 ended with an input I/O error after2455 decoded frames. Eight
  retries produced zero decoded frames and output connection refusals. The direct
  FFmpeg recorder exited naturally after the first connection. It is explicitly a
  single-publisher listener, so the fixture prevents observing worker reconnection.
- `diagnostic-media-inspection.json`: both archive and live audio/video fully decode
  with FFmpeg `-xerror`. The1080p archive contains237.866667s of video and237.886667s
  of audio. Live contains82s video and93.336712s audio. Live output is worker-scaled
  360p, not evidence of a native360p upgrade. No barcode continuity, scoreboard or
  phase-audio/sync qualification is claimed. The preserved native input hash matches
  the prepared source. Original Downloads videos remain unchanged.
- The bounded failure snapshot is complete:261 files,1,012,223,290 bytes. Reuse it
  rather than making another gigabyte copy. No `capacity-diagnostics.json` exists
  in this original run because the UI failure skipped that branch; keep that absence
  intact as part of the failed experiment.

The harness correction joins diagnostic collection after either UI outcome and
then saves the report before entering existing failure preservation/cleanup. It
always rejects; a secondary collection/write failure cannot mask the original UI
failure. Seven new tests failed before the correction and all16 focused tests now
pass. Read-only review found no actionable issue. This correction does not repair
streaming or retroactively change the failed experiment.
The complete tooling suite also passes all4,188 tests with joined exit0
(`repeated-live-checkpoint-capacity-ui-failure-tools.log`).

Next work, in order:

1. Add bounded one-shot candidate readiness/admission diagnostics and determine why
   the final probe had almost expired when measurement finished. Preserve strict
   freshness and owner checks; do not extend stale evidence.
2. Provide a reconnectable, session-aware output recorder for fault experiments.
   Retain each connection's timestamps and media; never concatenate across a gap
   and claim continuous delivery.
3. Measure baseline and higher-profile total wire rates, then specify the fault
   capacity and expected minimum-profile behavior before launch. Existing550kbps
   results remain failures under their original criteria.
4. Run a newly frozen diagnostic, qualify transport and actual native causal
   response, and only then enable the full recovery gate. Fresh post-recovery
   measurement/ramp and true outage remain separate experiments.

## Candidate scheduling diagnosis and bounded trace

Further replay of the original timestamps is saved separately in
`native-app-rQQICD/diagnostic-candidate-timing-inspection.json`. At the earliest
eligible stage3 time1960023.6136242084, the previous healthy source window had
already expired at1960022.2504742085. The next source evaluation arrived at
1960027.0101839583; the candidate bound8.34ms later. Its first overlapping source
window was evaluated at1960031.904023, **766.21ms after probe retirement**.
Current admission requires both current probe authority and a fresh overlapping
source window, so this one-shot schedule had no valid admission opportunity.
This explains the recorded failure without weakening either guard.

The existing bounded advisory wait trace now also covers single measured trials
that require readiness. It records probe reads, unavailable context, binding and
measurement completion, and exports only after joined retirement. Its4096-event/
4MiB limits and non-authoritative role are unchanged. Legacy trials without
readiness still do not export this trace. The regression failed on missing trace
data before the change; all58 candidate fixture tests pass afterward, including
the joined single-trial export and unchanged legacy behavior. This is diagnostic
instrumentation only; a new live trace and the scheduling correction remain open.

Scheduling work should coordinate the final probe with fresh source readiness,
using the existing repeated-campaign coordination as a reference. Preserve bounded
probe duration/payload, cancellation and ownership, and allow time for actual
candidate encoding plus an independently received overlapping source report.
Do not simply extend evidence expiry or renew a retired probe. Validate phase
offsets between report cadence and probe startup with deterministic tests before
another real-match experiment.

All555 app-model tests pass with joined exit0
(`repeated-live-checkpoint-capacity-one-shot-trace-app-models.log`), and read-only
review found no actionable issue. The original native source freeze and failed
result remain unchanged.
The arm64 iOS simulator UI test target also builds successfully with Xcode26.2
(`repeated-live-checkpoint-capacity-one-shot-trace-ios-build.log`). This build did
not create or boot a simulator or install a runtime; no new live run is implied.

The retained late video-cost intervals provide a further diagnostic: eight usable
240p intervals report345.5–382.9kbps video payload (mean362.4kbps) against350kbps
configuration. `diagnostic-native-video-rate-inspection.json` preserves those
scalars. These are late, video-only intervals; neither matched audio cost nor a
full transport decomposition is established. They cannot determine a new fault
capacity by themselves.

## Single measured-trial coordination implementation

Use the already implemented repeated-campaign timing policy for single measured
trials through an explicit `coordinatesMeasurement` opt-in on the staged probe.
The native factory selects it only for a measured staged route. Legacy staged
probes retain three eight-second stages. The measured route joins stage two,
waits for current matching readiness within the original60-second campaign
deadline, starts stage three, then rechecks readiness/configuration after the
native await. Candidate wiring forwards the existing readiness provider to both
measured probe routes. This does not grant candidate admission.

Only coordinated stage three gets the existing repeated path's twelve-second
absolute ceiling and bounded extra polls. Earlier stages remain eight seconds;
total poll validation includes the extra allowance. Native leases,16MiB cumulative
byte budget,60-second campaign budget and terminal withdrawal remain authoritative.
Waiting for readiness never renews the retired stage-two owner. The candidate's
existing wait deadline and all admission freshness/overlap rules remain unchanged.

The candidate retains the existing half-second final-probe warmup. An initial
implementation removed it for single measured trials to catch the first freshness
window, but the native run below showed this conflicts with admission's independent
warmup requirement. That removal is reverted; current readiness cannot make a
premature cost sample admissible. The longer bounded active probe must span the
next original readiness/overlap report while retaining all admission requirements.

Simply relaxing source freshness would admit stale evidence; shortening the
measurement would change its cost evidence. Neither addresses the observed
schedule. Coordination plus the existing bounded active-probe allowance gives
the measured route time for an original overlapping report, subject to native
resource limits. A withdrawn/expired/byte-limited probe still fails admission.

- [x] Add failing tests for staged readiness wait, changed readiness after native
  replacement, cancellation joining, final-stage lifetime/terminal limits and
  total poll budget, retaining legacy stage timing.
- [x] Implement opt-in coordination and readiness-provider wiring.
- [x] Run focused and full app-model tests, tooling tests as relevant, and the
  arm64 iOS simulator build; obtain read-only review.
- [ ] Re-run a frozen capacity diagnostic only after the reconnectable sink and capacity
  test assumptions are addressed. No unit-test result qualifies live recovery.

The first coordination regression run failed20 assertions in five tests: it
allocated without readiness, stopped stage three too early, and omitted the
additional poll allowance. The implementation fixes those cases. A separate
measurement-start regression failed because the half-second delay prevented
starting in the current readiness window; it passes with immediate measured
allocation while the legacy path keeps its warmup.

Read-only review found a real expiry race across the new readiness awaits. Both
sites now check the current clock against the original `validUntil` after return.
Before allocation, expired readiness waits for another report within the unchanged
campaign deadline. After allocation, expired or changed readiness cancels the owned
probe. Both expiry cases failed before the correction and pass afterward; review
confirmed the finding resolved. All565 app-model tests pass with joined exit0
(`repeated-live-checkpoint-capacity-coordination-reviewed-models.log`).

Before repairing/running the capacity fixture, re-run the previously passing
90-second fixed-impairment real-match route with frozen sources and the new
coordination. This tests the scheduling correction without depending on a sink
reconnect. Its result must not be described as capacity recovery.
All4,188 tooling tests also pass (`repeated-live-checkpoint-capacity-coordination-tools.log`),
and the arm64 iOS simulator UI test target builds with Xcode26.2
(`repeated-live-checkpoint-capacity-coordination-ios-build.log`). Both joined exit0.

## Native coordination test and admission-contract correction

The first frozen attempt, `native-app-n3pDrZ` / `measurement-coordination-freeze-dvucg_p2`,
failed before simulator creation when the Docker engine returned500 for relay image
inspection. Docker Desktop claimed to be running but the engine's`_ping` timed out.
A normal Docker Desktop restart restored`_ping` and image inspection. The image
remains `sha256:ca29df4c78ce6c0b3cda955bda17ec32c576d1894eb839110561f3c794a30d47`.
The startup failure is preserved separately; all1,244 frozen hashes are unchanged.

The retry, `native-app-pyWflj` / `measurement-coordination-freeze-akghm_hx`, ran
commit308221e with the same prepared source and fixed30ms/0.2% impairment. Its
native UI test passed in169.394s. File-recording qualification passed with3,888
delivered video frames; local and live full-decode commands succeeded. However,
the measured-trial verifier failed `profile.phases.length`: one native profile,
not the required two. Twenty healthy evaluations still reported`missingCapacity`;
there was no candidate admission or native profile request. This run is a failed
measured trial, not successful adaptation or recovery. All1,244 hashes are unchanged
and owned simulator cleanup completed.

The new closed wait trace explains the failure precisely. The candidate bound
26.49ms after stage3 began and encoded121 frames successfully. But admission has
always required `binding.startedAt + 0.5 <= boundAt`, so immediate binding could
never qualify. The final probe remained active for11.643s and withdrew at the
unchanged16MiB native byte budget (16,776,368 bytes), demonstrating that the
longer scheduling allowance did not bypass that limit. The compact inspection is
`native-app-pyWflj/diagnostic-coordination-inspection.json`; the bounded wait trace
is retained in `failure-app-data-TSI5yO/QA/native-candidate-wait.json`.

Restore the half-second measurement warmup, retaining coordinated readiness,
post-await expiry checks and the bounded final-probe lifetime. The corrected
regression first failed on the premature measured start, then passes after the
restoration. An admission-boundary test separately checks an active binding at
0.500s is accepted and at0.499s rejected. A new frozen run is required to show the
longer probe spans the next fresh measurement/admission opportunity; this failed
run remains unchanged. Reconnectable sink, suitable capacity stimulus and actual
capacity/outage recovery remain separate open work.
The restored implementation passes all118 focused probe/candidate/admission tests,
all566 app-model tests, and the arm64 iOS simulator UI test build. Logs are
`repeated-live-checkpoint-capacity-admission-warmup-reviewed.log`,
`repeated-live-checkpoint-capacity-warmup-restored-models.log`, and
`repeated-live-checkpoint-capacity-warmup-restored-ios-build.log`; all joined exit0.
Read-only review confirmed sender/admission warmup consistency and no further
findings, while explicitly leaving native timing viability unproven.

## Startup pressure replay prerequisite

The frozen `native-app-CLof0G` run at `0019079` joined with exit1 after its UI
workflow passed and the native240p→360p trial was applied and confirmed. The strict
policy replay rejected two `localPressure` rows0.764s and1.035s after bootstrap,
before the first source evaluation16.686s after bootstrap. Their retained SRT
samples include124.944ms RTT against the400ms recovery delay (the existing
quarter-delay pressure threshold is100ms). This is real observed startup pressure;
it must not be removed, mislabeled healthy, or bypassed by changing thresholds.
All1,244 frozen source/input hashes stayed unchanged. This is still a failed full
experiment and does not establish capacity recovery.

Implement a separate explicit `startupPressurePolicy: minimum-before-source-v1`
replay option, defaulting to `reject`, available only with recovery-budget policy.
Retain the complete input and every raw pressure row. Before the first evaluated
source window only, require unchanged acknowledged minimum receipt/revision,
monotonic policy sequence and nonoverlapping bounded quarter-second windows,
fresh evaluation times, exact native unknown/missing/pressure reasons and no
application/candidate/reset authority. Reconstruct thermal/transport/queue endpoint
selection with the existing independent local-pressure replay. Give these rows
zero healthy duration. Subsequent source windows must begin after the pressure
watermark and establish all the existing fresh baseline, candidate admission,
cadence, probation and delivery gates. No local pressure after source evaluation
begins is accepted, including probation or post-confirmation events.

- [x] Test opt-in, defaults/unknown modes, raw mutations, ownership, timing,
  sequence, reasons, authority fields, after-source events and unchanged input.
- [x] Implement the narrow replay and propagate its explicit option through the
  pure full-trial helper. Leave the live harness/default route strict.
- [x] Replay the unchanged real artifacts under both contracts, preserving the
  original failure. Qualify media/audio independently where possible; report any
  additional failures rather than widening this contract. Review before commit.


## Startup replay and media checkpoint

All4,230 tooling tests passed, including the new explicit startup policy contract.
The positive tests failed before implementation, and an evaluation-clock reversal
mutation reproduced before its guard was added. Independent read-only review found
no actionable issues. The confirmed-prefix helper still qualifies only through
its reported confirmation boundary: any suffix, including later pressure, remains
unqualified. Full-trial replay rejects later pressure outright.

Final offline replay in `artifacts/qa/startup-pressure-replay-FFFQLI` retains the
strict-policy failure and separately passes explicit startup policy, confirmed
prefix and full native trial/media-delivery helper. All152 reconstructed delivery
windows are healthy, with zero late/missing/uncertain/below24/below30 rows. The
original source/input freeze still contains1,244 unchanged hashes. Replay source
and artifact hashes are saved separately and verified after replay.

`artifacts/qa/startup-pressure-media-mV08WO` independently verifies complete source
identity and A/V coverage: archive3,852consecutive frames0–3851, live3,402consecutive
frames236–3637. It verifies both score glyph states and27 phase/grid audio anchors
in addition to baseline checks (30 unique archive probes,29 live). Maximum absolute
live A/V lag is65.198ms; its spread is0.333ms. Archive alignment is within0.001ms.
The saved archive completion report is finished, has no first failure and valid
timing. The original harness had already completed full FFmpeg A/V decoding before
its policy rejection. This offline replay uses the saved decoded PCM, frame probes,
barcodes and crops; it does not claim a second decode or complete audio fidelity.

The native scheduling evidence is saved in `native-app-CLof0G/diagnostic-coordination-inspection.json`.
Candidate binding age was4.891s, satisfying the unchanged0.5s admission warmup.
Stage3 accepted padding through9.884s, and retirement preserved14,660,240 total
accepted bytes with reason`cancelled` during trial application, below16MiB. The
native trial admitted/applied/confirmed; no stale capacity was reused.

The original live harness remains failed under its strict contract. The new mode
is explicitly selected only by the pure offline helper; no production behavior or
live default changed. Capacity reduction/restoration, a reconnectable recorder,
fresh post-recovery ramp, true outage, physical camera/Watch and other hosts remain
open. Next, provide a session-aware reconnectable test recorder and choose a fault
rate from measured full wire costs before a new capacity experiment.


## Reconnectable recorder prerequisite complete

The session-aware loopback recorder is implemented and selected only for explicit
capacity diagnostics. Two real publishers using separate excerpts of the prepared
match successfully reconnect to the same endpoint; both90-frame outputs and audio
fully decode, and all saved source/input hashes are unchanged. Per-session native
recorder/timestamp manifests and aggregate lifecycle evidence are preserved.
All4,251 tooling tests pass; review found no actionable issues. See the
[recorder implementation and verification](2026-09-24-reconnecting-recorder.md).

This removes the one-connection sink limitation seen in`rQQICD`, but the native
capacity campaign has not yet been rerun. Full wire-cost measurement and an
appropriate capacity stimulus remain prerequisites; capacity adaptation, causal
recovery, fresh re-ramp and outage qualification remain incomplete.

## Measured next-stimulus design

`artifacts/qa/capacity-rate-calibration-fdthAF` independently replays complete proxy
packet timelines for both existing runs. Counts include IPv4/UDP28-byte overhead,
SRT/MPEG-TS traffic, audio and video. It requires a same-probe receiver report that
accounts for every final accepted padding byte with zero pending packets; selected
windows begin at least5s after that host receipt. All raw artifact/script hashes
are unchanged. This is diagnostic rate selection, not delivery/recovery proof.

For the single-profile240p run, nine5s windows (45s total) offer560.704–643.949kbps,
mean606.209kbps; its45 one-second windows peak736.800kbps. Selection includes one
pre-limit window and40s after unrestricted capacity was restored. Every selected
window has zero proxy overflow. Post-restoration sender traffic does not imply
worker recovery—the failed worker/recorder history remains failed.

For the confirmed360p run, twelve5s windows (60s total) offer835.430–957.421kbps,
mean878.490kbps; its60 one-second windows peak1,081.120kbps. The complete final
profile and raw post-padding traffic support this engineering choice. Calibration
does not independently bind each host bin to a native profile clock; the next
causal native experiment must still perform that join.

Choose a **750,000bps** laboratory limit: above the observed minimum-profile
one-second maximum and below every upgraded-profile five-second average. This
is a new test stimulus, not a production upload requirement or a guarantee for
other clips, devices or networks. Keep delay30ms, deterministic every500th-packet
loss,16KiB burst, queue bounds and all application pressure/freshness thresholds.

The new native run must also delay the fault: `CLof0G` confirmed at61.769s after
bootstrap, so the old60s schedule cannot reliably establish confirmation before
the fault. Add explicit profile`capacity750k` with limit at90s, restoration at150s,
and a210s hold to retain60s restored observation. Keep historical`capacity550k`
(60/120s,180s hold) intact so existing artifacts and tests remain reproducible.
Use at least330s prepared content; the earlier270s file is too close to the prior
archive-duration overhead for a210s hold. Do not reuse/truncate identities when
preparing longer representative footage.

Implementation/verification sequence:

- [x] Add a trusted named-profile table and explicit profile option to transport
  configuration/qualification, preserving the default historical contract. Test
  both complete schedules with the real synthetic queue, wrong selection,
  incomplete duration, rate/timing/counter mutations and unchanged old fixtures.
- [x] Propagate the selected trusted profile to clock scheduling, host route
  validation and the independent Swift fixture leaf. Exactly210s is required for
  `capacity750k`; exactly180s remains required for`capacity550k`. The clock verifier
  must still join actual requested/applied phases and bounded native brackets.
- [x] Test and build the native fixture with the existing installed iOS26.2 runtime.
  Keep normal capacity success denied; select the reconnectable recorder only via
  explicit diagnostics. Verify larger hold fits existing evidence budgets.
- [x] Prepare/hash at least330s of representative footage using the existing
  frame-identity/audio integrity workflow. Run one frozen210s native diagnostic
  campaign, join every owned process, and preserve all session evidence and
  original failures.
- [ ] Complete independent causal qualification that confirmation preceded the
  limit, an owned pressure decrease occurred and minimum media recovered after restoration.
- [ ] Only after those facts are established, implement full causal recovery and
  fresh post-recovery measured ramp qualification. A true outage remains separate.


### 750kbps profile implementation checkpoint

The explicit `capacity750k` laboratory route is implemented with a 210-second
hold and 90/150-second limit/restoration boundaries. Transport and clock
qualifiers take a trusted explicit profile; their default remains the historical
550kbps contract. Cross-profile evidence is rejected. Host, worker callback,
independent Swift selector and UI checks carry the same exact configuration.
The longer hold uses 128 source windows within the existing capacity evidence
budgets. Normal capacity success remains denied; this route is diagnostic only.

Verification: all 4,285 tooling tests and 567 app-model tests pass, and the arm64
iOS simulator build-for-testing succeeds with Xcode 26.2. The new native fixture
regression failed before implementation and passes afterward. Read-only review
found no actionable issues. Evidence is saved in
`artifacts/qa/repeated-live-checkpoint-capacity750-*`.
The 330-second fixture preparation and frozen native experiment are next;
no new capacity downshift or recovery claim follows from these checks.


### Frozen 750kbps native experiment

The implemented profile ran at commit `8a39b31` against the qualified 330-second
real-match fixture (`prepared-native-capacity750-GM019e`, SHA-256
`1b941060e76921c1dec03c8f9459baf5679aaf1b479fc0abb166b70575cf0a19`).
Preparation fully decoded both streams and verified all 9,900 consecutive source
identities and continuous audio. The prepared source and original longer fixture
were fingerprinted and unchanged; supplied Downloads recordings were not modified.

Native evidence: `artifacts/qa/native-app-5UYvcA`; frozen driver evidence:
`artifacts/qa/capacity750-diagnostics-freeze-5z50643n`.
The UI workflow passes in 299.821 seconds. The diagnostic harness deliberately
returns exit 1 with its explicit unqualified-result error, after joining collection.
All 1,248 frozen code/input/driver hashes remain unchanged. Its temporary iPhone
simulator was deleted, and no runtime was installed or user simulator removed.

Observed controller history (seconds after bootstrap):

- Higher-profile application: 47.303; logged trial confirmation: 66.545.
- Actual limit is independently bracketed at 88.966–89.470.
- Transport-pressure event: 91.728; owned `decrease` application to 240p: 92.190.
- Restoration is independently bracketed at 148.962–149.465.
- The app stays at 240p until publishing stops at 237.523. There is no fresh
  post-restoration increase, and no complete causal recovery verdict yet.

Both clock boundaries pass the unchanged four-challenge verifier. The worker
maintains one RTMP session; the recorder closes naturally with no rejected
connections, interruption, listener error or finish timeout. Collection errors
are empty. The limited phase forwards 4,599,264 wire bytes, with maximum queue
residence 503.989ms and no overflow. These are raw diagnostic observations, not
an accepted transport verdict.

Full `-xerror` audio/video decoding passes for both saved files. The clean 1080p
archive has 7,499 consecutive IDs 0–7,498 (249.967 seconds), continuous audio and
16ms of audio tail; archive queue diagnostics report no rejected/dropped samples.
The live file has 7,043 consecutive IDs 230–7,272 with no interior identity gaps.
It retains 1.383s of initial audio lead, within the existing acquisition allowance,
and 20.825ms of audio tail. The archive continues 226 source frames, about 7.53s,
after the last live frame. Media reports and hashes are in `diagnostic-media750`.
This does not establish instant startup or physical camera recording reliability.

Independent raw native media replay and three-phase compressed-frame/profile
replay pass. All 327 classified delivery windows are healthy at 30fps, with zero
late, missing, uncertain or below-24fps rows. The initial live phase still loses
60 acquisition frames before its first decoded identity. These component passes
must not be promoted to a complete policy/recovery result.

Two remaining verifier mismatches are preserved:

1. The strict transport verifier rejects missing phase traffic during export after
   intentional publisher stop. In both directions, last traffic is at about 238.1s
   after proxy start; the proxy closes at 268.7s. Every required baseline bin is
   populated; the missing restored bins are 242.35–267.35s. Do not trim or rewrite
   the original timeline. Design explicit scheduled observation coverage while
   retaining full-lifetime counter/prefix/conservation/queue validation, and test
   gaps within the requested observation separately from cleanup silence.
2. Full native evidence replay rejects action `decrease` where the existing
   decoder-recovery lifecycle expects `reset`. The genuine network-pressure
   action must retain its own raw pressure, receipt, application and source joins.
   Add an explicit capacity-only policy/lifecycle case; keep decoder-fault and
   historical defaults strict. Merely accepting either action name is insufficient.

Natural-audio checks of the unchanged files pass at 53 additional phase/grid
anchors: 56 archive probes and 55 live probes. Maximum absolute live A/V offset
is 65.949ms with 0.667ms spread; archive alignment is within 0.001ms. Both score
glyph states pass with full agreement. Reports and input hashes are in
`diagnostic-audio-score750`. This samples waveform alignment, not every audio
sample or physical capture fidelity.

Next: implement the explicit transport observation and capacity-pressure lifecycle
contracts with negative
regressions, then replay the unchanged artifacts. Full causal recovery, a fresh
post-restoration ramp, a true outage, production ladder integration and physical
phone/Watch tests remain open. A repeat native run requires a changed implementation
or distinct experiment, not an attempt to erase these recorded failures.

## Explicit observation and transport-pressure replay design

Routine autonomous design and implementation remain authorized. Two independent
prerequisites are next; neither grants a full causal recovery verdict.

### Scheduled transport observation

Preserve the current through-close traffic coverage as the default. Add an explicit
`coveragePolicy: 'scheduled-hold-v1'` option to the transport qualifier. Its restored
traffic window ends exactly 60,000ms after the *actual* restored phase application,
not at the last traffic packet or a caller-selected timestamp. Require that endpoint
within the original closed schedule and retain the profile's total hold requirement.
Baseline and limited phase boundaries remain actual applied timestamps. Require
traffic in every existing five-second coverage bucket of the scheduled restored
minute, plus the existing last-forwarded timestamp requirement. No raw artifact
can select this policy, and unknown policy names must fail.

Retain full-lifetime configuration, phase/prefix, timeline, packet/byte conservation,
closed queue/pending-send, deterministic loss, rate budget, congestion and error checks.
No overflow after restoration is allowed, including cleanup. Require healthy queue
residence at the scheduled restored window's final twenty seconds as well as the
existing final twenty seconds before closure. Return the selected coverage scope
and explicit false native/recovery permission. Post-window silence can be harmless;
post-window corruption or unjoined work cannot be ignored.

Use the real synthetic queue to test 60 seconds of restored traffic followed by
silent export time, default rejection of that same raw artifact, both profiles,
gaps/early stop inside the scheduled minute, altered late counters/errors/queue
state, insufficient close duration, and unknown policy. Replay unchanged `5UYvcA`
after tests/review. Never trim the saved timeline or replace its stopped timestamp.

### Capacity-only native pressure decrease

The existing recovery-budget decoder-reset route retains its exact semantics.
Investigate the complete `localPressure` event preceding the second native write:
raw local samples, prior evaluated window endpoint/sequence, active revision and
receipt, decision time/expiry, application ID/window sequence, request/ack times,
and native profile/bitrate receipts. The capacity route must explicitly select
this decrease variant and independently reconstruct the local pressure that
motivated it. Preserve retired candidate/probe snapshots without granting them
fresh authority. A blind `reset || decrease` acceptance is not the design.

Implement the bounded receipt/lifecycle prerequisite only after that join is
specified from native code and frozen evidence. Follow it with complete causal
policy replay against the qualified clock/transport bounds; first-confirmation,
post-limit pressure and stable post-restoration delivery remain separate gates.

The native source and raw run establish a quarter-second `localPressure` window,
using the same policy sequence as receiver windows. The next profile write names
that window sequence; its recommendation expires at window.end + 2s. The pressure
row retains the active trial's receipt/application metadata, and the subsequent
minimum write has null candidate authority. Add explicit boolean `capacityDecrease`
to lifecycle/native-evidence/retirement replay, requiring recovery-budget recovery
(and the capacity audit route in the outer evidence helper). Reconstruct local
pressure from expanded raw histories, require elevated transport and exact reasons,
join the prior policy endpoint/sequence, current receipt and original trial metadata,
and require the following owned write to use that same sequence before expiry.
Keep the later write's inactive probe/candidate history and every existing receipt
and completion check. Return local-decrease correspondence with recovery false.
The known source-confirmation log alone never proves confirmed policy; the later
full policy replay must establish that separately.

### Explicit transport/decrease checkpoint

Both prerequisites are implemented and reviewed. All 4,403 tooling tests pass
(`repeated-live-checkpoint-capacity-observation-pressure-tools.log`). Focused tests
were observed failing before implementation; pressure tests first needed a test-only
clone of immutable expanded sample entries before their mutations were valid.
The checked-in compressed regression fixture contains frozen metadata and frame
identity lists from `5UYvcA`, with source hashes and provenance; it contains no video.

Unchanged-artifact replay now passes scheduled transport, raw native media, native
profile transitions, raw local transport decrease, native lifecycle/retirement and
candidate witness joins. Strict through-close transport still fails as expected;
neither the original native harness result nor timeline is rewritten. Sources and
input hashes are recorded in `diagnostic-native750-explicit-capacity-replay.json`.
The first offline invocation omitted the already-required capacity cadence selector
and failed on that envelope; its result is separately preserved. With that explicit
selector, confirmed-prefix policy replay reaches an unsupported earlier rejection.

That rejection is `delivery-freshness` at 19.054s after bootstrap on revision 0,
before the trial. The native session rejects stale delivery observations and clears
recovery/pending candidate evidence. Its log has the current receipt but no original
rejected delivery sample. This cannot prove why that delivery sample was stale.
The next policy work must either conservatively model this invalidation without
healthy credit and independently validate all subsequent recovery/admission, or
capture additional diagnostic evidence for a new run. It must never silently drop
this event, infer a healthy sample, or accept such a rejection during probation.
Complete fault causality, restored policy/delivery and fresh ramp remain open.

### Conservative pre-trial delivery rejection

Choose explicit `preTrialRejectionPolicy: 'invalidate-delivery-freshness-v1'` for
recovery-budget confirmed-prefix replay only; default `reject` is unchanged.
This models the observed rejection's effect, not the unrecorded sample's actual age.
Accept only the exact baseline revision-0/minimum-profile receipt-bound log shape
and reason `delivery-freshness`, before any trial application/admission. It cannot
contain a window, source, candidate, application or action. Clear accumulated
recovery and the selected baseline; preserve consumed source/policy watermarks
just as `QualityController.invalidateTelemetry` does. The rejected event itself
consumes no policy window and earns zero healthy credit. Subsequent source windows
must independently pass their existing scope, monotonicity, ownership, pressure,
receipt age, cadence and admission checks. A rejection after the last healthy
window therefore cannot reuse that window to admit an upgrade. Reject during or
after trial/probation, changed receipts, unknown reasons/policies, extra authority
fields and clock regressions. Return an explicit invalidation count and zero
healthy credit; the suffix and complete recovery remain unqualified.


### Confirmed-prefix invalidation replay checkpoint

The explicit pre-trial invalidation policy is implemented. Its positive regression
failed on the unsupported rejection before implementation, then passed with all
negative cases. Review confirmed native invalidation semantics and prompted a
more specific assertion that rejection after the final healthy window fails the
healthy-baseline admission gate. All 4,418 tooling tests pass; the strengthened
15-test rejection suite also passes. Logs are
`repeated-live-checkpoint-capacity-prefix-rejection-*`.

`diagnostic-native750-prefix-replay.json` replays the same frozen `5UYvcA` artifacts.
Raw media/profile components, explicit scheduled transport, native lifecycle/probe
retirement/candidate joins and confirmed-prefix policy all pass. The default
through-close transport failure remains unchanged. Eighteen artifact hashes and
146 replay-source hashes were unchanged during this offline replay. It introduces
no new native run, physical device claim, or complete recovery result.

The first confirmed trial is independently reconstructed at event 14. Its decision
time is 22.421s before the conservative lower clock bound for the actual limit.
The qualified local transport-pressure window starts 1.956s after the conservative
upper bound for that limit. These component timestamps are now available for a
full causal join. The pre-trial rejection count is one, healthy credit is zero,
and the rejected delivery sample's own freshness remains explicitly unqualified.

Next implement the complete capacity suffix replay: keep separate source and policy
watermarks through short local-pressure windows and the native format transition;
verify every subsequent evaluated window against its original source, receiver,
pressure, receipt and cadence evidence; credit no recovery before the conservative
restoration boundary. Require independently covered healthy source and one-/two-
second delivery lanes after restoration, then join the preserved archive/audio/score
results. The original source and native histories must remain complete, including
all minimum-profile pressure events. A later fresh measured re-ramp and real outage
still need their own native campaigns. Production upgrades remain disabled.

## Complete capacity policy join

Add `qualifyMeasuredCapacityPolicy` with raw native metadata/decoded identities,
raw closed UDP accounting, raw native clock audit and host exchanges. Select the
trusted profile explicitly. Recompute scheduled transport, scope-bound clock
brackets, complete native evidence with explicit capacity decrease, confirmed
prefix (including explicitly chosen pre-trial invalidation), and delivery ownership.
Do not accept caller-supplied qualified summaries as authority.

Require confirmed decision AND log time before the limit's lower native bound;
require the reconstructed pressure window start after its upper bound, and the
completed decrease before restoration's lower bound. These checks bind independently
verified components without assuming a shared host/native epoch.

Replay every suffix event through the original stopped row. Keep source interval
sequence/end separate from policy window sequence/end. Each source event must join
one original source observation and its independently reconstructed proof, preserve
worker/reader/processing ownership, and consume the next source interval. A transition
may consume source coverage only when the native guard actually forbids evaluation
(mixed/wrong encoding configuration, a start before acknowledgment, or overlap with
the last policy window); it contributes no health. Evaluated source windows consume
the next policy sequence, retain exact native receipt, independently recompute raw
pressure and frame counts, and match fresh raw cadence evidence and decision reasons.
The selected run requires strong nominal source windows; unmodeled degraded source,
unknown or rejected suffix events fail closed, rather than being skipped.

Reconstruct all local-pressure windows from original samples with the prior policy
watermark, exact reasons/current configuration, and no source/delivery capacity
credit. Only the already-qualified first decrease may follow the higher-profile
pressure; subsequent minimum-profile pressure retains `minimumProfileInsufficient`
and cannot acquire authority. Pressure after restoration restarts recovery selection.
No recovery credit is earned before the conservative restoration upper bound.

Select whole contiguous strong source windows after restoration/latest pressure and
require at least ten seconds shared with BOTH independently reconstructed one- and
two-second delivery lanes, using existing recovery bucket thresholds. Retain whole
suffix cadence continuity and final delivery/decision bounds through actual audit
closure; later asynchronous publisher stop creates no additional telemetry coverage.
Qualify every delivery row's native/decoded/archive ownership. Return capacity policy
qualification only, with fresh-ramp, physical-device, media-file decoding and production
upgrade authorization false. The caller still owes full A/V decoding, clean archive,
score and waveform verification. This single-decrease route does not establish a
later fresh re-ramp or an outage; those remain separate campaigns.

Tests use the frozen real native fixture plus a separate hashed raw network/clock
fixture. Cover wrong profile/clock scope, confirmation after fault, pressure before
fault, late decrease, shifted restoration, omitted/reordered source or policy events,
forged transitions, changed receipts/pressure/counts/cadence/reasons, incomplete
post-restoration source/delivery lanes and extra authority. Preserve the original
artifacts and their strict result. Red/green, full tooling, review and frozen offline
replay precede changing any native success path.


### Complete capacity policy replay checkpoint

Implemented `scripts/measured-capacity-policy.mjs` and 39 focused tests. The caller
must explicitly select a trusted profile. The verifier now joins the original raw
network schedule, host/native clock brackets, measured admission and confirmation,
strict delivery coverage throughout probation, native pressure-driven decrease,
every subsequent source/policy event, and recovery after restoration. It reuses raw
media/receipt reconstruction; it never accepts a prior qualified summary as authority.

Review caught trailing omissions that ordinary sequence checks missed. The final
source must agree with the final raw cadence report; at most one unconsumed source
is allowed, with pending encoder frames and an age below the native two-second
wait bound. That pending interval earns no health credit. Each delivery lane must
extend through every bucket due by the final cadence observation, using the native
scheduler's configured latency/sample-age budgets. Every post-restoration recovery
bucket must remain healthy, including buckets after the selected ten-second window.
Missing probation delivery in either lane also fails. All eight new omission/profile
regressions failed before the corresponding fix; focused tests subsequently passed.
Independent review found no remaining actionable issues after these fixes.

The frozen `native-app-5UYvcA` artifacts passed a separate offline replay at
`diagnostic-native750-policy-final-replay.json`. All 20 raw input hashes and 147 replay
code hashes were unchanged. It verifies 15.000202 seconds of probation delivery,
then replays 32 source windows, six local-pressure events, and one transition.
Post-restoration source windows 30–31 supply 10.000051 seconds of shared recovery
with both delivery lanes. The full suffix is checked through native uptime
1966432.0250071252. The final pending source is 46 (nine pending frames, age
1.340779 seconds), with zero healthy credit. Final one-/two-second delivery coverage
ends at 1966430 / 1966429 respectively, before the next bucket becomes due.

The original strict transport result is preserved: it fails on post-stop export
silence. The explicitly selected scheduled-window transport check passes. This
checkpoint qualifies the capacity policy from saved raw evidence; it does not
rewrite the original diagnostic run into a native harness pass. Existing full A/V,
archive, glyph and waveform evidence remains separately recorded. Fresh re-ramp,
physical devices, broad quality ladder and production upgrade authorization remain
unqualified. No simulator or source video was changed for this offline checkpoint.

Next, connect this bounded capacity qualifier to a distinct native harness success
route, preserving diagnostic-only mode and ordinary strict defaults. The route must
run the existing full media/archive/audio/scoring checks, explicitly use scheduled
capacity transport coverage, and save capacity policy evidence separately. Inspect
all downstream legacy cadence/profile/deadline entry points before removing the
current harness guard; capacity evidence must not fall through to steady-trial or
decoder-pause qualification. Freeze and run a fresh native experiment only after the
routing and failure cases pass local tooling tests. Fresh measured ramp-up after
restoration remains a subsequent experiment.


### Native capacity success-route implementation

The explicit non-diagnostic capacity route now dispatches scheduled-window transport
and the complete capacity policy before reporting native success. It preserves all
existing A/V decode, archive, ingress, score glyph, direct-recorder terminal/frame,
and natural-audio requirements. Native profile phases are returned separately from
the trusted capacity profile label for phase/grid audio anchors. Raw capacity clock
exports and transport data are bounded on read. Capacity evidence has its own output
artifact, results field and final assertion; it cannot satisfy the steady-trial or
decoder-pause success route. `--capacity-diagnostics` retains its reconnecting recorder
and unconditional non-passing behavior. Normal capacity validation uses the existing
strict single-session recorder.

The old native preflight guard failure was reproduced before edits in
`capacity750-qualified-freeze-fo6nor8f`. The positive native profile regression also
failed before the return field was added. The now-obsolete test requiring all
capacity runs to stop at that guard is replaced with an incomplete-route rejection
before any artifacts/resources. Independent integration review found no actionable
issues. A fresh frozen native run is required to establish this route's actual
end-to-end outcome; this wiring alone is not a passing media experiment.


### Fresh native run exposed a measurement wake-up race

Runner wiring is committed at `9409438`; all 4,457 tooling tests pass. A fresh run
`native-app-V7e8Zi` on the existing iOS26.2 iPhone14 simulator completed its UI
workflow in 300.064 seconds. Both full A/V decodes, source identity checks,
natural-audio checks and score glyph checks completed before transport qualification
failed with **Insufficient offered load**. The archive contains 7,497 consecutive
frames (0–7,496); the live file contains 7,045 (230–7,274). The run remained at240p
and offered at most741,792bps during the750,000bps limit, so it correctly cannot
qualify a congestion/decrease/recovery campaign. Its original failed result remains
preserved. All1,255 frozen source/input/driver hashes were unchanged; the wrapper
joined with exit1 and the owned simulator was deleted. Evidence:
`capacity750-qualified-freeze-2orvqqbd` and the run's
`candidate-wakeup-assessment.json` (eight independently checked raw-input hashes).

The candidate trace records68 `contextUnavailable` reads and a deadline without
starting measurement. Final stage3 had the correct active probe; its final reason
was later `byteLimit`. After probe warmup, source7 was evaluated at bootstrap
+41.762214 seconds and remained eligible only through+41.838049 (~75.69ms).
Candidate context reads at+41.760305 and+41.862261 straddled that interval. Source6
had expired before the final probe's warmup; source8 arrived after the candidate
wait deadline. No context read began inside these recorded freshness windows.
This identifies a polling race rather than permission to reuse stale health.

The implemented fix is a coalesced notification after a successful native
source evaluation. It wakes the candidate scheduler immediately but carries no
context, receipt, probe or admission authority. The scheduler must requery all
current ownership/freshness/lease checks. Capture a change revision before async
probe/context reads to avoid a lost wake-up, retain the existing timeout as fallback,
and cancel/join the pending wait on stop. Keep the current two-second source age,
probe leases, scope checks, trial thresholds and campaign deadlines unchanged.
Two focused native model regressions have failed on the original behavior: a
long-poll candidate misses newly available readiness, and the driver neither
notifies nor clears its notification callback on stop. Green tests, full model
coverage, review and a fresh frozen native run must follow before claiming repair.


Wake-up verification: all 574 app-model tests pass (89.514 seconds), including
coalescing before registration, signal/close after registration, cancellation,
timeout, signals during suspended probe/context reads, immediate candidate retry,
and driver notification/stop revocation. Independent review found no actionable
issues. The initial red run had a test-only clock setter typo; after correcting it,
the two regression methods failed with six intended assertions. The full green run
is `repeated-live-checkpoint-capacity-readiness-wakeup-model-green.log`. The next
native run will retain the same750kbps profile and media input; no threshold,
probe lifetime or campaign deadline was relaxed.


## Fresh native wake-up repeat and clock failure

The frozen `0c16b43` run `native-app-aRYRfO` joined with exit1. Its 1,255 frozen
source/input hashes were unchanged, its UI workflow passed in300.835s, and the
owned temporary simulator was deleted. No runtime was installed. The candidate
now binds fresh source health, starts its measurement and joins it successfully.
The native audit records a360p trial applied47.264723s after bootstrap and a240p
decrease at90.193810s. This verifies the wake-up repair in the real workflow,
not the full causal recovery policy.

The clean local archive fully decodes and has7,503 consecutive frame identities
0–7,502. The direct stream recorder exits naturally with code0 and no requested
termination. Full live-media qualification did not run because collection failed
first: the first host/native clock exchange exceeded250ms. The closed native
clock audit contains only sequence1. No complete host clock file was emitted.
Do not infer missing fault brackets from shared epochs or approximate schedules.

Raw cadence evidence also retains six freshness rejections. Near89.23s, the
control response spent149.954ms in HTTP and273.641ms awaiting the native probe;
its total sample age was547.598ms, beyond the250ms budget. The adjacent report
gap was625.848ms. Later HTTP delays at178s and195s also yielded stale reports.
These unknown intervals cannot earn healthy credit, and the current complete
capacity verifier correctly rejects such suffixes. The observations do not prove
that the clock scheduling repair will remove these separate freshness failures.

Inspection found that the lab-only clock responder is called solely from
`pollControl()`, behind its busy gate and network work. Its next bounded repair
is an owned cancellation-aware polling task, activated only by the existing
DEBUG fixture factory, joined before closed export. Keep the250ms exchange
and1.5s fault-bracket limits unchanged. Test response while network recovery is
explicitly suspended, cancel-before-start, joined shutdown, immutable export and
no samples after closure before another native experiment.

The compact read-only assessment and nine raw-file hashes are saved in
`artifacts/qa/native-app-aRYRfO/clock-and-freshness-assessment.json`; reproduction
is `artifacts/qa/assess-capacity750-aRYRfO.mjs`. Every qualification/production
authorization flag remains false. The original failed artifacts are retained.


## Independent clock responder verification

The regression reproduced before repair: a request written while snapshot recovery
was suspended had no response. The DEBUG capture model now starts an owned task
only when its existing clock fixture factory returns an instance. The actor polls
at10ms intervals with cancellation-aware sleep. Publisher detach cancels the task
synchronously and joined teardown awaits its completion before closed export.
`pollControl()` no longer drives clock polling. Scope, nonce, sample limits and
all host clock budgets remain unchanged. No Release media or quality behavior changed.

The focused eight tests,99 capture/clock regression tests, and complete576
app-model tests pass; all child processes joined. The full suite took89.898s.
Logs use the prefix `artifacts/qa/repeated-live-checkpoint-capacity-clock-polling-`
with `red`, `green`, `regression`, and `full-model` suffixes dated20260924.
Read-only spec and lifecycle reviews found no actionable issues. The test's
two-second response timeout proves independence from suspended network control;
it does not establish the native experiment's250ms exchange limit. A frozen
real-match repeat is required for that claim.
