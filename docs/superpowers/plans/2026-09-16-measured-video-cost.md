# Measured Native Video Cost Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline under the active autonomous goal.

**Goal:** Measure actual H.264 payload cost with native encoder/source identity on the real publishing path.

**Architecture:** A bounded scalar join in ScorebugStreaming consumes both native callbacks; SRTPublisher owns it per attempt and closes it after native teardown. The existing reduced-format fixture exports interval history and the harness independently reconciles it with demuxed packets.

**Tech Stack:** Swift/CoreMedia/XCTest, existing native simulator fixture, Node/FFprobe qualification.

- [ ] Add `PublishingVideoCostTests.swift`: failing coverage for exact byte math,
  rational timestamp equivalence, either callback order, two-second boundaries,
  mixed configuration/session resets, duplicates/missing joins, gaps, low frame
  rates, slow completions, bounded retention, clock regressions, close and freshness.
- [ ] Implement `PublishingVideoCost.swift` with at most 64 pending joins, eight
  retained intervals, sticky invalidity and no media ownership. Exclude anchor
  bytes and incomplete windows; preserve actual rates rather than configured rates.
- [ ] Wire both callbacks in `SRTPublisher.swift` and close after joined stop.
  Add optional cost-observer forwarding in `SRTMediaPublisher.swift`.
- [ ] Extend `NativePublishingFormatFixture.swift` and capture factory forwarding
  to persist actual intervals with format evidence at joined stop. Test serialization.
- [ ] Add independent Node cost qualification against FFprobe packet sizes/PTS and
  damaged-evidence regressions; integrate with the existing reduced live fixture.
- [ ] Run streaming/model/tools tests and both Apple builds; review and fix findings.
- [ ] Run actual fixed540p pressure fixture, independently verify media and cost,
  preserve source/evidence hashes, update main plan and commit.

This advances measured cost, not full candidate admission. Repeated/staged probing,
fresh candidate encoding cost, overhead reserves and admission still follow; do not
enable automatic increases from historical/current video payload alone.
