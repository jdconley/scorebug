# Bounded native video submission

Follow the reviewed [design](../specs/2026-09-24-video-submission-isolation.md).
Work only in the existing isolated checkout. Parent owns heavy commands serially.

- [ ] Add deterministic blocked-conversion/audio-drain and single-operation tests;
      preserve failing results against synchronous SRT submission.
- [ ] Add prepare/run/commit operation ownership in the codec and outgoing adapter,
      preserving synchronous callers. Keep actual submission clocks in the worker.
- [ ] Integrate one SRT operation and an idempotent commit barrier for encoded output.
      Add synchronous-yield-before-return, failed-return and obsolete-output tests.
- [ ] Add bounded mutation gates for async settings, verified bitrate and replacement.
      Verify last-old-frame receipts, no overtaking, first-new-sync handling and gate
      release before waiting for replacement output.
- [ ] Integrate finish and shared close retirement. Test close/cancellation during
      conversion and mutation, re-publication, deadline abort and accepted-tail drain.
- [ ] Review ownership, cancellation and protocol compatibility. Regenerate the
      maintained vendor patch from verified baseline files; verify exact round trip.
- [ ] Run affected vendor tests, clean SDKProbe and Streaming, native models and
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
