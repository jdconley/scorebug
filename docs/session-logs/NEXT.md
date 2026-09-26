# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. Goal active. Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. No PR/push requested. Sign Conley Chaos LLC B222J9J7B8.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos; [latest session](2026-09-26-separate-native-scorer.md) owns commands/results. Preserve Downloads originals. No runtime downloads, unrelated simulator/recording deletion, or heavy builds/media analysis during capture.

## Latest verified checkpoint

Implementation `90036c4`, simulator build correction `78c4fdd`: separate native iPhone14 simulator scorer while the physical filming phone records/streams. Reviewed source; 55 focused regressions; signed phone and arm64 ad-hoc simulator builds pass. Exact native leaves pass once each, zero skips. The scorer takes over, awards/undoes/awards; filming phone observes changes while recording/publishing. Archive continues after stream stop and exports the actual new UUID.

Run `separate-native-scorer-kfuQEO`, lab `device-lab-uZky2H`: durable six-score/two-media command checks pass, no scorer recordings, all source/binary inputs unchanged. Archive 4546 frames/151.54s; both outputs4243 frames with the expected overlay sequence. Precise full A/V decodes and encoded timestamp continuity pass. Scene is almost black: no fresh-motion or perceptual A/V sync qualification. UI observed startup240p then360p; no adaptive collapse in this run. `assessment.json` preserves these limits. Both native jobs, lab, and owned simulator have joined/cleaned up. No capture/build/media-analysis job remains active.

## Pending device prerequisites and next actions

1. User asked to point the rear camera at a lit scene with movement; no response yet. Do not repeat unchanged dark capture. After repositioning, the same reviewed lane can verify visible motion; use only the new export UUID for collection.
2. Physical recovery runner LAN access remains denied. Short diagnostic `physical-recovery-2UDoQf` reports NSURLError-1009/CFStream50 and explicit `localNetworkDenied`; the Scorebug app itself connects. User was asked to enable ScorebugAppUITests-Runner under Settings → Privacy & Security → Local Network, or report missing/already enabled. After a state change run `scripts/test-physical-recovery.mjs --device … --host … --lane network-probe`; only if both HTTP checks pass run full recovery720. See [physical diagnosis](2026-09-26-physical-recovery.md). Do not reset privacy, delete Scorebug or disable firewall.
3. Combined physical Watch scoring needs a reachable developer connection. User already approved automation and reported both devices ready; latest Watch queries encountered tunnel failure then bounded timeout, not a proven lock. Networking readiness question is pending. Retry after a state change, not repeated automation permission requests. Separate Ultra2 scoring baseline passes; combined acceptance does not.

## Remaining delivery gaps

- Two ordinary360p recovery runs pass all media checks. 720p forced-collapse runs pass native/transport/geometry but lose live video/audio; clean archive passes. Keep failed evidence intact; no 720p recovery claim.
- First-descent audit shows pressure decision after initial overflow and ~456ms simulator profile application. Offline comparison places most delay between first new submission and completion (~431ms simulator versus27–30ms Mac hardware); not exact drain timing or physical-phone proof. See [breakdown](2026-09-26-replacement-latency-breakdown.md).
- Do not repeat unchanged simulator720 captures or restore rejected bitrate-first/source-pacing/maxbw experiments without new causal evidence.
- Wider profiles, sustained hardware, route changes/outages, second physical scorer/Watch, remote proxy hosts and real YouTube remain open.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed iOS26.2 runtime; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; Docker `scorebug/ingest:campaign-probe-v3`.

Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E`, watchOS26.6.

Separate native scorer launcher: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-separate-native-scorer.mjs --device 00008140-001474110C13001C --host 192.168.1.130`. It requires clean committed code, builds both targets before capture, creates only an owned simulator, and separately reports workflow versus media qualification.
