# Native transport statistics implementation plan

> **For agentic workers:** Use the existing bounded independent-review workflow.
> Parent owns implementation and all Swift/media execution in the validation worktree.

**Goal:** Expose fresh, attempt-scoped SRT counter and sender-pressure evidence for
capacity qualification while preserving reliable independent local recording.

**Architecture:** Timestamp successful native SRT statistics collection on the socket
actor, never at a later cached read. Copy a validated immutable scalar descriptor
through the SRT adapter and existing publishing health loop. Preserve sampling time,
reject stale/contradictory/counter-reset evidence, and retain historical terminal data
without making a capacity or delivery claim. No capture callback work is added.

**Tech stack:** Pinned libsrt 1.5.4 / HaishinKit source subset, Swift Media/Streaming,
existing Mac dual-output qualification fixture and unsigned iPhone/Watch build.

## Design and scope

The old RTT/drop/sent-byte tuple is unused by app policy. Keep it for compatibility;
add `PublishingTransportStatistics` for an exact socket sample. Native generation
identifies the single-use publisher; the enclosing publishing session owns the
attempt. Fields are uptime `sampledAt`, socket `elapsedMilliseconds`, cumulative
sent/retransmitted bytes and dropped packets, RTT, estimated bandwidth, sender
buffer bytes/duration and available sender bytes. Names explicitly describe SRT
transport statistics, not video bitrate, available capacity or viewer receipt.

Three approaches considered: treating the bandwidth estimate as usable capacity
would permit unjustified increases; timing cached reads would disguise stale data;
timestamping actual successful collection preserves provenance and is selected.
The SRT sample is unavailable before collection and after stop/failure. The SDK
keeps cached read semantics and changes no statistics frequency or send behavior.

`PublishingTransportStatistics` construction rejects invalid/nonfinite/negative
fields and retransmitted bytes larger than total sent bytes. A session tracker
keeps a bounded latest historical sample, accepts monotonic timestamps/counters,
ignores exact duplicates, and permanently quarantines contradictions/resets within
one publishing attempt. Missing readings do not erase historical evidence. Freshness
is calculated from the original sampling uptime with a bounded maximum age;
closure explicitly makes evidence historical, never fresh. No capacity value is
invented from successful send rate, estimated bandwidth or an empty buffer.

## Task 1: Scalar model and tracking

Files: `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/PublishingTransportStatistics.swift`
and matching tests; `PublishingSession.swift` and publishing lifecycle tests.

- [x] Write failing tests for descriptor validation, monotonic samples, duplicates,
      stale reads, counter/time/generation resets, contradictory equal timestamps,
      close/freeze and independent sessions. Example:
    ```swift
    var tracker = PublishingTransportStatisticsTracker()
    tracker.observe(sample)
    XCTAssertEqual(tracker.snapshot.latest, sample)
    XCTAssertNil(tracker.snapshot.freshSample(at: sample.sampledAt + 3))
    tracker.close()
    XCTAssertNil(tracker.snapshot.freshSample(at: sample.sampledAt))
    ```
- [x] Implement immutable descriptor, checked tracker and freshness (default 2s,
      finite nonnegative uptime; no buffering history, no derived capacity).
- [x] Add optional `MediaPublisher.transportStatistics()` defaulting to nil. Read it
      in the existing health monitor, with cancellation/state guards. Close tracker
      synchronously at stop admission; late reads cannot revive evidence. Expose its
      snapshot through `PublishingSessionSnapshot`.
- [x] Test stop while read is suspended, nil preservation, defaults and new-session
      isolation; run all Media tests with Xcode 26.2.

## Task 2: Native collection and adapter

Files: SDK `SRTPerformanceData.swift`, `SRTSocket.swift`, maintained patch/README;
Streaming `SRTPublisher.swift`, `SRTMediaPublisher.swift` and adapter tests.

- [x] Timestamp successful `srt_bstats` collection at entry with system uptime; expose nil
      before collection, and clear availability on failed collection/stop. Test cached
      reads retain timestamp, successful replacement advances it and failure clears it.
- [x] Construct the descriptor only for healthy current generation; recheck state
      after awaits. Add injectable statistics operation to SRTMediaPublisher; tests
      cover before start, healthy forwarding, stop race, unhealthy and cancelled reads.
- [x] Regenerate maintained patch against verified upstream baseline. Verify all
      original upstream hashes and exact reverse/forward patch round trip.
- [x] Run full SDK and Streaming suites and combined unsigned iPhone/Watch Release.

## Task 3: Real socket evidence

Files: `tools/media-sdk-probe/Sources/DualOutputSmoke/DualOutputSmoke.swift`,
`scripts/test-dual-output.mjs`, documentation and qualification tests as needed.

- [x] Extend the owned real native fixture to retain bounded sampled statistics;
      require advancing counters/timestamps for normal scenarios and unavailable adapter
      readings after joined stop. Keep source clock, A/V, frame, archive, bitrate-change,
      absent/stalled receiver and cleanup gates unchanged.
- [x] Run the existing five-scenario dual-output test, independently check exact
      exported counters and unchanged media outcomes. Review the final source.
- [x] Document evidence and remaining capacity/overhead, worker/thermal pressure,
      source-profile transitions and policy-window alignment. Commit only verified work.

Commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:
`swift test --package-path ios/Packages/ScorebugMedia`,
`swift test --package-path ios/Packages/ScorebugStreaming`,
`swift test --package-path vendor/HaishinKit`,
`python3 vendor/HaishinKit/verify-scorebug-patch.py`,
`pnpm test:dual-output`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

## Verified result

All tasks are complete. Full suites pass: Media 184 (129 XCTest + 55 Swift
Testing), Streaming 44, SDK 127, Film model 123 and tooling 661. The unsigned
combined iPhone/Watch Release build and all 162 original SDK hashes / exact patch
round trip pass. Failing executable regressions preceded implementation: scalar
validation/tracking (5 tests, 42 failures), session integration (7 tests, 12 failures),
adapter forwarding (19 tests, 6 failures) and SDK collection (2 tests, 6 failures).
Independent review found a post-read health race; its gated regression failed once
before the fix. Both adapter layers now revalidate health and lifecycle after the
read. Follow-up review approved with no blockers. SDK tests explicitly establish
that sampling occurs before the native call and cannot revive after closure.

Final real-socket run `artifacts/qa/dual-output-buQa9V` passes all five scenarios:
record-only, normal, normal with 123.25-second source offset, stalled receiver and
absent receiver. Every archive has all 420 frames. Both normal live outputs also
have all 420 frames at 30 fps and each yields 13 advancing timestamped native
statistics samples, with unavailable statistics after joined stop. Actual live
packet rates fall from 5.992 to 1.982 Mbps and 6.068 to 2.016 Mbps. Archive A/V
marker error is at most 0.021 ms; live at most 65.364 ms. Peak RSS is below 96 MiB.
The command exited zero after owned-child cleanup. First run `dual-output-RUPobA`
also passed before the reviewed health-race fix; final evidence uses `buQa9V`.

Source/evidence hashes and terminal outcomes are retained in
`artifacts/qa/transport-statistics-final-verification.json`.

This establishes timestamped transport counters and instantaneous sender-buffer
observations, not usable video capacity or time-weighted transport pressure. Next
capacity work needs audio/mux/control/retransmission accounting and bidirectional
rate/delay/loss qualification; instantaneous bandwidth estimates cannot substitute
for sustained decoded-frame evidence. Thermal/worker pressure, applied-profile
source boundaries, monotonic policy alignment, physical camera/watch networking
and other-host GPU/cloud qualification remain outstanding. Automatic adaptation
remains disabled.
