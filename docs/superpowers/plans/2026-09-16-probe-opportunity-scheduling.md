# Probe opportunity scheduling implementation plan

> Execute inline using the applied executing-plans and test-driven-development skills. Existing autonomous authorization covers this bounded implementation and local verification.

**Goal:** Remove the measured one-message-per-video-frame probe bottleneck while preserving a single socket-writing transport consumer, media priority, bounded optional traffic and joined teardown.

**Architecture:** Extend per-publication transport accounting with one coalesced wake stream. Successful media enqueue and output termination signal it. The existing transport task drains queued media first, then may offer one optional packet. A probe-owned strict dispatch timer only signals that same consumer; it never sends or queues data. Its deadline follows the remaining token delay with a 2 ms minimum, so the producer has bounded wake frequency and no catch-up traffic. All sends retain the existing one-message token cap, native nonblocking write, statistics checks and synchronous revocation. No timer exists without an admitted probe.

**Alternatives:** Multiple packets after each frame would introduce bursts and stay coupled to frame rate. A separate sending task would complicate media precedence, socket ownership and close cycles. Coalesced wakeups keep one writer and separate eligibility from camera cadence.

**Files:** `TransportOutputAccounting.swift` owns wake coalescing/termination; `TSWriter.swift` signals output lifecycle; `SRTBandwidthProbe.swift` computes remaining token delay; `SRTStream.swift` owns wake-only timer and transport draining. Tests live in the existing bandwidth-probe and stream-padding suites. Maintain SDK README and exact upstream patch provenance.

- [x] Add a native socket stream regression: after one startup frame, 1 Mbps probe traffic continues without more frames, reaches at least 80% of its accounted target during a finite observation, and then expires without further acceptance. Run focused Swift tests and retain the failing result.
- [x] Implement one buffered wake signal per output generation. Enqueue signals only after successful admission; finish wakes and terminates without losing queued media. The sole consumer drains its existing bounded data stream before offering padding.
- [x] Compute next token delay under the probe lock. Start one owned task after successful probe admission; a strict dispatch timer schedules at least 2 ms ahead and signals only the captured publication accounting while the permit remains valid. A checked continuation joins its cancellation handler even when task cancellation precedes timer resume. Finish and close revoke, cancel and join it. The timer handler never awaits a socket/connection operation, avoiding teardown cycles.
- [x] Exercise wake coalescing, closed output, token delay/no catch-up, pending media priority during blocked send/statistics hops, timer cancellation, finish drain and publication restart. Update old opportunity-count assumptions to test the revised schedule while retaining causality.
- [x] Run SDK tests, streaming adapter tests, ARM64 simulator test build and combined unsigned iPhone/Watch Release build sequentially. Rebuild and verify the vendored patch from independently verified upstream hashes.
- [ ] Review concurrency and ownership. Run the real native renewal fixture with unchanged archive/live gates, then pressure if renewal meets the actual target. Keep receiver capacity/adaptive quality disabled until authenticated receiver delivery and measured candidate-cost admission exist.

**Acceptance:** Source tests must prove single-consumer media precedence and finite ownership. Real acceptance must report actual bytes/time rather than requested rate; target at least 90% accounted rate in a healthy simulator interval, with all existing archive identity/audio, live identity/cadence/A/V and owner-termination gates. Sustained CPU starvation may underdeliver; it must never create a catch-up burst or be mistaken for headroom. Physical phone/Watch, remote host and adaptive quality qualification remain separate open requirements.

## Measured timer selection

