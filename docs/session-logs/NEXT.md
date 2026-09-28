# Next session handoff

## Direction and checkout

Simulator-first. Batch related changes, run focused checks, reuse saved passing
acceptance and incremental builds. Hardware/external hosts are deferred. No agents,
pushes, real broadcasts or purchases. Preserve originals and unrelated simulators.

Authoritative checkout: `/Users/jd/.codex/worktrees/scorebug-local-validation`,
branch `codex/local-validation`. The [delivery plan](../superpowers/plans/2026-09-13-portable-streaming-and-watch.md)
owns TODOs; the [acceptance matrix](../simulator-acceptance.md) owns retained evidence.
[Faster iteration](2026-09-28-faster-media-iteration.md) documents the diagnostic harness.

## Active checkpoint

UHD sender pacing fix: four-message token capacity and at most four nonblocking
writes per idle wake, rechecking pending media and all probe limits per message.
Standard pacing, v4 wire,48Mbps/64MiB bounds and receiver admission are unchanged.
Real SDK timer/pump diagnostic (always-accepting socket) improves48Mbps request
from25.143 to47.998Mbps; all four rates achieve99.5–100%.75 affected tests pass.
Patch reverse/original hashes/reapply verified. This measures sender scheduling,
not network capacity.

Full simulator `ordinary-native-aK6INv`, lab `device-lab-9PaWFc`, exec80522 joined1,
cleanup[].360/720/1080 confirmed; real receiver sees those geometries without gaps.
4K candidate fails `inputRejected / unresolvedInputLimit` (16 unresolved raw frames).
An earlier attempt timed out in sourceWait. No2160 admission or full media pass.
Native export succeeds;166 segment hashes checked.240s UHD terminal allowance works.
Artifacts and exact phase attachment are in the [session log](2026-09-28-uhd-sender-pacing.md).

Short real-footage SDK encoder diagnostic on macOS: normal4K24Mbps produces90/90
frames,83ms maximum completion delay; low-latency mode produces1/6 then hits raw
queue limit (375ms first completion). Do not switch production modes or raise limits.
The simulator/load-specific failure remains to isolate. SDK Xcode schemes available:
HaishinKit,HaishinKit-Package,SRTHaishinKit; test target HaishinKitPatchTests.
No simulator-specific SDK diagnostic has run yet. All jobs joined.

Production timing remains broadcast-reliability3000-v3:3s media,1s report age,
4.25s capture evaluation. Prior timing evidence/session retained.

## Reuse, don't repeat

- Native two-phone create/join/scoring, Watch B41mm takeover/relaunch/end, uncertain
  command recovery and archive fault recovery pass. Watch setup fixture/directHTTP
  does not qualify WatchConnectivity.
-1080 ladder/real receiver geometry/archive/live A/V/overlay: `ordinary-native-PpPozK`.
- Short native4K record/export/playback/relaunch: `recording-quality-20260928-media`.
- Relay generations/stale credentials/late reader, API/worker crash and Mac service
  outputs have retained passing checks. Severe congestion loses media; larger peer
  buffering worsened it. Keep broadcast3000/default SRT policy and avoid parameter-only reruns.

## Next work

1. Isolate4K candidate pending-input failure with a short simulator SDK encoding
   diagnostic. Existing opt-in `VideoCandidateEncoderTests/uhdNativeLatencyDiagnostic`
   reads `SCOREBUG_CANDIDATE_SOURCE`; normal and low-latency recipes are diagnostics,
   not passing-capacity assertions. Mac alone does not reproduce simulator failure.
   Inspect native encoder selection/startup/completion under the actual load; preserve
   memory/queue caps. Avoid another full8minute UI/export run without a causal fix.
2. After focused candidate fix, qualify full4K climb and saved media with retained
   `verify-2160-climb-20260928.py`, `verify-uhd-media-20260928.py` and
   `collect-ordinary-export-20260925.py`. Native frame/media thresholds unchanged.
3. Audit remaining delivery/pressure TODOs against existing coverage, then sustained
   profiles, physical companion/radio and external hosts. Hosted CI remains unverified
   until a push is authorized. Do not retest established two-phone/Watch features.

## Environment

Xcode `/Applications/Xcode-26.2.0.app/Contents/Developer`; scope DEVELOPER_DIR.
FFmpeg `/opt/homebrew/opt/ffmpeg-full/bin/`. Installed26.2 runtimes; generic simulator
builds require `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`. Last LAN192.168.1.130.

4K600s source: `artifacts/qa/uhd-app-20260928/input.mov`, SHA256
`be959258221b1427697d911daae4e54f99721fa69a82ae0c66f7b39922970d1a`.
1080 source: `artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov`.
Run: `node scripts/test-ordinary-native-app.mjs --host <LAN> --source <absolute.mov> --lane quality2160`.
Default relay remains `scorebug/ingest:drain-v1`; UHD lane explicitly usesv4.

Never print generated ordinary-environment.json; it contains test credentials.
Do not clear physical Watch Keychain or reconcile pending pairing blindly.
