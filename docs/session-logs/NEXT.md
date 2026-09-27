# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. The goal remains incomplete.

Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Reviewed implementation checkpoint: `fe35041`. Sign with Conley Chaos LLC `B222J9J7B8`. No PR/push requested. Preserve Downloads originals and unrelated recordings/simulators. No runtime downloads or heavy builds/media analysis during capture.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos; [latest session](2026-09-26-evening-device-resume.md) owns commands, failures and evidence.

## Current blocker and readiness

The user confirms the phone points at a lit moving scene. Fresh phone and Watch queries both report unlocked. The latest physical recovery runner nevertheless times out **enabling UI automation before the test body**, matching the first-session passcode prompt the user described. The pending question asks the user to approve a visible prompt or report none. Do not repeat the test without new readiness evidence, and do not assume unlocked means automation initialized.

Attempt `physical-recovery-EUdSsp`, lab `device-lab-oqKUm2`, source `fe35041`: no capture started, zero controller mutations/receiver sessions, worker exit0, cleanup empty, all25 execution inputs unchanged, root56518 joined1. No jobs remain active.

Runner direct LAN requests still report access denied despite the enabled switch. The reviewed DEBUG-only app loopback bridge passes its real-phone API/controller and joined-shutdown probe (`physical-recovery-ymge6q`). Use that supported path; do not reset privacy, delete Scorebug, disable firewall or repeat Settings navigation. See [Apple-source research](../research/2026-09-26-xctest-local-network.md).

## Reviewed and built checkpoint

- [Physical startup contract](../superpowers/plans/2026-09-26-physical-startup-acquisition.md): physical evidence format3 / `physical-recovery720-v1`; anchored10s initial encoder ACK, then30s owned-source acquisition retaining revision0/attempt/ACK. Ordinary contracts and later recovery guards unchanged. Independent reviews and182 focused tests pass.
- [Cadence rejection witness](../superpowers/plans/2026-09-26-cadence-rejection-witness.md): DEBUG-only exact receipt/evaluation-time age decomposition, first-cause latch, successful-ACK-only audit export. UI and production thresholds unchanged. Independent reviews,78 app tests,7 Core tests and210 Node tests pass. Includes separate strict physical transition-audit verifier.
- Signed Debug phone/Watch and Release builds pass. Binary checks prove bridge/diagnostic present in Debug and absent in Release. All jobs joined. Evidence: `artifacts/qa/physical-startup-witness-builds-20260926/`.

## Next actions

1. After the phone automation prerequisite is resolved, recheck en0 and run:
   `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane recovery720 --runner-transport app-loopback --bridge-port 49173`.
2. Freeze source/binaries during capture; join all work before media analysis. Collect only the actual new recording UUID export and exact publishing-attempt QA audit. Rehash inputs on failure too. Do not substitute old exports or observations.
3. Use new artifact wrappers `replay-physical-v3-recovery-20260926.mjs`, `verify-physical-applied-transitions-20260926.mjs`, and `verify-physical-output-media-20260926.py` under `artifacts/qa/`. The first two retain complete-collapse qualification; partial failed runs are diagnostic-only. Inspect visible motion/overlay and A/V separately from encoded continuity.
4. Inspect exact cadence rejection age before changing policy/reporting behavior. Prior phone360 trials reset on cadence freshness without injected impairment; later mutable UI values cannot explain the original rejection. Do not relax250ms or other guards merely to pass.
5. Run combined physical Watch scoring while its paired phone records/streams after the phone run and collection join. `artifacts/qa/run-physical-paired-lit-20260926.mjs` uses current host and the fresh build manifest; recheck host/products before use. It waits for Watch readiness before starting phone capture. Earlier Watch automation also timed out before its body; separate Ultra2 scoring has passed, combined acceptance has not.
6. Update the current plan and this handoff; put chronology in the session log.

## Remaining qualification gaps

- The real phone plus a separate native iPhone14 simulator scorer passes scoring/undo, recording/streaming/export and allthree encoded-file checks. That scene was dark, so fresh motion and perceptual sync remain unqualified. See [separate scorer session](2026-09-26-separate-native-scorer.md).
- Two ordinary360 recovery runs pass all media checks. Simulator720 forced-collapse runs lose live video/audio while the clean archive passes. No720 recovery qualification yet; do not repeat unchanged simulator experiments. See [latency breakdown](2026-09-26-replacement-latency-breakdown.md).
- Relative sender pacing remains experimental and unqualified; do not promote it from a failed ramp. See [comparison](2026-09-26-measured-relative-pacing.md).
- Sustained hardware operation, wider profiles, route changes/outages, second physical scorer/Watch, remote proxy hosts and real YouTube remain open. Local mock output precedes external broadcasts; no cloud purchases or real stream keys are authorized here.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed26.2 simulator runtimes; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; latest LAN10.0.0.122 (recheck); Docker `scorebug/ingest:campaign-probe-v3`.

Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E`, watchOS26.6.
