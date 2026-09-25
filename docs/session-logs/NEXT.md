# Next session handoff

## Working state

- Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Do not work in the original `/Users/jd/src/scorebug` checkout.
- Active goal: complete native recording, native phone/Watch scoring, progressive SRT publication, portable overlay proxy, mock RTMP MP4 and optional proxy-overlay MP4.
- [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) contains goals/status/todos. Current evidence and commands: [reliability session](2026-09-25-reliability-profile-and-paired-hardware.md). [Research](../research/2026-09-25-live-platform-adaptation.md) explains the latency/adaptation choices.
- Implementation `aaa9afc` and expiry fix `c4c30cd` passed spec and quality reviews. Full JS4,953/Core498 before expiry fix; after fix Core500/Session21/focusedJS183 pass. Root full app-model619 and focused93 tests, arm64 iOS build pass. No production real-camera adaptation is enabled.
- No root test/lab/analysis process remains running. All review agents completed. Preserve all failed evidence and original Downloads videos; use only installed runtimes.

## Fresh result: 2-second reliability profile

- `artifacts/qa/native-app-LvDNAy`, source checkpoint086ff94: UI pass; diagnostics collection errors empty; intentional diagnostic exit1. All six timing envelopes consistently select `broadcast-reliability2000-v1`.
- Same390-second input SHA c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814,700msSRT,capacity750k-retry/token-budget fault90s→restore150s,270-second hold.
- Clean archive9,313frames0–9,312; each live8,860frames227–9,086. Full A/V decode, sequential identities, native compressed/profile phases, natural waveform grid, eight phase-boundary anchors per live output, score0–0→1–0 and226-frame archive continuation pass. All410 overlapping delivery windows on time. Four phases240p→360p→240p→360p each30freshfps.
- Applications27.82s increase,90.89s decrease,182.99s restored increase after bootstrap. Original540owned events retain two acknowledged and two failed measurements. Trusted native probes, capacity clocks and accounted-media leaves pass. Complete whole-history recovery qualification remains unfinished; do not promote leaf results to production authority.
- Result files: `owned-recording-diagnostic/results.json`, `leaf-results.json`, `owned-av-overlay-diagnostic/results.json`, `phase-audio.json`, `latency-budget-diagnosis.json`, `timing-evidence.json`. Sampled visual preview `owned-recording-diagnostic/four-phase-preview.png`.

## Next implementation/testing

1. Run the prepared3000comparison from a clean tree: `python3 artifacts/qa/run-owned-reliability-native-20260925.py 3000`. It records sourceHEAD and rejects inherited/partial flags. Retain strict1500,2000 and3000 as separate experiments; do not relabel historical failures.
2. After joining, use `analyze-owned-recordings-20260925.py`, `replay-owned-timing-leaves-20260925.mjs ARTIFACT broadcast-reliability3000-v1`, `verify-owned-av-overlay-20260925.mjs`, then `verify-owned-phase-audio-20260925.mjs` and `diagnose-owned-timing-profile-20260925.mjs`. All are artifact-local helpers under `artifacts/qa`, output wx evidence and do not grant full qualification. Phase helper requires successful four-phase leaf and prior A/V checks.
3. Complete [whole-history recovery qualification](../superpowers/plans/2026-09-25-owned-recovery-qualification.md): original receiver campaigns/conservation; raw candidate witness; native application/encoder receipts; policy chronology including failed attempts and 10/20/40/60s holds; capacity clock causality; all recorded media. Reuse reviewed helpers, keep size/resource limits, no success-only histories or synthetic legacy envelopes. Candidate encoder identity first appears at joined result, not start.
4. Integrate qualified controller/candidate measurement/feedback into the real-camera path. `PublishingQualityDriver.fixture` is currently DEBUG simulator-only; physical fixed240smoke is not progressive-streaming acceptance. Then wider ladder, sustained capture/outages, other native phone/Watch route, remote workers and real YouTube.

## Physical device retry

- Signing: Conley Chaos LLC B222J9J7B8. iPhone16Pro UDID00008140-001474110C13001C iOS26.7; Ultra2 UDID00008310-0000B2CE3E08A01E watchOS26.6. Per-command Xcode26.2 at `/Applications/Xcode-26.2.0.app/Contents/Developer`.
- Phone/Watch physical products in DerivedData/Physical and PhysicalWatch were built at eff8465; phone explicitly installed while idle. They are not c4c30cd timing binaries. Build/install current source before claiming that source physically tested; preserve existing capture.
- User approved the phone automation prompt and confirmed both devices ready. New Watch-first `device-lab-3RCYtU` still timed out enabling automation before any test case. Phone never started. Lab and runner joined, no media sessions, clean shutdown. Watch tunnel was connected, then a lock-state query lost connection; later details reconnected. No confirmed root cause.
- Pending async question asks whether a new automation/passcode prompt appeared on either device during retry. Do not repeat the same question or blindly rerun.
- Working-history clue: in successful Watch run mmTL6h the phone automation was already active before Watch initialization. A phone-active/simultaneous launch is a bounded coordination hypothesis if readiness permits. Earlier Watch-first guidance was intended to avoid exhausting phone deadlines during Watch preparation; it is not proof that sequencing is required.
- Use fresh lab and credentials for each retry; old IWDkV4/3RCYtU labs are stopped. Private setup credentials belong only in child environment, never argv/shared logs. Announce tests, keep camera lit/uncovered and Watch unlocked. User enters passcode on device, never chat.
- Historical phone three-output pass: device-lab-yk1iYl/run11. Watch real setup/takeover/point/undo/away/end passed mmTL6h, but concurrent camera samples black and phone failed before export. Complete paired three-output acceptance is still open. Correct export directory: `Library/Application Support/Scorebug/Recordings/Exports`; identify newly created file, not an old export.

## References and boundaries

- [Device runbook](../device-testing.md), [relay/native evidence](2026-09-25-relay-recovery-budget.md), [owned app work](2026-09-25-owned-measurement-app.md).
- Historical400ms native mAluZi had all four phases but damaged reference frames.700ms7JYkdI and1000mssiloC2 retained clean media but no complete ramp under strict1500deadline. Never erase or reinterpret those results.
- FFmpeg/ffprobe: `/opt/homebrew/opt/ffmpeg-full/bin/`; installed iOS26.2/iPhone14 simulator route. No runtime downloads, unrelated simulator deletion or global tool relinking.
