# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. Goal remains incomplete. The reviewed app-loopback test-control bridge passes its physical probe after the user confirmed the runner permission is already enabled. Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. No PR/push requested. Sign Conley Chaos LLC B222J9J7B8.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos; [latest session](2026-09-26-evening-device-resume.md) owns commands/results. User resumed work; direct runner requests still find LAN denial despite the enabled switch. [Loopback implementation plan](../superpowers/plans/2026-09-26-physical-recovery-loopback.md) is the next path. Preserve Downloads originals. No runtime downloads, unrelated simulator/recording deletion, or heavy builds/media analysis during capture.

## Latest experiment

Source `dcdc8ca`: explicit `--publish-pacing relative` added only to lab/recovery720 tooling; defaults unchanged. Reviews pass,41 focused regressions and99 API tests pass. Run `ordinary-native-ezaWU8` / lab `device-lab-tmXAPL` failed the unconstrained720 climb:360→240→360, local sender buffer411ms versus350ms threshold; no720 ACK, no bandwidth constraint applied. Full captured-span media passes (archive8887 consecutive frames; both live8612; waveform/overlay checks pass), but no ramp/recovery qualification. All jobs and owned resources joined/cleaned.29-file failed-ramp manifest retained. Keep pacing experimental; do not repeat unchanged or claim a measured native pacing ceiling. See [session](2026-09-26-measured-relative-pacing.md).

## Latest verified checkpoint

Implementation `90036c4`, simulator build correction `78c4fdd`: separate native iPhone14 simulator scorer while the physical filming phone records/streams. Reviewed source; 55 focused regressions; signed phone and arm64 ad-hoc simulator builds pass. Exact native leaves pass once each, zero skips. The scorer takes over, awards/undoes/awards; filming phone observes changes while recording/publishing. Archive continues after stream stop and exports the actual new UUID.

Run `separate-native-scorer-kfuQEO`, lab `device-lab-uZky2H`: durable six-score/two-media command checks pass, no scorer recordings, all source/binary inputs unchanged. Archive 4546 frames/151.54s; both outputs4243 frames with the expected overlay sequence. Precise full A/V decodes and encoded timestamp continuity pass. Scene is almost black: no fresh-motion or perceptual A/V sync qualification. UI observed startup240p then360p; no adaptive collapse in this run. `assessment.json` preserves these limits. Both native jobs, lab, and owned simulator have joined/cleaned up. No capture/build/media-analysis job remains active.

## Pending device prerequisites and next actions

Latest resume: current en0 is10.0.0.122, not192.168.1.130. Probe `physical-recovery-AeMjLt` built and executed on the unlocked phone, but again reports explicit localNetworkDenied; no capture, all17 inputs unchanged, lab shutdown clean. The user confirms the runner switch is already enabled; installed bundle identity matches. Apple DTS recommends app-owned loopback forwarding for similar XCTest failures. The bridge is implemented and reviewed; physical probe physical-recovery-ymge6q passes actual API/controller forwarding and joined shutdown, with all25 inputs unchanged. Watch query reports connection reset by peer, without any lock-state result. Refresh host configuration before reusing artifact-only paired launchers.

1. User confirms the rear camera now points at a lit scene with movement. With that scene, the same reviewed lane can verify visible motion; use only the new export UUID for collection.
2. Direct physical recovery runner LAN access remains denied despite its enabled switch. The app itself connects. Follow the [reviewed bridge design](../superpowers/plans/2026-09-26-physical-recovery-loopback.md): explicit DEBUG-only authenticated loopback, fixed private upstreams, idle guard before app relaunch, bounded forwarding/shutdown, unchanged mutation timing gates. The opt-in probe passes. Two physical attempts reach recording/streaming/export but fail the initial source-acquisition test budget before impairment. Execute the [explicit physical startup contract](../superpowers/plans/2026-09-26-physical-startup-acquisition.md), then rerun recovery720 through --runner-transport app-loopback --bridge-port 49173. Do not reset privacy, delete Scorebug, disable firewall or repeat Settings navigation. [Apple-source research](../research/2026-09-26-xctest-local-network.md) explains the alternative and its limits.
3. Combined physical Watch scoring now reaches the unlocked Watch runner. Fresh current signed phone/Watch builds pass. Run `physical-paired-live-KdfdC1` failed before its test body with UI automation initialization timeout; no phone capture started, all jobs joined and14 input hashes unchanged. User was asked whether a new prompt is visible (approve if shown, otherwise report none). Do not repeat unchanged or infer a Watch lock. See [latest Watch session](2026-09-26-watch-approved-retry.md). Separate Ultra2 scoring baseline passes; combined acceptance does not.

## Remaining delivery gaps

- Two ordinary360p recovery runs pass all media checks. 720p forced-collapse runs pass native/transport/geometry but lose live video/audio; clean archive passes. Keep failed evidence intact; no 720p recovery claim.
- First-descent audit shows pressure decision after initial overflow and ~456ms simulator profile application. Offline comparison places most delay between first new submission and completion (~431ms simulator versus27–30ms Mac hardware); not exact drain timing or physical-phone proof. See [breakdown](2026-09-26-replacement-latency-breakdown.md).
- Do not repeat unchanged simulator720 captures or restore rejected bitrate-first/source-pacing/maxbw experiments without new causal evidence.
- Wider profiles, sustained hardware, route changes/outages, second physical scorer/Watch, remote proxy hosts and real YouTube remain open.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed iOS26.2 runtime; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; current LAN10.0.0.122 (recheck interface before launch); Docker `scorebug/ingest:campaign-probe-v3`.

Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E`, watchOS26.6.

Separate native scorer launcher: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-separate-native-scorer.mjs --device 00008140-001474110C13001C --host 10.0.0.122`. It requires clean committed code, builds both targets before capture, creates only an owned simulator, and separately reports workflow versus media qualification.
