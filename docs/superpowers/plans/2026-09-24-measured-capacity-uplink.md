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
