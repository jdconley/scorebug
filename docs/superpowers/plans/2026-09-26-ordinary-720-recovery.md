# Ordinary native 720p recovery implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development, with independent specification and quality review before committing each source slice. Root owns live execution and final media verification.

**Goal:** Qualify ordinary native240→confirmed360→confirmed720 streaming, constrained fallback to240, and fresh confirmed360→720 recovery while clean recording, native scoring, proxy overlay, RTMP recording and optional overlay recording remain active.

**Architecture:** Add720 to the normal production measured ladder. A new explicit XCTest/Node lane controls the existing real750kbps upload bottleneck only after native phase confirmation. Native applied-format receipts and accepted decoded windows join to pre-scale worker geometry using the authenticated derived stream key. Existing360qualification remains available and cannot masquerade as720qualification.

**Tech Stack:** Swift/CoreMedia/VideoToolbox, existing production adaptation and guarded encoder replacement, XCTest, NodeUDP/controller/checkers, FFmpeg/ffprobe, three-output frame/audio/overlay verification.

## Current prerequisites and limits

Native720recipe43f2229 and decodedgeometry038a4ec are reviewed and committed. The [identity correlation dependency](2026-09-26-pipeline-geometry-correlation.md) is reviewed and committed as `026189c`. Source integration is reviewed and committed as `8495c79`; the production ladder is now240/360/720. Actual native recovery and media qualification remain pending. Two consecutive ordinary360recovery runs pass native/actualtransport/three-output media gates; earlier rollback remains unexplained.

This is a higher-rung checkpoint, not full-match/hardware/network-route/remote-host completion.540p,1080p and original-quality4K support/qualification remain tracked by the main delivery plan. Physical paired acceptance takes priority when the Watch is ready; no heavy jobs during capture.

## 1. Actual native format witness and production ladder

Files: `ios/Sources/Scorebug/Capture/PublishingQualitySession.swift`, `PublishingQualityDriver.swift`, their `ios/FilmModelTests/` tests.

- [x] Test then append the existing720recipe to productionProfiles:

```swift
.init(id: "720p30", width: 1280, height: 720,
      minimumBitrate: 3_000_000, maximumBitrate: 3_000_000)
```

Keep240startup,360entry, measured-candidate ownership, strict1500timing, guarded writes, recovery budgets, current8Mbpsmedia/12Mbpsprobe caps and archive configuration unchanged. No app environment selector to choose an easier ladder. Tests prove the exact ordered ladder and next-profile selection on the normal production path.

- [x] Extend DEBUG `appliedTransition` only after the existing validated profile+bitrate receipt and Core ACK. Preserve causal diagnostics. For profile changes, record actual format width/height, generation, old/new encoder UUIDs, exact old/new sourcePTS and actual bitrate-receipt encoder/generation/last-submittedPTS. Source these from receipts, never requested profile dimensions.

Use decimal integers and `value/timescale` for CMTime strings; retain epoch0/numeric validation and compare rationals exactly in independent checks. Existing profileNativeAt/nativeAt/ackAt associate the receipt order. Test absent witness before ACK, failed/stale/cancelled applications, distinct old/new encoder, actual format preservation, and agreement between profile and bitrate receipts.

- [x] Recheck4096byte diagnostics with new witness plus accepted decoded identity/endpoints, pending/application/trial and populated pressure cause. Preserve ownership and causal fields. Fix demonstrated budget problems explicitly; no silent old diagnostic or threshold relaxation.

## 2. Explicit native/Node recovery720 lane

Files: `ios/AppUITests/PhysicalStreamingTests.swift`, `scripts/test-ordinary-native-app.mjs`, `scripts/test/ordinary-native-app.test.mjs`, existing host-compiled recovery guard tests, `scripts/device-lab.mjs` and option tests.

- [x] Add `--lane recovery720`, choosing a dedicated `testOrdinarySimulatorRecover720ScoreStopAndExport`. It uses the same private recovery controller and ordinary file-source app launch. The test selection belongs only to XCTest; app receives no profile/timing/candidate fixture selector. Old phone/paired/recovery lanes remain unchanged.
- [x] Parameterize recoveryIncrease with the exact expected profile/bitrate, preserving150second ACK and30second probation→confirmation gates. The new sequence is:

```text
initial-minimum
initial-360-increase-acknowledged / initial-360-probation / initial-360-confirmed
initial-720-increase-acknowledged / initial-720-probation / initial-720-confirmed
constrain (existing750000bits/s)
fallback-acknowledged (240p)
restore
recovery-360-increase-acknowledged / recovery-360-probation / recovery-360-confirmed
recovery-720-increase-acknowledged / recovery-720-probation / recovery-720-confirmed
```

