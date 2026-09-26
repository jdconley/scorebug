# Next session handoff

## Working state

- Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Do not edit `/Users/jd/src/scorebug`.
- Active goal: native clean recording, phone/Watch scoring, progressive SRT, portable overlay proxy, mock RTMP MP4 and optional proxy-overlay MP4. Production camera publishing remains minimum-only.
- [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) contains current goals/status/todos. [Current session log](2026-09-25-owned-admission-and-probe-pressure.md) contains implementation/review evidence and failed experiments. [Research](../research/2026-09-25-live-platform-adaptation.md) distinguishes established sender adaptation from experimental product timing.
- Runtime HEAD of the latest experiment: `27a502d` (launched at documentation checkpoint `116765b`). No root process or review remains active. Preserve all failures and original Downloads/device recordings. Use installed runtimes only.

## Latest result

`native-app-9IVqF0` repeats the3000ms decoder/1000ms SRT case after reviewed instantaneous queue sampling:

- UI workflow passes360.852s; root11576 joins with intentional diagnosticexit1. Collection errors empty. Four phases240p→360p→240p→360p;556owned events,4owners,2acknowledgements/2failed settlements.
- Archive9273consecutiveframes0–9272; both live8827consecutiveframes229–9055. Full A/V decode passes, no frame identity gaps/reversals, identical live identities. Archive continues217frames beyond live. Analysis6549 joined0.
- Recorder exits0, no forced stop, eight clean lifecycle events. Separate score0→1 glyph checks pass both live outputs.
- All five timing/native/compressed/profile/capacity-clock leaves pass. Reviewed admission/application join passes4owners/2admissions; no full-media authority.
- **Delivery evidence fails completeness:**32MiB exhausted at374rows (33,525,136serialized bytes). All retained windows healthy, but final media extends20.4096s after last evaluation. Do not raise the established cap or discard history to claim a pass.
- **Live audio still fails:** approximately21ms gap near114.449s in both outputs; archive64waveform probes pass and has no timestamp gaps above3ms. A/V54722 joined1. No phase-audio pass claimed. Queue correction is valid but not a complete media-loss fix.

Artifacts: `owned-recording-diagnostic/`, `owned-av-overlay-diagnostic/`, `audio-timestamp-diagnosis.json`, `independent-score-glyphs/`, `owned-admission-application-replay.json`, `instantaneous-pressure-comparison.json`.

## Reviewed changes

- `27a502d`: both SRTSocket constructors use shared srt_bistats; demand(clear0,instantaneous1), periodic(1,1). Timestamp/failure/cancellation/counter contracts unchanged.71focused/80related/8final tests and bundled simulator build pass. Both independent reviews reran8tests;162upstream hashes and patch round trip pass. Controlled realSRT1.5.6 and bundled1.5.4 experiments prove bstats averaging hides current queue pressure.
- `4a86392`: whole-original-history admission/application joins passed both reviews and replays. Receiver conservation/intervals, candidate cost joins, timing profiles/expiry and recorder instrumentation also reviewed. Full retry/fault/media integration is still open.
- Previous detailed results and historical artifacts are in session logs. Particularly: clean media/four phases `LvDNAy` at2000/700; failed media `pzZozK`, `D4EhKU`, `uE9hUY`, `iUAsQ6` under their original profiles. Never relabel old evidence.

## Next implementation

1. Address residual live audio/probe behavior and complete evidence retention within existing lab budgets. The same fault replay now has continuous video but still drops audio; do not run another identical experiment without a change or new observation.
2. Finish [whole-history recovery qualification](../superpowers/plans/2026-09-25-owned-recovery-qualification.md): healthy holds/backoff, capacity causality and complete recorded media. Original admission and receipt correspondence now join independently.
3. Extract continuous delivery classification from Audit storage. Keep production state bounded and live beyond512windows/256identity changes. Preserve finite laboratory completeness gates.
4. Promote owned candidate runtime types and replace lifetime16attempt cap with one active owner, joined predecessor and policy cooldown. Driver512event cap only truncates diagnostics; don't claim it stops control.
5. Parameterize next-candidate probes: current lab ladder500kbps→2Mbps→12Mbps and stage3 assumption must not simply be enabled on phones. Replace laboratoryIPv4 fixed44byte/message cost with a validated production Wi-Fi/cellular/IPv4/IPv6 basis.
6. Wire ordinary camera through a production factory using existing guarded mutation, freshness, compressed AAC and owned lifecycle paths. Qualify240p350k→360p600k first, then wider backend/device ladder. Verify release construction, sustained state, thermal/archive independence and paired scoring.

## Physical devices

- Signing Conley Chaos LLC `B222J9J7B8`. Phone16Pro `00008140-001474110C13001C` iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E` watchOS26.6.
- Physical products in DerivedData/Physical and PhysicalWatch are at `eff8465`, not latest code; rebuild before new claims.
- User's prior readiness reply was consumed. Watch-first `device-lab-3RCYtU` timed out enabling automation; coordinated `device-lab-uh4flR` failed Watch destination preparation before its test launched. Phone recording/streaming started but wait-for-Watch timed out; cleanup completed. Its sampled video is black;89stored phone segments verified and diagnostic concatenation decodes, but native export was not reached.
- A subsequent automation/passcode question remains pending. Do not blindly rerun hardware without useful readiness change. Announce hardware work; camera lit/uncovered and Watch nearby/unlocked. User enters passcode on device, never chat. Credentials stay out of argv/logs.
- Prior visible phone three-output success `device-lab-yk1iYl/run11`; separate Watch command success `mmTL6h`. Full paired progressive vertical remains open. See [device runbook](../device-testing.md). Phone exports: `Library/Application Support/Scorebug/Recordings/Exports`.

## Environment and next-run tools

- Xcode: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
- FFmpeg/ffprobe: `/opt/homebrew/opt/ffmpeg-full/bin/`. Installed iOS26.2/iPhone14 simulator; no runtime downloads/unrelated cleanup.
- Source `artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`,390s, SHA256`c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`.
- Latest launcher `artifacts/qa/run-owned-reliability3000-peer1000-native-20260925-instantaneous.py 3000`. For a justified new run, use a unique suffix: outputs are exclusive and original evidence must remain intact. Commit source/docs before launch; launcher requires clean tracked state and records HEAD.
- Wrapper `repeated-live-checkpoint-run-check.py` writes `-exit.json`. Join processes explicitly. Run `analyze-owned-recordings-20260925.py` to completion before leaf/admission/A/V helpers. Huge errors may contain all audio probes or timelines: print scalar summaries only.
