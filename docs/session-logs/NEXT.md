# Next session handoff

## Objective and workspace

Complete native phone recording/scoring and paired Watch scoring, progressive
SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlay MP4.
The goal remains active. Use `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`; never edit the original checkout. Runtime source
HEAD5634bea, with a small diagnostic slice under review. No PR requested. All current capture/build/media jobs are joined.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns goals/status/todos. [Current session](2026-09-26-collapse-packet-diagnostics.md)
owns chronology and artifacts. Preserve Downloads originals and failed evidence.
No runtime downloads, unrelated simulator deletion, or heavy builds/media analysis
during capture. Sign Conley Chaos LLC B222J9J7B8.

## Immediate priorities

Current source slice: constrain-anchored packet diagnostics, bounded to25s in the
recovery lab, with app/queue/rate behavior unchanged.132focused tests and formatting
pass; spec review approved, quality review pending. See the collapse diagnostic
plan. Commit reviewed source before repeating ordinary720/700ms to attribute the
burst. No native capture active.

1. Finish physical paired vertical when the Watch is unlocked. User approved phone
   automation, but fresh Xcode preflight still explicitly reports Watch locked.
   Async request asks to unlock the Watch and keep it on wrist; do not repeat an
   unchanged attempt. Latest `physical-paired-live-BIKKzC` / `device-lab-MObUL1`
   never starts phone capture, times out its240s Watch readiness gate, then joins
   after root interrupts owned runner77189. Clean lab shutdown: worker0/notforced,
   receiver finished/no sessions, failures:[]. Fresh e147ac4 signed phone/Watch
   builds pass; Watch paired/connected with developer services. Reuse helper
   `artifacts/qa/run-physical-paired-instrumented-20260926.mjs` after fresh readiness.
2. Diagnose collapse loss, not timing rejection. Ordinary `ordinary-native-JZQQai`
   / `device-lab-vVhC6B` completes full720recovery under broadcast3000ms + negotiated
   700ms upload recovery, but both live outputs fail media continuity. Preserve
   failed evidence and use existing bounded SRT packet diagnostics to distinguish
   original/drain traffic from retransmissions near collapse before choosing a fix.
   Existing source-cadence pacing is opt-in and did not qualify prior media; read
   September16 pacing/encoder-low-latency and September17 frame-delay plans first.
   Do not repeat unchanged runs or treat a wider deadline/queue as a loss fix.

## Latest verified result

Production timing source passed199app/8Core tests, DebugUI/Release builds and both
exact-blob reviews. Normal factory uses3000ms decoder/3500ms capture evaluation;
strict1500 remains explicitly constructible. Other freshness/stall/loss limits stay.

JZQQai workflow, independent native/actual750kbps transport and geometry replay
PASS.157segment actual native export collected. All129samples report3000/3500;
pressure receipts revisions3/4 confirm actual700ms sender delay. Six applied
transitions cover240→360→720→360→240→360→720. Phase attachment:
`401C06B8-279F-456A-A430-EC5A61C41722.json`.

MEDIA FAILS: archive9328consecutive frames/30fps/no audio gaps;64waveform and clean
glyph checks pass. Both live outputs8995frames with identical IDs,28barcode breaks,
26audio gaps, minimum1freshfps and0.933s maximum video gap during one collapse.
Archive111frame continuation passes. Upstream315overflow drops/297900wire bytes.
Live summed-audio coverage fails by about1234.7ms; this is not proof of permanent
presentation offset. Original producing manifest remains failed.49-file preservation
manifest `failed-media-evidence-manifest.json`. No accepted-window media mapping.

Previous `ordinary-native-TJzyrf`120ms run also fails collapse media; original
223packet loss and45barcode/24audio discontinuities are retained. Requested700ms
with strict1500 (`ordinary-native-3ux2FX`) passes initial240p media but cannot ramp.
Historical details are in the current session and transport/pipeline session logs.

## Baseline and open limits

Two complete ordinary360recovery passes:93koj3 and rpRZ6E, including three-output
media and six accepted-window mappings. Earlier te5IoU rollback remains unexplained;
older9IVqF0 audio/evidence failures remain failed. Separate physical phone camera
and Watch scoring baselines pass; combined acceptance is open. Paired simulator
companion registration remains unresolved. Sustained hardware, wider profiles,
outages/routes, other scorers, remote hosts and YouTube acceptance remain open.

Reviewed offline helpers live under artifacts/qa; hashes/review in
`ordinary-720-helper-review.json`. The mapper requires successful producing media
and must not qualify either failed720run. Use existing helpers, not substitute
archive concatenation or weakened frame/audio checks.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; installed runtimes only.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130.
Phone16Pro `00008140-001474110C13001C`, iOS26.7; Ultra2
`00008310-0000B2CE3E08A01E`, watchOS26.6.
Current physical build/readiness evidence: `physical-paired-current-mtc1mc54`,
phone-broadcast-ready/watch-broadcast-build/watch-broadcast-ready-20260926 labels.
Verified600s source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`,
18000IDs,1080p30/48kPCM, SHA256
`6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.
