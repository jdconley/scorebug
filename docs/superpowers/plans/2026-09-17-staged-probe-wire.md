# Staged Probe Wire Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded relay task, then spec and quality review. Parent owns verification and integration.

**Goal:** Establish a backwards-compatible wire foundation for repeated probes without enabling additional native traffic or quality upgrades.

**Architecture:** Preserve `SBUGPRB1` exactly. Add an explicit `SBUGPRB2` encoder and relay parser with a monotonically increasing publication-owned stage. Each stage retains its UUID, generation, immutable rate, message sequence and seven TS packet ordinals. The existing native probe continues emitting v1; the authenticated application/status path continues rejecting unqualified v2 evidence.

**Tech Stack:** Swift/Testing, patched MediaMTX Go reader and race tests, existing Apple build verification.

## Wire contract

Each 1316-byte message contains seven 188-byte null TS packets. Bytes 0–48 retain the v1 layout, except the magic is `SBUGPRB2`. Bytes 49–52 contain the stage as an unsigned big-endian UInt32; bytes 53–187 are `0xff`. The stage must be in 1...32. UUID must be nonzero, generation positive, rate 1...2,000,000, ordinal 0...6. The encoder's separate throwing `encodeStage(id:generation:stage:sequence:bitRate:)` rejects malformed parameters and a sequence whose message would exceed the 16 MiB cap. The legacy encoder and live caller remain unchanged.

The relay accepts the first observed stage even if it is greater than one (earlier attempts may have sent no bytes). A replacement stage must be strictly greater, have a different UUID from the current stage, retain publishing generation, and start at sequence zero/ordinal zero after a complete prior message. Same-stage UUID/rate changes, stage regressions, mixed versions, interrupted messages and structural faults permanently invalidate connection evidence. Stage plus UUID is identity: no unbounded retired-UUID set is needed, and UUID alone must not identify a future stage. Higher stages may change rate. The stage limit bounds work even when unseen attempts are skipped.

Stage replacement resets only current-stage counters and first/last delivery times. Receiver clock, origin, structural invalidity and cumulative accepted complete-message payload never reset. The 16 MiB payload limit spans all stages. Receiver snapshots use convention `mpegts-null-probe-v2`, add `stage` and decimal-string `totalDeliveredPayloadBytes`, and retain existing fields for the current stage. V1 snapshots omit the new fields and preserve existing accounting.

This adds no automatic scheduler, replacement API, admission policy or production configuration. Subsequent work must carry exact stage identity through authenticated status and native ownership, join prior send/wake owners before replacement, enforce cumulative sender byte/time/stage budgets, cancel on pressure/reset/route/stop, and measure fresh candidate encoding cost. Neither current throughput nor delivered padding alone is spare capacity.

## Tasks and verification

- [x] Add Swift tests before implementation: independent fixed v2 byte vector for all seven packets, immutable legacy vector, maximum legal stage/rate/sequence, and zero/overflow/malformed parameters. Run `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path vendor/HaishinKit --filter SRTProbeStageMessageTests` and retain the expected missing-API failure.
- [x] Implement the separate v2 encoder. Keep the live probe's `encode(...)` call unchanged; run the focused and complete SDK tests.
- [x] Add Go tests before parser changes in a fresh pinned upstream checkout. Test staged byte-for-byte pass-through under fragmented reads, skipped unseen stages, per-stage counters/timestamps, cross-stage byte cap, same/older stage substitutions, partial-message transition, generation/version changes, malformed bounds and sticky faults. Retain red and green logs; regenerate the cumulative patch and update its SHA-256.
- [x] Run patched Go reader tests and race tests; freshly reapply the patch and verify pinned original-file hashes. Do not edit any existing frozen QA artifact or source checkout.
- [x] Review spec compliance then code quality; resolve actual findings and rerun affected checks.
- [x] Run SDK tests, relevant repository packaging tests, ARM64 simulator build and unsigned combined phone/Watch Release sequentially. Save a new verification manifest with source/evidence hashes and precise limitations; update the main plan and commit.

## Qualification boundary

Passing this slice proves wire generation and receiver accounting, including pass-through of mixed media bytes. It does not prove an actual repeated native SRT run, measured capacity, safe encoder upgrades, physical phones/watches or remote deployment. Existing frozen media qualifications remain evidence for their original source revisions only.

## Verified checkpoint

The new encoder passed its missing-API red check, then 17 focused SDK tests and
all 204 SDK tests. Go tests first demonstrated unrecognized v2 traffic, and a
second regression caught omission of the stage field from malformed v2 snapshots.
The final three relay packages pass normal and race suites. A fresh extraction of
the pinned archive reproduces all 17 patched files byte for byte; the SDK patch
also round-trips all 162 original hashes.

The existing authenticated status path passes 61 control-plane tests; 23 shared
receiver-probe tests pass. ARM64 simulator build-for-testing and unsigned combined
iPhone/Watch Release both pass. No live repeated-probe experiment or Docker image
build was performed in this slice. Media integrity, capacity and recovery remain
unqualified for v2; the current native sender still emits v1.

Evidence is retained under `artifacts/qa/staged-probe-relay-20260917/` and the new
`artifacts/qa/staged-probe-wire-*` prefix. The final verification manifest records
source/evidence hashes and checks that the prior frozen deadline evidence remains
unchanged. Next implement authenticated v2 stage matching and stale-stage rejection,
then joined native replacement with cumulative budgets before actual media trials.

Independent spec and quality reviews are approved, with no actionable findings.