A 10 ms `Task.sleep` diagnostic on this machine produced roughly 10–17 ms delays across background, medium and high priorities, even with zero requested tolerance. The first scheduler therefore delivered only ~0.72–0.76 Mbps in its 1 Mbps regression. A strict dispatch timer diagnostic stayed near 10 ms, and the revised stream regression reached ~0.94 Mbps including startup quantization. [Apple documents strict timers as best effort](https://developer.apple.com/documentation/dispatch/dispatchsource/timerflags): this is not a hard real-time guarantee. Existing token and deadline gates remain authoritative.

A gated cancellation regression also reproduced premature completion when joining via a cancelled AsyncStream iterator. The owner now waits for the dispatch cancellation handler through a checked continuation; only that callback proves the entered timer handler has returned.

## Source and build verification

All 197 SDK tests and 70 streaming adapter tests pass on the reviewed sources. The 1 Mbps and 2 Mbps finite tests meet their 80% unit-test floor; receiver-qualified usable capacity is not inferred. ARM64 DEBUG simulator build-for-testing and unsigned combined iPhone/Watch Release builds pass. The upstream verifier checks all 162 original hashes and exact forward/reverse patch reconstruction, including the new timer source.

The adapter's initial incremental build omitted the newly added dependency source from its cached SwiftPM plan. Cleaning that package's build cache resolved the missing-symbol build error; the final adapter and Xcode builds pass on the same source inventory.

Review identified two ownership gaps, each reproduced before fixing: concurrent close callers must share teardown before republishing, and a finish call overlapping close must still join any original finish/replacement owner. Shared close ownership and preserved join precedence now enforce both. The final bounded re-review found no blockers. Sources before native qualification are recorded in `artifacts/qa/probe-schedule-runtime-source.json`.

The actual native renewal run is `native-app-LZBHFN`, with a 90-second hold and the same fixed540p live / independent1080p30 archive settings and diagnostic gates as the prior baseline. The parent command exits zero and all owners terminate/join; the independently verified result follows.

## Real renewed-probe result

On the captured reviewed runtime, `native-app-LZBHFN` passes the native UI/scoring/export workflow and all diagnostic media gates. The probe renews 489 times and accepts 4,553 messages (5,991,748 payload bytes) over 50.040748 seconds: **0.957899 Mbps payload / 0.989926 Mbps accounted** against the requested 1 Mbps. Last acceptance is 205.035 ms before the final lease deadline. Media continues 42.850 seconds after last probe acceptance.

The independent archive preserves all 3,727 consecutive 1080p30 identities and 62 expected audio markers, with +10.667 ms A/V end coverage. Fixed540p live preserves all 3,351 consecutive retained identities (192–3542), all 55 audio markers and +30.948 ms end coverage. Its 36 startup acquisition frames remain separately accounted. Minimum reported receiver cadence is 29.6 fps, above the unchanged 24 fps floor. Both full decode logs are empty.

Forward and reverse proxy totals exactly reconcile with timeline bins: zero injected, overflow, oversized or close-discard drops; no errors, foreign packets or pending packets. Peak forward residence is 2.927 ms. Native UI, worker and recorder owners all exit zero and the status collector/proxy close.

`verify-probe-schedule-native.py` independently reconstructs saved barcode identities and validates renewal causality, receiver windows, A/V coverage, proxy conservation, owner termination and at least 90% of the requested accounted target. Six deliberately damaged copies are rejected, including lower accepted throughput that still obeys packet/deadline bounds. The runtime source inventory is checked by hash. This proves finite local acceptance with healthy fixed-profile media; it does not prove receiver-attributed headroom or candidate-profile capacity.

## Failed pressure attempt and next action

Pressure attempt `native-app-2jcK34` terminates with parent exit 1 / UI workflow exit 65 on the same sources. The archive fails with queue overflow after roughly 22 seconds of source video; streaming consequently stops. The probe has **zero events** and was cancelled before admission. Last forwarded traffic precedes the scheduled 4 Mbps phase by about 40 seconds. This run never reaches probe-pressure qualification and must remain a failed recording run.

The archive's first rejection finds 24,946,560 queued bytes against the unchanged 25,165,824-byte limit, with a further 3,114,720-byte video sample unable to fit. Terminal evidence records 1,316 written samples, one rejection and 17 queued samples discarded. Saved fragments are retained, but complete recording preservation is not proven.

Retained producer evidence shows frames 635–666 arriving over only 0.129775 seconds, after the first retained frame is 1.486636 seconds behind its deadline. `FixtureCameraSource` uses an absolute frame schedule and emits overdue frames without spacing, consistent with this catch-up burst. The retained persistence operations peak at 28.361 ms; the diagnostic history does not establish the initiating stall. This does not prove the new transport consumer is unrelated, nor does it implicate an optional timer that never started.

The parent command, UI runner, worker, recorder, collector and proxy terminate; their failure evidence is retained in `probe-schedule-pressure-failure-analysis.json`. No thresholds were loosened and no rerun was substituted for this result.

**Next:** deterministically reproduce the observed delayed producer / catch-up burst against the archive consumer, then address source pacing and recording reliability without hiding missing frames, widening acceptance gates or confusing simulator timing with physical camera proof. Repeat pressure qualification after resolving that evidence. Receiver-attributed probe delivery and candidate-cost admission remain afterward; production adaptation remains disabled.

Terminal source/evidence hashes are recorded in `artifacts/qa/probe-schedule-final-verification.json`, including both the passing renewal and failed pressure attempt.
