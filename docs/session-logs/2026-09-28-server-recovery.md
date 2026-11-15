# Native recording and publishing across server restarts

Starting checkout: `codex/local-validation`, `345dfa4`, clean. Simulator-first; no hardware actions.

## Change

Control and worker-status polling previously detached a healthy SRT publisher on any API error, then scheduled a broadcast stop. Established healthy publishing now survives transient connection errors, HTTP429 and HTTP5xx. Polling clears stale worker/adaptation evidence and automatically reconciles the current selection when the API returns. Unauthorized/forbidden responses, invalid state and storage failures retain terminal behavior. New failed starts require another tap; explicit stops remain terminal. Local recording stays independent.

The existing ordinary native simulator workflow gains `--lane server-recovery`. Its native UI requests two host-side owned-process restarts after scoring: API SIGKILL/restart with the same SQLite database, secrets and port; then graceful worker shutdown/restart. Each holds the process unavailable for15seconds. The native UI observes unavailable and recovered worker state while continuously checking recording/publishing. It then stops, verifies the archive continues, and exports. This does not qualify a hard worker crash or relay/source interruption.

## Verification

- Focused red: two new established-session recovery checks failed eight assertions before the fix (`artifacts/qa/control-recovery-red.log`).
- CaptureStreamingModelTests:118 pass,25.2seconds (`control-recovery-green.log`). Includes offline recovery, changed selection, explicit stop, HTTP401/403/429/503, queued starts, storage errors, request cancellation and stale owners.
- Ordinary launcher/device-lab checks:35 pass (`server-recovery-launcher-final.log`).
- Native `ordinary-native-QOuplL`, lab `device-lab-Kebxdx`: workflow passes in157seconds, all cleanup passes. API and worker unavailable for15.208/15.311seconds respectively. The worker exercised its real five-second control deadline. Publisher remains accepted in generation1 through both recoveries, without another Start tap. Code is based on345dfa4 plus the patch/hash in the run's `implementation.json`.
- Media:44native segments pass hashes/metadata checks; native export contains2534consecutive source frames starting at0, at30fps. Both outputs contain three decodable H264/AAC sessions. Two sampled final frames in each recovered output independently match HOME1–0AWAY and reject0–0/1–1; archive samples have no overlay. Final A/V end offsets: archive12ms, direct8.3ms, proxy−12.8ms. Reports and scripts are under the run's `native-media-verification/`.
- Limitation: interrupted first/second output segments have roughly0.48–0.52seconds of audio beyond their last video frame. Expected process-outage gaps are retained as separate files; no concatenation, padding or blanket continuity claim. Healthy final outputs recover, but seamless crash media/tail coverage is not qualified.
- Native command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane server-recovery`.
- All process handles joined. Owned simulator removed, app data preserved, lab stopped. No repeated broad native/Watch suite or hardware build.

## Remaining scope

Hard worker crash/source interruption, backend capability negotiation and the saved720p congestion failure remain open. Real devices remain deferred.
