# Owned automatic recovery qualification

Goal: verify a fresh automatic 240p → 360p → 240p → 360p cycle through the native
app, clean archive, proxy overlay and recorded destination after capacity returns.
This is a separate contract from existing three-phase capacity and five-phase
decoder-fault runs. Preserve their selectors and acceptance rules.

- [x] Add `capacity750k-retry`: 750 kbps limit at 90 seconds, restore at 150,
      270-second hold. Require exact `SCOREBUG_TEST_OWNED_MEASUREMENT=1`, the complete
      staged file route and token-budget evidence; reject partial/mixed selection.
- [x] Add `owned240` transition evidence, format version 10, exactly four phases
      and three native receipts. Verify every compressed frame and native boundary;
      preserve versions 8/9 and their existing phase counts.
- [x] Prepare and fully qualify at least 360 seconds of timestamped source media.
      Keep the existing `holdSeconds + 90` input guard. Retain original source and
      hashes, full decode, frame identity and audio continuity evidence.
- [x] Wire the actual owned app route and bounded lifecycle artifact. Native
      operations, final candidate binding, guarded application and exact cleanup
      must be real; exported booleans cannot create authority.
- [ ] Add whole-history owned lifecycle, witness and policy replay. Reuse complete
      media, capacity clock/rate-ledger, delivery ownership and coverage checks.
      Never call the old one-candidate qualifier with a fabricated three-phase
      summary or sliced source/delivery history.
- [ ] Require initial confirmation before the capacity limit, completed decrease
      before restoration, a new successful measurement starting after the
      restoration upper clock bound, revision-3 application and confirmed trial.
      Preserve all failed attempts, cleanup/settlement and 10/20/40/60-second fresh
      healthy holds; classify the complete terminal suffix.
- [x] Collect an explicit diagnostic native run with all three recordings before
      final qualification; diagnostic collection must never report a passing verdict.
- [x] Align real candidate collection with fresh source reports, preserving the
      existing two-second freshness limits, then rerun with the campaign-aware relay.
- [ ] Qualify the full native experiment with all archive/live frames, phase audio
      anchors, changing score, continued local recording and both final outputs.
      Preserve the 3,072 cadence / 512 delivery row and 16/32 MiB evidence limits;
      stop with explicit failure if exhausted rather than dropping history.
- [x] Reproduce missing-reference damage offline with retained compressed input
      and decoder diagnostics; compare identities and pixels at original PTS.
- [x] Reproduce the silent damage through the actual SRT relay and compare measured
      retransmission recovery at400ms and1000ms. The1000ms controlled case matches
      all captured video frames; complete native A/V and delivery remain unqualified.
- [x] Permit exact1000ms only on the explicit owned diagnostic retry route,
      preserving400ms and1500ms delivery limits; specification/quality reviews pass.
- [ ] Rerun the full native cycle at1000ms and qualify complete A/V, timing and
      all three recordings before selecting production recovery behavior.
- [ ] Resolve the observed live-frame damage following late packet retransmission.
      Verify actual SRT/relay boundary capture and recovery timing before choosing
      a fix; decoder flags alone failed the controlled reproduction. Retain strict
      media checks and the complete failed evidence.
- [ ] Review specification and quality, retain failures, and update the delivery
      plan from actual evidence before production enablement or hardware claims.

Implementation context and results belong in the
[session log](../../session-logs/2026-09-25-owned-measurement-app.md).
