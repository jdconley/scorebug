# Next session handoff

## Objective and workspace

Complete native phone recording/scoring, paired Watch scoring, progressive SRT upload, portable score-overlay proxy, mock RTMP MP4 and optional overlaid MP4. Goal active. Use only `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. No PR/push requested. Sign Conley Chaos LLC B222J9J7B8.

[Delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md) owns goals/status/todos. [Current session](2026-09-26-physical-recovery.md) owns results, failures and artifacts. Preserve Downloads originals; no runtime downloads, unrelated simulator deletion, or heavy builds/media analysis during capture.

## Current work

Physical lane source `2bdcd60`, setup fixes through `f6dc8bf`: bounded physical camera recovery lane implemented and reviewed. Controller/UDP LAN routing explicitly uses an assigned private IPv4 host, with default loopback unchanged. Physical test preflight resolves runner LAN permission before recording. Actual new recording UUID is retained for scoped collection. Launcher binds actual Debug code and configured test inputs before/after execution; media qualification remains separate. 89 ordinary/network regression tests, seven launcher tests, five native helper tests and signed phone build pass.

Replacement latency replay (`a5b7799`) is complete: request→first new submission is about42ms on both host and simulator; first submission→completion is27–30ms on Mac hardware and~431ms on simulator. This is not exact old-encoder drain timing or proof of iPhone behavior. See [breakdown log](2026-09-26-replacement-latency-breakdown.md).

Physical setup rotation failure is fixed and verified past setup. Runner LAN preflight still fails before recording: BD0Vxw timed out with runner background; IFCArW foregrounded runner and tapped its LAN Allow prompt but timed out; N6qxbW repeated the timeout after the permission-state change. All attempts joined and have no lab cleanup failures; no recordings started. Host GET checks pass and Node is firewall-allowed. Do not repeat the full lane unchanged.

Current source `c1fef11`: isolated physical network probe implemented, independently reviewed and signed build passed.27 combined ordinary/physical launcher tests pass. Actual `physical-recovery-2UDoQf` diagnostic definitively finds the runner LAN privilege denied: both GETs return NSURLError-1009/CFStream50, and the TCP path explicitly reports `localNetworkDenied`. Cancellation joined; controller audit closed with zero mutations; all retained binary/source/private xctestrun hashes manually reverified unchanged after the failed probe. No recording started; no media claim.

Required input pending: user asked to enable ScorebugAppUITests-Runner under iPhone Settings → Privacy & Security → Local Network, or report missing/already enabled. After that state change, run the short network probe first; do not repeat full recovery while the runner is denied. See [current session](2026-09-26-physical-recovery.md).

User reconfirmed automation approval and both devices ready. Phone query reports unlocked. Watch queries failed to establish the developer connection twice (tunnel error, then bounded timeout); lock state is unknown, not proven locked. One networking clarification is pending. Combined paired capture has not started. Retry after a real readiness change; do not repeatedly prompt for already-granted automation authorization.

Next: after runner LAN access changes, rerun the reviewed short network probe, then return to full physical collapse if both HTTP checks pass. Only then collect the actual new archive/export/audit and assess native/transport/geometry plus source-appropriate camera media. Then run paired Watch scoring while phone records/streams when connected. Avoid builds/media analysis during capture. Do not repeat unchanged simulator720 captures or reapply rejected pacing/bitrate-first experiments.

## Acceptance still open

- Earlier full720p `ordinary-native-xjv6RI` (source5ee827a, labJeoRqF) passes native/transport/geometry but loses91video IDs and has21audio gaps. Archive10250sequentialframes/30fps plus70waveform/clean-glyph probes passes.54-file failure manifest retained. Earlier100ms pressure sampling remains active; ordinary SDK source-cadence pacing remains reverted. See [sampling log](2026-09-26-earlier-pressure-sampling.md).
- Two ordinary360p recovery runs93koj3/rpRZ6E pass all three outputs and accepted-window mappings. No720p recovery qualification yet. Keep all historical failures under original contracts.
- Separate physical phone camera and Watch scoring baselines pass. Combined acceptance remains open. User approved automation; phone is unlocked and Watch developer connectivity is pending. Last paired8qxiOg stopped before phone capture and joined cleanly. Paired simulator companion registration remains unresolved.
- Sustained hardware, higher profiles, outages/routes, other native scorers, remote workers and real YouTube remain open. Prefer a physical-phone collapse comparison over assuming simulator buffering represents iPhone hardware.

## Tools and environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`; LAN192.168.1.130; Docker `scorebug/ingest:campaign-probe-v3`. Phone16Pro00008140-001474110C13001C/iOS26.7; Ultra200008310-0000B2CE3E08A01E/watchOS26.6.

Source `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`:600s,18000IDs,1080p30,48kPCM, SHA2566c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6. Originals unchanged.

Full run: `node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source <absolute-source-path> --lane recovery720 --publish-peer-latency-ms 700` with Xcode environment. Reviewed root-owned helpers under artifacts/qa: collect-ordinary-export-20260925.py, replay-ordinary-720-recovery-20260926.mjs, verify-ordinary-720-media-20260926.py, verify-ordinary-av-overlay-20260925.mjs and analyze-collapse-packets-20260926.py. Export actual native archive; never substitute concatenated segments. Accepted-window mapper requires a successful producing media manifest.
