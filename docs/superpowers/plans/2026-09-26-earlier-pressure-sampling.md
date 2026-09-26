# Earlier pressure sampling comparison

**Goal:** Reduce detection/scheduling delay during the ordinary 720p bandwidth collapse without weakening media acceptance or increasing media buffering.

**Status:** Implementation reviewed; focused media/controller tests and Debug/Release builds pass. App regressions pass; full media comparison pending. Ordinary pacing activation has been reverted after no demonstrated benefit. SDK pacing remains optional. Complete the available paired physical test before any heavy build or simulator capture.

The app will select a100ms publishing-health interval and100ms local-health loop. Keep the reusable Media API default250ms and keep all existing pressure thresholds,250ms evidence intervals, native receipt guards, serialized work and stop/cancel semantics. This is a Scorebug experiment, not a published platform constant or guaranteed response deadline: each loop still awaits native work.

At100ms,64samples retain only6.3seconds. Increase transport and thermal scalar histories together to160samples (~15.9seconds), preserving former nominal coverage and enclosing samples for a5.25second source interval evaluated3.5seconds later. These histories contain scalars; no media queues grow. Retain gap clearing, quarantine, exact counter deltas, detached snapshots and no extrapolation.

- [x] Regression tests fail on old retention: aged5.25second source interval,7second measurement, early pressure maximum and bounded eviction.
- [x] Implement160sample histories and app-owned100ms selection for both loops. Preserve media API defaults and existing lifetime guards.
- [x] Focused Media/app/Core checks, relevant ownership/lifecycle tests, DebugUI and Release builds; independent source and quality reviews.
- [ ] Repeat ordinary recovery720 with the same verified source,750kbps cap,700ms SRT delay and3000ms broadcast timing. Join all jobs before capture.
- [ ] Verify native/transport/geometry and full three-output A/V. Compare pressure observation/evaluation/native ACK, overflow onset/count and queue residence. Do not reconstruct unsampled receipts or accept control success as media success.

If reaction advances but media still loses frames/audio, retain the failure and investigate encoder application/queued old output. Do not widen deadlines or retransmission/media buffers merely to hide collapse loss.

Evidence and chronology belong in [session log](../../session-logs/2026-09-26-earlier-pressure-sampling.md). Published-platform rationale remains in [research](../../research/2026-09-25-live-platform-adaptation.md).
