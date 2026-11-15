# Source-cadence pacing implementation plan

> **For agentic workers:** Use superpowers:executing-plans for this authorized evidence-driven continuation.

**Goal:** Prevent native encoder drain batches from reaching the muxer ahead of the established source cadence, then measure whether constrained-uplink delivery improves.

**Architecture:** Add an opt-in immutable encoded-video pacing mode to SRTStream. A scalar cadence clock maps source deltas to system uptime using the first compressed output. The existing owned video consumer waits until eligibility; audio and transport remain independent. No additional per-frame tasks or payload copies. Keep the mapping through encoder replacement and reset it for a new publication.

**Tech stack:** Swift 6, CoreMedia, existing HaishinKit bounded queues/lifecycles, native simulator fixture and Node qualification.

## Contract

This follows measured 301–395 ms drain leads, not a new assumed latency. Eligibility is max(now, first output uptime + exact source delta). No fixed delay is added and late frames are not delayed further. Invalid/nonmonotonic source or uptime, arithmetic failure, or a source lead greater than one second fails publishing explicitly. The consumer checks generation/cancellation/failure both before and after suspension. Finish joins it under the existing deadline; close cancels it and stale work cannot publish into a later attempt.

The measured replay requires up to 12 pending frames. The encoder output queue is currently eight frames, so simply sleeping its consumer would overflow. Use a 16-frame queue only for this opt-in experiment, retain the existing 2 MiB per-frame limit, and preserve explicit overflow failure. This is a bounded compressed encoder queue adjustment, not a transport-queue increase. Default behavior remains unchanged. Raw compressed passthrough does not claim this encoded-video pacing policy.

Record actual consumer dequeue and post-wait observation times alongside the existing frame bytes/source/sync metadata. Dequeue time is not native completion; `sourceCadencePaced` records the executed encoded-consumer path. This must expose real waiting and eligibility without relabeling encoder completion as mux delivery. The DEBUG native fixture requires explicit `SCOREBUG_TEST_SOURCE_CADENCE_PACING=1` plus adaptive-profile prerequisites; it records and forwards the choice. Production default remains off.

The sustained upward trial measured 7.82 Mbps video on a 4 Mbps link and remains a separate capacity problem. Pacing does not establish capacity and must not relax archive, identity, cadence, freshness, operation deadlines or queue failure gates.

## Tasks

- [x] Test scalar cadence behavior: first/normal/late output, burst, rational large PTS, source/clock reversal, excessive lead and fresh publication reset.
- [x] Implement scalar clock and opt-in existing-consumer pacing with bounded output queue selection. Test real native finish/frame preservation, cancellation and restart, replacement continuity, deadline and overflow. Reconstruct maintained SDK patch and verify original hashes/round trip.
- [x] Wire the immutable setting through the streaming adapter and DEBUG adaptive fixture, with strict early option validation and preserved unset behavior. Retain actual available/observed times; qualify them independently and reject missing or contradictory pacing evidence.
- [x] Run SDK, streaming, app-model and tooling suites plus combined unsigned Release build; review lifecycle/source consistency before the native experiment.
- [x] Snapshot source, repeat the same 240-second rate4m native experiment with source-cadence pacing as the sole added behavior flag; join all owners and keep failed gates.
- [x] Compare independent archive/live identity/coverage, actual pacing delays/queue bounds, and native receipts/freshness. Verify cleanup, hash final evidence and commit the measured outcome.

Apple commands use Xcode 26.2 in the existing isolated worktree. Do not accept the Xcode 26.6 license. Heavy workloads run sequentially and reuse existing build directories; disk is limited. No external deployment/broadcast or physical-device qualification is implied.

## Pre-run verification

Causal red checks cover the missing scalar scheduler, stream option/observations, DEBUG flag/dequeue capture and raw verifier enforcement. The SDK passes 168 tests, including real native paced-tail preservation, injected wait cancellation and restart, finish deadline, exact queue-overflow failure, and replacement output eligibility against the original publication anchor. The latter addresses the review's nonblocking regression suggestion. There are 212 passing app-model tests, 1017 tooling tests and 61 streaming tests. SwiftPM's existing streaming scratch directory initially retained stale source discovery for the new clock file; refreshing the unchanged manifest timestamps forced a successful graph refresh. The SDK patch verifies all 162 original hashes and its exact reverse/forward round trip. Review found no blockers.

Queue ownership is at most sixteen queued compressed samples plus one current consumer-held sample, retaining the 2 MiB per-item limit. Source-cadence pacing runs only on the encoded output consumer. `dequeuedAt` measures taking that current item, not when VideoToolbox produced it; `sourceCadencePaced` comes from the executed consumer path. The independent qualifier requires actual mode=true for the experiment, checks dequeue order and eligibility across all phases, and leaves late frames visible.

