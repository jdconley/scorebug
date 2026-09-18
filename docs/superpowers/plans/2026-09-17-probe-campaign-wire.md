# Campaign-aware probe wire implementation plan

> **For agentic workers:** Use independent bounded sender, relay and native-consumer agents with disjoint file ownership; parent owns protocol/API/adapters and integration. Parent serializes all Swift, Go, Docker and native jobs. Use test-first implementation, spec review then quality review. Work only in the local-validation worktree.

**Goal:** Carry explicit repeated-campaign identity through sender bytes, receiver accounting and authenticated native evidence without admitting stale campaign traffic.

**Architecture:** Add opt-in v3 from the first probe of a publication. V1/v2 remain unchanged. V3 adds a UInt32 campaign ordinal to the existing staged header; restart increments it with checked overflow, replacement preserves it. Receiver and native tracker order (campaign, stage), preserving publication clock and total bytes while resetting campaign coverage and budget. This does not activate repeated scheduling or production upgrades.

**Tech stack:** Swift SRT sender, Go MediaMTX receiver, TypeScript authenticated API, Swift shared native consumer.

## Shared contract

- Marker `SBUGPRB3`; bytes 0..48 follow v2 except marker. Big-endian stage 1...32 at bytes 49..52, campaign UInt32 1...4294967295 at 53..56, bytes 57..187 remain FF. Seven 188-byte null packets/message; identity, generation, sequence, rate and ordinal rules unchanged. Rate 1...12000000.
- `beginBandwidthProbe(..., staged: true, repeatable: true)` chooses v3 campaign 1. Repeatable without staged rejects. Defaults retain v1/v2. SDK snapshots carry optional `campaign: UInt32`. Same-campaign replacement preserves it; restart requires it and increments with overflow rejection. No downgrade or restart of legacy v2. Old authority remains revoked.
- Receiver convention `mpegts-null-probe-v3` adds decimal-string `campaign` and `campaignDeliveredPayloadBytes`; `totalDeliveredPayloadBytes` now counts complete payload for the entire publication. Stage counters retain existing meaning. V1/v2 omit campaign fields and preserve their connection cap.
- Each v3 campaign has the existing 16 MiB complete/pending payload cap across stages. Publication total is a UInt64 canonical string, bounded by campaign ordinal times 16 MiB (maximum 72057594021150720). All counts stay exact; reserve a whole message before its first packet. Campaign counter <= publication counter, current-stage bytes <= campaign counter, all complete payload counters divisible by 1316.
- First observed campaign/stage may be any valid positive value. Subsequent campaign may increase, or stage may increase within the same campaign. Transition requires changed UUID, same publishing generation, sequence/ordinal zero and a complete previous message. Campaign/stage gaps allowed; old campaign/stage, same tuple identity/rate change, mixed wire versions, incomplete transitions or malformed fields permanently invalidate proof while preserving media and reader errors.
- New campaign resets campaign and stage counters. New stage resets stage only. Neither changes publication total or receiver elapsed clock. Retain scalar state and one partial packet only.
- Swift/API schema require exact fields/types/canonical strings, reject campaign fields on legacy conventions and explicit nulls. Swift expected identity adds optional `campaign: UInt32`; freshness matches it exactly. No Double/Int narrowing for counters or campaign on watchOS arm64_32.
- Tracker orders campaigns/stages lexicographically, discards capacity coverage on every boundary but retains publication clock/total history. Same-campaign publication delta must equal campaign delta. Cross-campaign publication total must include prior observed total plus any old pending reservation plus the full new campaign counter. Old/replayed/mixed identity quarantines. No healthy interval spans a boundary.

## Tasks

- [x] Sender: failing golden-layout/bounds/legacy tests, v3 encoding and owner propagation; begin/restart/replace identity and overflow tests. Update maintained HaishinKit patch and verify upstream round trip.
- [x] Relay: prepare a new source work directory from pinned source (preserve all prior evidence), failing v3 byte/accounting/ordering/fragmentation/pass-through/legacy tests; implement observer/API fields, maintain patch/upstream manifest, run focused and race Go tests. Build a new image tag only after review.
- [x] Shared native consumer: failing v3 Codable/validation/freshness/ordering/budget/coverage/replay tests; implement fields and tracker contract while preserving v1/v2. Run Core regressions.
- [x] Parent API: shared v3 golden fixture and protocol union; failing API envelope tests for counters/ordinals/nulls/legacy rejection; parse and preserve the complete v3 identity through authenticated relay metadata. Run API regressions and type checks.
- [x] Parent adapters: expose repeatable begin and carry campaign in native snapshots; validate campaign equality on renew/replace and exact +1 on restart. Update restart fixtures to opt in. Add negative downgrade/overflow/campaign tests, run streaming regressions.
- [x] Independent spec then quality review; resolve all findings. Verify actual sender bytes against receiver parser, build fresh relay image and run real SRT repeated campaigns with media pass-through. Keep native scheduler and production adaptation disabled until fresh candidate/recovery scheduling and repeated ramp replay are implemented.
- [x] Preserve all raw results, verify frozen prior evidence, record exact source/test/image hashes, update findings and commit. Existing routes remain regression gates; a wire-only pass is not complete adaptive-stream qualification.

