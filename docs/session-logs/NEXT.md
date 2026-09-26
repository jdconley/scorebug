# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. Goal active. Use only `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. No PR/push requested. Sign Conley Chaos LLC B222J9J7B8.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos. [Current session](2026-09-26-simulator-downshift-comparison.md) owns results, failures and artifacts. Preserve Downloads originals; no runtime downloads, unrelated simulator deletion, or heavy builds/media analysis during capture.

## Current work

All native captures joined. Reviewed frame180 simulator comparison `native-downshift-simulator-m2_n26dz` shows a pending-keyframe reduction234633→142553bytes but unchanged~480ms replacement. The initial lowercase-UUID launcher failure `bltk_6u5` remains failed with successful cleanup.

Reviewed frame181 host `native-downshift-adjacent-taykc_ic` and simulator `native-downshift-simulator-adjacent-_g_m04ab` pass strict analysis/provenance. Host only shrinks pending nonsync frame7677→5500bytes, with unchanged37166byte peak100ms output. Simulator has identical frame sizes and14pending frames298550bytes in both modes. Benefit is phase-dependent, not a general burst fix.14validator tests, native unit build and iOS simulator test build pass. Details/hashes in current session log.

The [guarded downshift experiment](../superpowers/plans/2026-09-26-guarded-downshift-experiment.md) is completed and rejected. Source241de49 run ordinary-native-EZqNUN/labCadzNV passes workflow/native/transport/geometry but fails live media:96missing IDs4545→4642,25audio gaps, min1fps/maxgap3.234s. Archive9289sequential30fps frames,64audio probes/clean glyphs,119frame continuation passes. AV summed-coverage~-1177ms failure does not establish permanent presentation offset. Preserve59-file failed evidence manifest and original false producing manifest. No accepted-window mapping.

All three candidate files restored exactly91857b7;17targeted tests pass, independent review verifies hashes. All process handles joined; no active build/capture/analysis or agent jobs. Candidate commit241de49 retains experiment; diagnostics91857b7 remain. Earlier100ms sampling is retained, ordinary pacer remains reverted. Next actual physical-phone collapse when unlocked; if local-only, retain bounded FIRST descent cause/admission/native-completion evidence to resolve missed revision3 before another policy intervention. Do not rerun unsupported simulator encoder settings or an unchanged full campaign.

## Acceptance still open

- Latest full720p `ordinary-native-xjv6RI` (source5ee827a, labJeoRqF) passes native/transport/geometry but loses91video IDs and has21audio gaps. Archive10250sequentialframes/30fps plus70waveform/clean-glyph probes passes.54-file failure manifest retained. Earlier100ms pressure sampling remains active; ordinary SDK source-cadence pacing remains reverted. See [sampling log](2026-09-26-earlier-pressure-sampling.md).
- Two ordinary360p recovery runs93koj3/rpRZ6E pass all three outputs and accepted-window mappings. No720p recovery qualification yet. Keep all historical failures under original contracts.
- Separate physical phone camera and Watch scoring baselines pass. Combined acceptance remains open. User approved automation, but latest direct phone and Watch lockState both report passcodeRequired:true; do not repeat paired capture without an actual unlock change. Last paired8qxiOg stopped before phone capture and joined cleanly. Paired simulator companion registration remains unresolved.
- Sustained hardware, higher profiles, outages/routes, other native scorers, remote workers and real YouTube remain open. Prefer a physical-phone collapse comparison over assuming simulator buffering represents iPhone hardware.

## Tools and environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; Docker `scorebug/ingest:campaign-probe-v3`. Phone16Pro00008140-001474110C13001C/iOS26.7; Ultra200008310-0000B2CE3E08A01E/watchOS26.6.

Source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`:600s,18000IDs,1080p30,48kPCM, SHA2566c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6. Originals unchanged.

Full run: `node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source <absolute-source-path> --lane recovery720 --publish-peer-latency-ms 700` with Xcode environment. Reviewed root-owned helpers under artifacts/qa: collect-ordinary-export-20260925.py, replay-ordinary-720-recovery-20260926.mjs, verify-ordinary-720-media-20260926.py, verify-ordinary-av-overlay-20260925.mjs and analyze-collapse-packets-20260926.py. Export actual native archive; never substitute concatenated segments. Accepted-window mapper requires a successful producing media manifest.
