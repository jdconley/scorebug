# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. The goal remains incomplete.

Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Reviewed implementation checkpoint: `fe35041`. Sign with Conley Chaos LLC `B222J9J7B8`. No PR/push requested. Preserve Downloads originals and unrelated recordings/simulators. No runtime downloads or heavy builds/media analysis during capture.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos; [latest session](2026-09-26-evening-device-resume.md) owns commands, failures and evidence.

## Current blocker and readiness

The user confirms the phone points at a lit moving scene and approved its new automation prompt. Physical run `physical-recovery-ydaKA3` now enters its test, observes initial ACK/source readiness, records/streams/scores/stops/exports, but fails the150s initial360 increase before impairment. It remains240p. All25 inputs unchanged and all jobs joined.

The subsequent paired Watch run `physical-paired-live-qBRzUf` times out enabling **Watch UI automation before its test body**. The phone camera is correctly not started. Fresh device checks were unlocked, but that does not establish automation initialization. The pending question asks whether a new phone/Watch prompt is visible and to approve it if shown. Do not retry without new readiness evidence.

Paired failure lab `device-lab-qkOT5A`: all14 inputs unchanged, worker exit0, receiver zero sessions, cleanup empty; root1127 joined1. No capture/build/media-analysis jobs remain active. Read-only adaptation design is complete; no implementation began. The next diagnostic is a separate bounded per-attempt DEBUG candidate summary, capturing exact receiver-time predicate operands and actual accumulated readiness blockers. Keep successful-ACK audit/UI payloads unchanged. Details are in the latest session log.

Runner direct LAN requests still report access denied despite the enabled switch. The reviewed DEBUG-only app loopback bridge passes actual phone API/controller and joined-shutdown checks. Use that path; do not reset privacy, delete Scorebug, disable firewall or repeat Settings navigation. See [Apple-source research](../research/2026-09-26-xctest-local-network.md).

## Reviewed and built checkpoint

- [Physical startup contract](../superpowers/plans/2026-09-26-physical-startup-acquisition.md): physical evidence format3 / `physical-recovery720-v1`; anchored10s initial encoder ACK, then30s owned-source acquisition retaining revision0/attempt/ACK. Ordinary contracts and later recovery guards unchanged. Independent reviews and182 focused tests pass.
- [Cadence rejection witness](../superpowers/plans/2026-09-26-cadence-rejection-witness.md): DEBUG-only exact receipt/evaluation-time age decomposition, first-cause latch, successful-ACK-only audit export. UI and production thresholds unchanged. Independent reviews,78 app tests,7 Core tests and210 Node tests pass. Includes separate strict physical transition-audit verifier.
- Signed Debug phone/Watch and Release builds pass. Binary checks prove bridge/diagnostic present in Debug and absent in Release. All jobs joined. Evidence: `artifacts/qa/physical-startup-witness-builds-20260926/`.

## Next actions

1. Prioritize the unchanged paired Watch retry after a new prompt approval. Recheck en0 and the prepared runtime hashes; use `artifacts/qa/run-physical-paired-lit-20260926.mjs`. It now binds newer phone capture products and unchanged Watch/source products via `artifacts/qa/paired-lit-provenance-20260926/result.json`. Do not reuse the older generic phone-binary hash after the physical launcher rebuild.
2. For a future evidence-backed adaptive comparison, the command is:
   `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane recovery720 --runner-transport app-loopback --bridge-port 49173`.
3. Freeze source/binaries during capture; join all work before media analysis. Collect only the actual new recording UUID export and exact publishing-attempt QA audit. Rehash inputs on failure too. Do not substitute old exports or observations.
4. Use new artifact wrappers `replay-physical-v3-recovery-20260926.mjs`, `verify-physical-applied-transitions-20260926.mjs`, and `verify-physical-output-media-20260926.py` under `artifacts/qa/`. The first two retain complete-collapse qualification; partial failed runs are diagnostic-only. Inspect visible motion/overlay and A/V separately from encoded continuity.
5. Diagnose the current ramp blocker before repeating it: first candidate cost913143bps versus demonstrated padding1040292bps did not meet1.25 headroom. Existing logic can raise the next probe demand to~1369715bps, so there is no proven hard ceiling. Retry reached cost-ready but recorded receiver-time-bounds; exact inequality and accumulated readiness blocker are missing. Preserve these values next, without relaxing headroom/timing. The earlier cadence-reset diagnosis remains separate; the latest audit has zero successful applications.
6. Update the current plan and this handoff; put chronology in the session log.

## Remaining qualification gaps

- The real phone plus a separate native iPhone14 simulator scorer passes scoring/undo, recording/streaming/export and allthree encoded-file checks. That scene was dark, so fresh motion and perceptual sync remain unqualified. See [separate scorer session](2026-09-26-separate-native-scorer.md).
- The latest lit phone run produces a221.6s clean1080p30 archive (6649frames) and both live files (6322frames each), all fully decoded with continuous encoded A/V. Samples show motion and overlay0–0→1–0; full fresh24fps/perceptual-sync qualification is still open. See `physical-recovery-ydaKA3/assessment.json`.
- Two ordinary360 recovery runs pass all media checks. Simulator720 forced-collapse runs lose live video/audio while the clean archive passes. No720 recovery qualification yet; do not repeat unchanged simulator experiments. See [latency breakdown](2026-09-26-replacement-latency-breakdown.md).
- Relative sender pacing remains experimental and unqualified; do not promote it from a failed ramp. See [comparison](2026-09-26-measured-relative-pacing.md).
- Sustained hardware operation, wider profiles, route changes/outages, second physical scorer/Watch, remote proxy hosts and real YouTube remain open. Local mock output precedes external broadcasts; no cloud purchases or real stream keys are authorized here.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed26.2 simulator runtimes; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; latest LAN10.0.0.122 (recheck); Docker `scorebug/ingest:campaign-probe-v3`.

Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E`, watchOS26.6.