## Verification checkpoint

The intended RED failures are retained for SDK legacy restart, receiver v3 parsing,
native decoding, API parsing, adapters and app observation. The source now passes:

- SDK: 289 tests, plus 162 upstream hash checks and exact maintained-patch round trip.
- Native receiver: 54 focused tests and all 438 Core tests; streaming adapters: all 153 tests.
- App model: all 397 tests, including full-width campaign observation propagation.
- Control plane: all 533 tests; protocol build and repository type checks pass.
- Go receiver and API race tests pass. The first broad command named a nonexistent
  protocol package and omitted generated assets; its setup failure is retained.
  The corrected command uses pinned generated assets and the relevant packages.
- The Go receiver consumes the actual 1316 bytes exported by Swift and checks the
  complete cross-language vector and decoded identity/counters.
- Independent spec review and subsequent quality review found no actionable issues.

Artifacts use `artifacts/qa/probe-campaign-wire-*`. Production selection and
repeated scheduling remain disabled. Fresh-image media integration passes as described below; native regression also passes as described below.

## Fresh-image SRT integration

`probe-campaign-wire-loopback-1af16bf6` passes against immutable image
`sha256:e69919c9834fb4dbf7468f56eb3d954f54879f8fb10654413c7667d95dea23d0`.
A bounded Go sender starts from the actual Swift golden message, sets the planned
campaign/stage/sequence/identity fields, and interleaves four stages across three
campaigns with a 12-second H.264/AAC MPEG-TS source. All 122 private publisher API
samples retain valid evidence; completed counters are exact and the receiver
clock never resets. Both sender and recorder joined with exit 0.

The reader joins after publication starts. Its 329 video frames match consecutive
source frames starting at index 30; its 554 AAC access units match consecutive
source packets starting at index 10. Both media streams fully decode. This is
finite pass-through qualification, not a whole-publication no-loss claim, a native
sender scheduling test, a rate-capacity claim, or repeated automatic ramp evidence.

Two harness failures remain preserved: the first recorder used an unsupported
FFmpeg SRT URL option; the second compared independently started AAC decoders'
PCM hashes, although all encoded AAC packets were identical. The final harness
uses the supported I/O timeout, checks live child health, compares encoded AAC
packet hashes and separately requires a complete successful decode. No product
source change was needed for these harness fixes.

Parent provenance verification reconstructs the relay from its pinned archive,
checks all 15 original hashes, and matches all 18 patched files to the tested
source exactly. Prior frozen image tags remain unchanged.

## Next native boundary

A wire-compatible restart is now available, but the current candidate fixture and
lifecycle export remain intentionally v2 and single-use. Before selecting v3 in
that route, add campaign to candidate binding comparisons, diagnostic copies and
independent evidence replay. Create a fresh measurement owner and revocable
candidate authority for each recovery attempt, join retired work before replacement,
and preserve publication/report clock high water across attempts. The native
scheduler must wait for independently proven recovery/cooldown before starting
another bounded campaign; receiver traffic alone cannot authorize an increase.
Then qualify at least two complete increase/reset/recovery cycles with independent
clean recording and decoded live-media evidence. Only after those checks should
production selection be considered. Physical phone/Watch and other proxy hosts
remain separate later gates.

## Native regression

Frozen-source `native-app-tttNJS` passes the existing iPhone 14/iOS 17.5 measured
recovery route with native scoring and archive export. It uses the unchanged v2
relay image, so this is compatibility regression coverage. The owned decoder
pause is 1,984.5 ms, followed by minimum-profile reset and 10.00023 seconds of
independently verified healthy recovery. The 1080p archive has 3,621 consecutive
frames at 30 fps and all 60 expected audio markers. The live recording has 3,242
consecutive frames at approximately 30 fps and all 54 expected markers in its
qualified interval. Both MP4s fully decode; neither contains source loss within
its recorded range. Minimum observed free space was 6,483,681,280 bytes.

The live recording starts audio 382 ms before video, within the current permitted
lead bound; this pass does not resolve the earlier intermittent startup audio
alignment issue. Production upgrades, repeated native ramps and network-loss
recovery remain explicitly unqualified. No physical device or remote proxy was
used in this checkpoint.


Unsigned combined iPhone/Watch Release builds successfully under licensed Xcode
26.2, including the Watch arm64_32 compiler target. The final raw/source inventory
is `artifacts/qa/probe-campaign-wire-final-verification.json`.


Final verification rehashed all 11,836 frozen prior evidence files without changes.
All 1,810 unit/model/API tests above pass, along with Go race checks, native
regression, fresh-image SRT integration, maintained-patch verification and the
combined Release build. This completes the campaign wire checkpoint; the overall
portable streaming/Watch goal and next native boundary remain open.
