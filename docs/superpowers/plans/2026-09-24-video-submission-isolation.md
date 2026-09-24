# Bounded native video submission

Follow the reviewed [design](../specs/2026-09-24-video-submission-isolation.md).
Work only in the existing isolated checkout. Parent owns heavy commands serially.

- [x] Add deterministic blocked-conversion/audio-drain and single-operation tests;
      preserve failing results against synchronous SRT submission.
- [x] Add prepare/run/commit operation ownership in the codec and outgoing adapter,
      preserving synchronous callers. Keep actual submission clocks in the worker.
- [x] Integrate one SRT operation and an idempotent commit barrier for encoded output.
      Add synchronous-yield-before-return, failed-return and obsolete-output tests.
- [x] Add bounded mutation gates for async settings, verified bitrate and replacement.
      Verify last-old-frame receipts, no overtaking, first-new-sync handling and gate
      release before waiting for replacement output.
- [x] Integrate finish and shared close retirement. Test close/cancellation during
      conversion and mutation, re-publication, deadline abort and accepted-tail drain.
- [x] Review ownership, cancellation and protocol compatibility. Regenerate the
      maintained vendor patch from verified baseline files; verify exact round trip.
- [x] Run affected vendor tests, clean SDKProbe and Streaming, native models and
      simulator build. Broaden only where dependencies or new failures require it.
- [ ] Commit and freeze tracked source hashes. Run a capped real 4K campaign that
      stops at its first failure; verify archive completeness and live behavior.
- [ ] Run the strict repeated adaptive native fixture, join all owned jobs, audit
      unchanged source and cleanup, and retain every failed artifact. Never replace
      a failed outcome with a rerun or relax its freshness/media gates to obtain PASS.
- [ ] Update the main plan with qualified behavior, remaining limitations and next
      physical-device/portable-worker work. Production upgrades remain disabled.

Starting runtime source: `d73461b`. Its focused/full model and JS checks pass, but
complete repeated qualification remains failed due to first-trial cadence expiry
in `native-app-hT3aOi`. Earlier `89926f4` remains the prior complete laboratory pass.
Real 4K publishing remains failed at the audio queue on `582a339`, while its archive
completes. Do not erase either limitation while implementing this separate fix.

## Implementation checkpoint

Native conversion now runs in one immutable retained operation outside the SRT actor.
Codec preparation and idempotent commit remain actor-owned. Audio and the transport
pump can drain concurrently. A reserved mutation gate prevents raw input from
passing settings, verified bitrate or replacement work; close retains the native
worker until it returns before invalidating its session. The video consumer joins
one operation snapshot before interpreting early output, then uses current time for
pacing. Existing queue bounds are unchanged.

Review identified and fixed probe admission during a suspended mutation, stale
pre-join pacing time and a raw-to-passthrough transition during mutation admission.
All have preserved failing regressions and passing fixes. Additional tests cover
bounded newest-frame eviction, accepted tail drain, bitrate cancellation and exact
last-old-frame receipts, close/reuse, early replacement success/failure/close,
notification invalidation inside conversion, fresh-session recovery and duplicate
commit rejection. Independent review approves the resulting changes.

All 306 vendor tests in 37 suites pass. The first full run exhausted the cooperative
pool when many deliberately blocking test gates ran concurrently: 39 issues clustered
at their five-second expiry. Its log is retained. Serializing TSWriterStartupTests
preserves each test's internal concurrency while bounding simultaneous test gates;
the complete suite then passes in 1.297 seconds. No runtime timeout or queue limit
was relaxed. The maintained patch verifies all 162 original hashes and exact round trip.
Clean SDKProbe (10 tests) and Streaming (170 tests), all 502 native model tests,
and the arm64 iPhone simulator build also pass. All owned commands have joined.
Real-media checks are next.