- [x] Require each of the four climbs to advance exactly one applied revision from its preceding confirmed/baseline state. Require observed probation, stable trial owner/revision through confirmation, advancing accepted source, same publishing attempt and same source scope. No hidden applied rollback may be counted as a successful climb. Candidate retries that never apply are allowed. The constrained descent may legitimately pass through360 before240; final minimum must have a newer revision than confirmed720, without assuming a direct reset. Retain observed intermediate ACKs/causes, but do not claim an exhaustive descending chain from2second samples.
- [x] Constrain only after confirmed720; require minimum ACK strictly after constrain response. Restore only after that minimum; require recovered360ACK after restoration, recovered720after confirmed recovered360. Keep60second fallback,2second sampling,270sample bound and540second recording deadline with existing cleanup reservation. Four maximum climb gates exceed the global deadline: the run must finish sooner or fail truthfully.
- [x] New native attachment uses `formatVersion:2, contract:"recovery720"`; old recovery keeps its v1schema/names. Preserve failures through stop/archive-continuation/export. Keep native HOME scoring and existing live/clean-archive/output checks.
- [x] Add an explicit API-only lab geometry option for this lane, validated before starting resources. Set both `SCOREBUG_TEST_WORKER_TERMINAL=1` and `SCOREBUG_TEST_WORKER_DECODED_GEOMETRY=1` only for that option; clear inherited flags for all other lanes. No general labCLI/profile/timing change. Keep owned process/UDP/controller cleanup and private environments.

## 3. Independent closed-contract qualification

Files: `scripts/ordinary-recovery-evidence.mjs`, its tests; new `scripts/ordinary-geometry-evidence.mjs` and tests.

- [x] Preserve the existing360entrypoint and semantics. Add an explicit `qualifyOrdinary720RecoveryNativeEvidence` entrypoint using a closed720contract; shared internals may avoid duplication, but never infer the contract from submitted milestones or accept a downgraded format. Require ten selected native phase observations, four increase ACKs and ten finite gates in the order above.
- [x] Independently replay native/host clock brackets, current owner and consecutive climb revisions (newer fallback revision), probation→confirmation, exact profile/bitrate, freshness and source advancement. Require v2/recovery720. Compare ACK-bound native format/bitrate receipt encoder/generation, exact rational PTS boundaries,1280×720 for720 and receipt→ACK ordering. Reject profile labels without actual format evidence. Initial startup has no appliedTransition profile-change receipt; require its actual240decoded geometry instead.
- [x] Retain unchanged transport qualification: three actual baseline/constrained/restored phases, exact750kbps controller receipts, real offered traffic/token denial, complete ledgers and joined conserved queues. Native success is separate from transport and media success.
- [x] Geometry checker assembles only bounded numeric `worker_decoded_geometry` rows and matching terminal metadata under one authenticated derived pipelineReadKey, expected game/generation and one terminal scope. Require all run indexes exactly once, consistent headers, clean geometry EOF/validity, contiguous ordinals, strictly increasing safe integer PTS, conserved counts and agreement with decoder lifetime metadata. Retain actual encoder exit; absent exit/drain completion cannot qualify. Pipelineordinal is not supervisor attempt.
- [x] For each accepted native window, require the same key and signed exact decoder endpoints/frame count. The first and last included decoded endpoints must lie in the same contiguous constant-dimension run at the expected profile resolution, respecting the previous-exclusive anchor; reject a720→240→720sandwich even when both endpoint dimensions match. Native metadata supplies accepted window counts; run summaries do not reconstruct every interiorPTS or prove fresh-fps/latency. Qualify those separately from recorded media. Return geometryQualified only, not media/health/capacity qualified.
- [x] Negative fixtures cover missing720,360substitution, swapped trials, reused owner/revision, hidden applied rollback during a climb, observed increase during the constrained descent, missing probation, early fallback/recovery, contract downgrade, expired gates, invalid rational receipt, mismatched encoders, missing/duplicate/wrongkey terminal, partial geometry, wrong dimensions/counts/boundaries,720→240→720sandwich, stale source and oversized diagnostics. Keep all existing360mutation tests.

## 4. Source verification, reviews and actual run

- [x] Run focused Swift/app, host guard, Node runner/lab/evidence tests; build DebugUI/Release with installed Xcode. Preserve commands/logs/counts/hashes and independent spec→quality approvals before commit.
- [ ] Execute on an owned iPhone14simulator with the verified600second natural-match fixture:

```sh
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane recovery720
```

- [ ] Join every capture/lab process, collect actual native export and attachments, then independently replay native/transport/geometry evidence. No source changes or heavy analysis during capture. Retain any failure and use its causal witness before another run.
- [ ] Fully decode clean archive, mock RTMP MP4 and proxy overlay MP4. Verify actual frame IDs/fresh-fps>=24(target30), audio continuity/alignment, native score overlay change, clean archive and independent archive continuation. Extend the existing source-window media mapper to allten accepted windows; don't claim exact network-boundary latency from that mapping.
- [ ] Update delivery status and a separate session log with actual results/limits. A component pass,720label,1080outputcanvas or configured750kbps alone cannot satisfy this vertical gate.
