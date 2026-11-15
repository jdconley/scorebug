# Measured Native Video Cost Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline under the active autonomous goal.

**Goal:** Measure actual H.264 payload cost with native encoder/source identity on the real publishing path.

**Architecture:** A bounded scalar join in ScorebugStreaming consumes both native callbacks; SRTPublisher owns it per attempt and closes it after native teardown. The existing reduced-format fixture exports interval history and the harness independently reconciles it with raw callback records.

**Tech Stack:** Swift/CoreMedia/XCTest, existing native simulator fixture, Node/FFprobe qualification.

- [x] Add `PublishingVideoCostTests.swift`: failing coverage for exact byte math,
      rational timestamp equivalence, either callback order, two-second boundaries,
      mixed configuration/session resets, duplicates/missing joins, gaps, low frame
      rates, slow completions, bounded retention, clock regressions, close and freshness.
- [x] Implement `PublishingVideoCost.swift` with at most 64 pending joins, eight
      retained intervals, sticky invalidity and no media ownership. Exclude anchor
      bytes and incomplete windows; preserve actual rates rather than configured rates.
- [x] Wire both callbacks in `SRTPublisher.swift` and close after joined stop.
      Add optional cost-observer forwarding in `SRTMediaPublisher.swift`.
- [x] Extend `NativePublishingFormatFixture.swift` and capture factory forwarding
      to persist actual intervals with format evidence at joined stop. Test serialization.
- [x] Add independent Node cost qualification against raw compressed callback byte sizes/PTS and
      damaged-evidence regressions; integrate with the existing reduced live fixture.
- [x] Run streaming/model/tools tests and both Apple builds; review and fix findings.
- [x] Run actual fixed540p pressure fixture, independently verify media and cost,
      preserve source/evidence hashes, update main plan and commit.

This advances measured cost, not full candidate admission. Repeated/staged probing,
fresh candidate encoding cost, overhead reserves and admission still follow; do not
enable automatic increases from historical/current video payload alone.

## Verification progress

All 78 streaming tests, 229 capture-model tests and 1,189 tooling tests pass.
ARM64 simulator build-for-testing and combined unsigned iPhone/Watch Release pass.
The review regressions reproduced stale exposure during pending replacement,
orphaned encoding callbacks, and omitted cost windows before their fixes.
The fixed-profile qualifier reconstructs the exact latest eight completed windows
and complete 1,024-frame raw retention; it does not qualify arbitrary transitions.

Runtime sources are frozen in `artifacts/qa/video-cost-runtime-source.json`.
Actual pressure trial `native-app-M4cCvu` and independent verification pass.
It preserves 6,388 archive frames and 6,012 consecutive retained live frames, all
expected audio markers and clean full decodes, with 30 fps minimum reported
receiver cadence. Eight native cost windows contain 7,045,658 H.264 payload bytes;
maximum measured payload cost is 3,527,347.258 bps. All 3,676 accepted probe
messages reach the receiver, probing withdraws under pressure, and media continues
for another 141.075 seconds. All owners join; 27 damaged evidence copies are
rejected. Final source/evidence hashes are in
`artifacts/qa/video-cost-final-verification.json`.

Downstream worker output is re-encoded,
so publisher byte cost is compared with separately retained actual native callbacks,
not assumed equal to destination packet sizes. Existing full media checks still apply.

A candidate admission implementation must additionally measure the current scene at
the proposed profile and account for its startup keyframe, audio, mux/network cost
and pressure margins. This meter's interval excludes its anchor frame by definition.
