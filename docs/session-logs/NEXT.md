# Next session handoff

## Working state

- Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Do not edit the original `/Users/jd/src/scorebug` checkout.
- Active goal: native recording, native phone/Watch scoring, progressive SRT, portable overlay proxy, mock RTMP MP4 and optional proxy-overlay MP4.
- [Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) is current goals/status/todos. [Current session log](2026-09-25-reliability-profile-and-paired-hardware.md) preserves commands, evidence and failed experiments; [research](../research/2026-09-25-live-platform-adaptation.md) explains the timing choices.
- Runtime timing contracts `aaa9afc` and expiry fix `c4c30cd` passed specification and quality reviews. New whole-history receiver conservation `d59fdcd` and interval replay `5535489` also passed both reviews. Root122 interval/conservation tests pass; quality reviewer236 related tests pass. Candidate/witness/application/retry-policy joins remain unfinished.
- No root test/lab/analysis process is currently running. The next native experiment is prepared below. Preserve failures, original Downloads footage and device recordings. Use installed runtimes only.

## Current evidence and next experiment

| Experiment | Decoder budget / SRT | Result |
| --- | --- | --- |
| `native-app-LvDNAy` | 2000 / 700 ms | Clean four phases, all recorded frame/audio/score checks pass. Complete recovery qualification remains open. |
| `native-app-pzZozK` | 3000 / 700 ms | Four phases, but one missing live frame and decoded identity damage. Archive clean. |
| `native-app-D4EhKU` | 2000 / 1000 ms | Clean video identities, but one live audio gap, two problematic delivery windows and no quality applications. Archive clean. |

- D4EhKU launched at `c62cf61`; root14560 joined intentional diagnosticexit1, UI1/0. Analysis29983 joined0; A/V70595 joined1. Both live files8865sequentialframes227–9091; archive9307frames0–9306. Live waveform/timestamps reveal ~21ms audio gap around133.374s. Four-phase gates correctly reject one phase; no score/phase-audio pass claimed.
- D4EhKU retains1317nativeevents, six failed attempts, five completed candidates. Diagnosis finds source-health expiry precedes the first usable post-candidate receiver interval in each completed attempt. Do not confuse missing readiness with bad encoding. The source and receiver evidence must overlap; preserve independent freshness limits.
- Next controlled run: `python3 artifacts/qa/run-owned-reliability3000-peer1000-native-20260925.py 3000`. It changes only the explicit timing profile/budget versus D4EhKU, keeps1000msSRT and all faults/source unchanged. Run from a clean tracked tree and join its original handle. Never infer success from UI or intentional diagnostic exit1.
- After collection: run `analyze-owned-recordings-20260925.py`, `replay-owned-timing-leaves-20260925.mjs ARTIFACT broadcast-reliability3000-v1`, `verify-owned-av-overlay-20260925.mjs`, and `diagnose-owned-timing-profile-20260925.mjs` from `artifacts/qa/`. Phase-audio helper requires both four-phase and A/V passes. Helpers write exclusive output paths; retain failures rather than overwrite.
- Root replayed new receiver intervals on all three complete artifacts. Results are saved as `owned-native-receiver-intervals-replay.json`; all pass this bounded slice and deny admission/recovery authority. LvDNAy10covered/3unbracketed, pzZozK10/4, D4EhKU27/9. Do not fabricate missing coverage or trim failed campaigns.

## Remaining implementation

1. Complete [whole-history recovery qualification](../superpowers/plans/2026-09-25-owned-recovery-qualification.md): candidate witnesses, native application receipts, healthy holds/backoff, capacity causality and all recorded media. Reuse original complete history and reviewed bounded helpers.
2. Integrate qualified adaptation into the real-camera path. Current physical publisher is minimum-only; `PublishingQualityDriver.fixture` and owned measurement are debug routes. Production must use bounded current state that continues throughout a match, independently of finite laboratory audit/attempt caps. Preserve lab caps and history.
3. Complete paired phone/Watch three-output acceptance, then wider ladder, sustained capture/outages, other native scorers and remote workers. Fixed-profile physical success does not prove progressive streaming.

## Physical devices

- Signing: Conley Chaos LLC `B222J9J7B8`. iPhone16Pro `00008140-001474110C13001C` iOS26.7; Ultra2 `00008310-0000B2CE3E08A01E` watchOS26.6. Xcode26.2 at `/Applications/Xcode-26.2.0.app/Contents/Developer`.
- Physical products under DerivedData/Physical and PhysicalWatch are built at `eff8465`, not the timing-experiment checkpoint. Rebuild/install current source before claiming it physically tested; preserve recordings.
- User approved the prompt and confirmed readiness. Watch-first retry `device-lab-3RCYtU` still timed out enabling automation. Coordinated phone-first/concurrent retry `device-lab-uh4flR` passed unlocked preflight but Watch failed destination preparation before test launch. Phone reached recording/publishing then timed out waiting for Watch; cleanup completed. Labs/runners are all stopped.
- uh4flR live files fully decode but sampled camera content is black. Its new phone recording has89 verified stored segments and diagnostic concatenation decodes, but no native export was reached. Do not claim paired success or native export.
- Pending question asks whether another automation/passcode prompt appeared. Do not repeat it or blindly rerun without a useful readiness change. Announce hardware tests; keep camera lit/uncovered and Watch nearby/unlocked. User enters passcode on device, never chat. Credentials only in child environment, never argv/shared logs.
- Prior visible phone three-output pass: `device-lab-yk1iYl/run11`; prior separate Watch command pass: `mmTL6h`. [Device runbook](../device-testing.md). Correct exports: `Library/Application Support/Scorebug/Recordings/Exports`; identify the newly created file.

## Environment

- FFmpeg/ffprobe: `/opt/homebrew/opt/ffmpeg-full/bin/`; installed iOS26.2/iPhone14 simulator route. No runtime downloads, unrelated cleanup or global relinking.
- Prepared390s source: `artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`, SHA256 `c1d0642bb102ca27733f39ece227c77135699e89f9ad29a67ddec34d5d2af814`.
