# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. Goal active. Use only `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. No PR/push requested. Sign Conley Chaos LLC B222J9J7B8.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos. [Current session](2026-09-26-first-descent-evidence.md) owns results, failures and artifacts. Preserve Downloads originals; no runtime downloads, unrelated simulator deletion, or heavy builds/media analysis during capture.

## Current work

Source376f761 implements the reviewed DEBUG successful-application audit:16records/8192bytes, capture in memory, immutable post-shutdown export, unchanged UI and policy.82focused Swift tests and39Node tests pass; signed phone/watch build-for-testing and Release build pass. All builds joined before capture. Details in [first-descent session](2026-09-26-first-descent-evidence.md) and [implementation plan](../superpowers/plans/2026-09-26-first-descent-evidence.md).

Fresh `ordinary-native-Kfk8rj`/lab`device-lab-w1Lwsr` completed; all jobs joined (capture15741exit0, media36036exit1, AV31004exit1). Native/transport/geometry and complete audit validation pass:6successful records,5sampled UI witnesses, first descent captured. Cause542–570ms after constraint, native completion1001–1029ms, profile456ms. First proxy overflow516ms: decision is already25.6–53.8ms late. No drain-vs-new-output breakdown yet. Largest early burst200–300ms precedes replacement. Full media fails:162missing IDs/two duplicates/30audio gaps in both lives; clean archive10779sequential30fps and74audio probes/glyphs passes,115frame tail. Original false producing manifest and immutable failed-media hash manifest retained; no accepted-window mapping.

Next: prioritize a physical-phone collapse comparison, plus paired Watch/camera acceptance, when actually unlocked. If hardware remains unavailable, first design a bounded native replacement breakdown (old-session drain completion, first new-frame submission/completion/compressed output) to distinguish the~456ms simulator span. Keep policy and transport unchanged for that causal comparison; do not repeat another unchanged ordinary720 run. Current phone/watch signed builds are ready; root has no active builds/captures/analyses or agent work.

User reports prompt approved; subsequent actual readiness queries nevertheless show both devices passcodeRequired:true. Initial Watch query failed allocation, bounded retry restored connectivity but remains locked. Fresh unlock question pending; signed current device builds are ready. Prioritize paired hardware run after actual unlock and after current capture joins. No extra automation approval needed unless a new prompt is observed.

Prior guarded bitrate-first241de49 experiment remains rejected and restored by62f08ea. Native phase comparisons show only phase-dependent benefit, no general burst solution. Full candidate EZqNUN retains59-file media failure; previous xjv6RI also remains failed. First-descent timings are the next diagnostic, not a policy fix. Do not repeat unsupported simulator low-latency/frame-delay properties.

## Acceptance still open

- Earlier full720p `ordinary-native-xjv6RI` (source5ee827a, labJeoRqF) passes native/transport/geometry but loses91video IDs and has21audio gaps. Archive10250sequentialframes/30fps plus70waveform/clean-glyph probes passes.54-file failure manifest retained. Earlier100ms pressure sampling remains active; ordinary SDK source-cadence pacing remains reverted. See [sampling log](2026-09-26-earlier-pressure-sampling.md).
- Two ordinary360p recovery runs93koj3/rpRZ6E pass all three outputs and accepted-window mappings. No720p recovery qualification yet. Keep all historical failures under original contracts.
- Separate physical phone camera and Watch scoring baselines pass. Combined acceptance remains open. User approved automation, but latest direct phone and Watch lockState both report passcodeRequired:true; do not repeat paired capture without an actual unlock change. Last paired8qxiOg stopped before phone capture and joined cleanly. Paired simulator companion registration remains unresolved.
- Sustained hardware, higher profiles, outages/routes, other native scorers, remote workers and real YouTube remain open. Prefer a physical-phone collapse comparison over assuming simulator buffering represents iPhone hardware.

## Tools and environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; Docker `scorebug/ingest:campaign-probe-v3`. Phone16Pro00008140-001474110C13001C/iOS26.7; Ultra200008310-0000B2CE3E08A01E/watchOS26.6.

Source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`:600s,18000IDs,1080p30,48kPCM, SHA2566c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6. Originals unchanged.

Full run: `node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source <absolute-source-path> --lane recovery720 --publish-peer-latency-ms 700` with Xcode environment. Reviewed root-owned helpers under artifacts/qa: collect-ordinary-export-20260925.py, replay-ordinary-720-recovery-20260926.mjs, verify-ordinary-720-media-20260926.py, verify-ordinary-av-overlay-20260925.mjs and analyze-collapse-packets-20260926.py. Export actual native archive; never substitute concatenated segments. Accepted-window mapper requires a successful producing media manifest.