## Measured native outcome

The combined unsigned iPhone/Watch Release build also passes. There are **1458** passing tests across the SDK, streaming, app-model and tooling suites. Runtime source is snapshotted against ba1d337. Native run `native-app-xJ7FLN` has exactly the prior compressed-frame experiment's saved settings plus `sourceCadencePacing: true`. The native UI workflow passes. The full runner fails live end coverage at **−158.2 ms**, outside the unchanged 100 ms budget; independent identity/cadence analysis also fails.

- Archive: **8203 consecutive 1080p/30 frames**, 273.433 seconds, **136/136** audio timing markers, 16 ms end coverage difference and zero rejected/dropped queue samples. Independent recording remains intact.
- Native: **7828** consecutive encoded frame records across five phases, all with actual `sourceCadencePaced: true`. Independent dequeue/order/eligibility checks pass. Maximum current-item wait is **35.53 ms** and maximum requested source lead is 33.06 ms. The last ten frames of every phase now span **299.95–300.66 ms**, rather than 26–80 ms. The original source clock survives all four geometry changes; no compressed encoder overflow terminates publication.
- Phase-relative peak 100 ms output bins are **129733, 98068, 170984, 118199 and 171048 bytes**, containing three or four frames. These are observed bins, not sliding-window rate bounds. Native-source lateness medians are about 1.06–1.44 ms; maximum lateness is 96.7 ms in the initial phase. This proves the intended scheduling, not end-to-end latency.
- All **86** local pressure windows replay and four profile applications bind to actual native receipts within their two-second operation budgets. Completion takes **448–472 ms**. Actual sender delay remains 400 ms on 1002 retained samples. Source-evidence age is median **1.616 seconds**, maximum **1.805 seconds**, below the unchanged two-second freshness limit.
- Live: **7638 pictures** spanning 7768 source positions, **167 absent unique identities**, **37 repeated observations**, **27 non-increasing barcodes** and 39 identity/cadence anomalies. Worst receiver cadence is **12.8 fps**; positive audio-PTS gaps total 192.4 ms. The worker reports 216 decode-error messages and the relay one lost/recovered timing episode. These messages are not frame counts.
- Both **2624-bin** proxy timelines reconcile without omissions. Forward overflow is **713 packets** (previously 821), maximum residence **525.14 ms**, and peak receive bin **144096 wire bytes** (previously 139264). Reverse overflow remains zero. The two successful relay snapshots preserve the same connection identities; neither read-leg sample reports loss. These are partial counter snapshots, not terminal delivery totals.

The measured phase video payload rates remain **6.038, 3.530, 7.850, 3.529 and 6.012 Mbps**. In particular, the 38-frame upward trial still injects nearly twice the constrained link's capacity before audio/transport overhead, and most overflow is in that trial/rollback interval. Receiver identities 1984–2031 and 3585–3643 resume at native sync points 2032 and 3644. The new low-profile first-frame identities 1972 and 3556 are absent downstream. Native sync metadata is not independent bitstream or pixel-integrity proof.

## Decision and remaining work

The experiment removes the measured native drain batching while preserving frame continuity, replacement deadlines and the archive. It does **not** meet the live requirements or consistently improve picture integrity. Keep source-cadence pacing opt-in and production adaptation disabled. The slightly better overflow/count metrics cannot justify promoting it, particularly with more repeated identities and worse audio coverage.

The next priority is **upward capacity admission**: establish fresh usable headroom against the measured cost of a candidate profile before initiating a high-resolution trial. Existing native evidence retains sent/retransmitted bytes, RTT, queue delay and pacing ceilings; those are not an independent capacity estimate. Inspect/measure actual SRT bandwidth/ACK evidence against known local rate phases before treating it as usable capacity, and use a bounded probing approach if that estimate is not reliable. Do not hard-code the fixture's known 4 Mbps limit into production decisions, substitute requested encoder bitrate for measured cost, or simply disable all future upgrades. Sustained constrained-link recovery and live audio/picture integrity remain required.

Native, collector, build, test and analysis owners are terminal and joined. Finalization verifies exact simulator/container removal, stopped collection, runtime equality to the snapshot, and identical stopped/final quality evidence before hashing terminal artifacts. Evidence is in `artifacts/qa/source-cadence-*` and the native directory. About 16 GiB remained after this run; continue reusing build directories and avoid unnecessary media copies. Physical iPhone/Watch routes, long soaks, remote hosts and production enablement remain open.
