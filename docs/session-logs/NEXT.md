# Next session handoff

## Current work

- Use `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Do not edit the original `/Users/jd/src/scorebug`.
- Active goal: reliable native recording, native phone/Watch scoring, progressive SRT to portable overlay proxy, mock RTMP MP4 and optional proxy-overlay MP4. Goal remains active; do not claim full completion.
- [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos. [Current session log](2026-09-25-ordinary-camera-adaptation.md) owns chronology, failures, commands and reviews.
- Current production implementation is through `2ad19b3` (diagnostics `3fef128`, `256c8c5`, `f814051`); subsequent commits update documentation. **Uncommitted measured-cost feedback is in progress.** Sole implementer `/root/ordinary_native_vertical` owns source/tests. Root owns docs and independent media analysis. Existing `/root/continuous_delivery_spec` accepted a new read-only spec review; earlier review-dispatch failures remain historical, not a current blanket prohibition.
- Execute the current follow-up in [production probe plan](../superpowers/plans/2026-09-25-production-probe-cost.md): learn one target/baseline revision/settings scoped scheduling hint from authoritative owned production `capacityHeadroom`/no-advice decisions. Next normal retry uses max(nominal, ceil(measured cost ×1.5)), preserving fresh admission, timing, backoff, exact ownership and native caps. Over-cap measured hints skip before registration/allocation without closing baseline. Clear on baseline change/stop; fixed lab plans ignore hints.
- No media run or root media process is active. Implementer is adding boundary/scope tests after the first actual decision→next-plan test passed. Review final code, run appropriate checks and Debug/Release builds, then a fresh complete ordinary vertical and independent media analysis.

## Latest ordinary evidence

- **Minimum-profile vertical qualified:** `ordinary-native-yVweTI` / `device-lab-FYiNYG` at `f814051`. Native scoring, stop, archive continuation and actual native MP4 export pass. Archive5733 sequential source frames0–5732; both live5459 identical frames156–5614;30 fresh fps in every complete second, full A/V decode and audio timestamps pass; archive tail118frames (~3.93s). Natural audio probes40archive/38eachlive, A/V coverage and native0–0→1–0 glyphs pass; archive clean. Results under `native-media-verification/`. Automatic increase failed separately.
- **Exact ramp blocker:** latest `ordinary-native-VeNxRu` / `device-lab-xPBh2q` at `2ad19b3` passes first-tap scoring, stop/continuation/export and clean teardown; adaptive150s gate fails. Admission/source are valid. Candidate cost905,984bps needs1,132,480bps at1.25 margin, but measured padding is1,049,228.72bps. Core correctly returns `capacityHeadroom`/no advice. Attachment `AED79EEA-98BD-41D4-8730-AAF5319434C1.json`. Do not loosen strict1500 timing or25% headroom to conceal this scheduling shortfall.
- **Separate unresolved scoring finding:** `ordinary-native-43w5fv` / `device-lab-roYDbC` missed HOME acknowledgment. Durable server contains only takeover, score0; app pending command null. Video/touch evidence shows correct unobscured button. Refresh collision is plausible but unproved. Harness preserves failure without retap and continues independent gates; no production scoring fix yet. Later success does not close this finding.
- All ordinary failed artifacts and originals remain preserved. Cleanup reports are empty; owned simulators were removed only after app-data preservation. Current runner exposes bounded current diagnostic scalars, not production event history. 181 relevant tests and Debug/Release arm64 builds passed at `3fef128`; final harness-only change has a passing UI build. New feedback needs fresh validation.

## Next verification

1. Finish/review measured-cost feedback; spec then quality review using available existing agents, or explicitly document any tool limitation. Commit only owned files.
2. Run `node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source "$(pwd)/artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov"` in the authoritative checkout. Runner uses only source injection and normal factories, private credentials, one owned iPhone14/iOS26.2 simulator, and real native setup/scoring/record/stream/stop/export. No lab selectors or timing overrides. Actual acknowledged240p→360p is required.
3. After joined cleanup, use `artifacts/qa/collect-ordinary-export-20260925.py RUN_ROOT`, then `analyze-ordinary-recordings-20260925.py INPUTS OUTDIR`, then `verify-ordinary-av-overlay-20260925.mjs INPUTS DECODED OUTDIR`. New output directories are exclusive. Require real native export, full decode/frame identities/fresh-fps/audio timestamps, waveform alignment, live score change, clean archive and continuation. Do not run heavy analysis alongside a live media test.
4. Reproduce score-input reliability, qualify fault/reset/recovery and paired Watch/physical camera. Then wider540p/1080p, sustained operation, other native scorer devices and remote workers. Automatic24Mbps4K exceeds current12Mbps probe capability and remains unqualified.

## Physical devices

- Signing: Conley Chaos LLC `B222J9J7B8`. iPhone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E`, watchOS26.6.
- User already approved automation/passcode prompt. Fresh CoreDevice checks still show both unavailable; USB inventory contains no iPhone/Apple Mobile entry. Reconnect/unlock question is pending. Do not request the same prompt approval again. Announce hardware automation once reachable; user enters passcode on device, never in chat.
- Signed phone/Watch build-for-testing products at `c99f752` verify team selection but are stale after later app/test changes. Rebuild before hardware execution; no hardware run during this ordinary-integration session.
- Earlier visible phone three-output pass: `device-lab-yk1iYl/run11`; separate Watch commands pass: `mmTL6h`. Combined paired progressive acceptance remains open. Preserve failed hardware attempts; see [device runbook](../device-testing.md) and [hardware session](2026-09-25-reliability-profile-and-paired-hardware.md).

## Earlier laboratory failures still open

- `native-app-9IVqF0` (experimental3000ms decoder/1000ms SRT) has four quality phases and continuous video, but its32MiB delivery audit expires374rows into the run, leaving20.4s uncovered. A21ms live audio gap also remains. Both live AAC payload sequences are identical, placing that gap before the tee. Do not relabel as complete recovery or raise audit caps.
- Exact-value interning experiment reduces33.5MB→11.4MB with identical reconstruction; runtime encoding and full terminal coverage remain unimplemented. Audio needs full-run bounded post-mux/worker-boundary diagnosis. Preserve original failures; do not repeat unchanged runs.
- Earlier clean media/four phases `LvDNAy` at2000/700 are a separate experimental profile. [Research](../research/2026-09-25-live-platform-adaptation.md) distinguishes published sender adaptation from product timing; [whole-history plan](../superpowers/plans/2026-09-25-owned-recovery-qualification.md) retains remaining qualification.

## Environment

- Xcode: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
- FFmpeg/ffprobe: `/opt/homebrew/opt/ffmpeg-full/bin/`. Installed iOS26.2/watchOS26.2 only; no missing-runtime downloads or unrelated cleanup.
- LAN address:192.168.1.130. Normal local stack uses maintained `scorebug/ingest:campaign-probe-v3` and100ms worker reports; both are reviewed. Image exists for linux/arm64. RemoteVPS templates still need relay-management/path/persistence modernization before portability claims.
- Prepared source:`artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`,390s,391,321,588bytes, SHA256`c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`. Downloads originals untouched.
- Preserve failed artifacts and join every process. Print scalar diagnostics, not full timelines, audio-probe arrays or credentials. No PR requested or created. Goal is unbounded and active.
