# September 25 — Three-output vertical and physical readiness

Starting implementation commit: `b65ca7f`, branch `codex/local-validation`, checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`. User requested outstanding reviews, a pure delivery plan with separate history, then the fastest useful native vertical with an optional proxy overlay recording. Later selected Conley Chaos LLC (`B222J9J7B8`) for device signing.

## Reviews and plan

Outstanding guarded Session specification and quality reviews approved; checkpoint committed as `b65ca7f`. Plan cleanup committed `0e130be`: lossless history plus imported checkpoint logs, with all 64 original checkbox texts/statuses retained and three new integration tasks. The first root checkbox comparison incorrectly compared wrapped first lines; the corrected whitespace/reflow comparison passed all 64. Root subsequently removed the remaining historical-anchor inventory from the live plan, leaving history in the archive and the plan focused on goals/status/todos.

## Proxy final-output recording

Added `OUTPUT_MODE=rtmp|record|rtmp+record`, `OUTPUT_RECORDING_DIR`, unique private attempt files, and one-encode tee output. Defaults remain RTMP. Output errors abort the attempt. Source timebase and A/V relationship remain preserved.

Red/green FFmpeg work found `empty_moov` erased a 0.6-second source audio lead. `frag_keyframe+delay_moov+default_base_moof` preserves it; recovery requires a completed first fragment and can lose a partial tail. Full home-daemon suite reported 26 files / 436 passing tests with real media enabled; build/typecheck passed. Independent spec/quality reviewers each passed 35 focused tests; spec reviewer also reran actual FFmpeg qualification. No remaining review findings. Real-media component checks cover frame preservation, overlay pixels, escaped paths, either sink failing, and decoding completed fragments without a trailer.

## Native simulator vertical

Command: `SCOREBUG_IOS_RUNTIME=26.2 SCOREBUG_IOS_DEVICE_TYPE=iPhone-14 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_PROXY_RECORDING=1 python3 artifacts/qa/repeated-live-checkpoint-run-check.py native-three-output-20260925 node scripts/test-native-app.mjs --streaming`.

Joined exit 0. Evidence: `artifacts/qa/native-app-k1oNme/results.json`; wrapper log/exit record use `repeated-live-checkpoint-native-three-output-20260925`.

- Native UI recorded, started SRT, awarded a point, stopped streaming, continued recording and exported.
- Clean archive: 1,555 consecutive source frames 0–1554; 30 fps; zero source loss.
- Mock RTMP MP4 and proxy overlay MP4: each 1,119 consecutive source frames 232–1350; approximately 30 fps; zero loss within acquired spans.
- All three MP4s fully decoded. Both overlay outputs contain the scored change. Measured maximum A/V pulse offset: archive 0.021 ms, RTMP recording 64.917 ms, proxy recording 66.250 ms.
- The archive continued at least two seconds beyond live video. This is a synthetic simulator smoke, not physical camera/Watch, adaptive recovery or sustained network qualification.
- Owned temporary simulator/containers were removed by the joined harness.

## Device lab

Added `scripts/device-lab.mjs`: explicit assigned RFC1918 LAN bind, generated development credentials, isolated SQLite database and relay container, loopback management/mock RTMP, both worker outputs and bounded duration/cleanup. Setup details remain private under its unique artifact directory. See [device runbook](../device-testing.md).

- Real startup/shutdown passed for `device-lab-ucoCpH` and final `device-lab-qCEnp4`; worker exited 0, receiver joined, no cleanup failures.
- SIGTERM during startup produced `device-lab-fxi6SV/shutdown.json`: receiver finished, no cleanup failures; process joined with abort exit 1. The ad-hoc collector initially failed because a glob included its own log file; this was a collector error, not a cleanup pass assertion.
- Review initially alleged equal inner/outer shutdown timers. Review withdrew that finding after tracing the actual worker override (1-second inner grace). Added explicit forced/nonzero exit reporting anyway, with a 10-second outer grace.
- Three launcher option/process tests and 45 streaming-option tests passed (48 total). Independent spec and quality reviews approved. Proxy MP4 validation remains separate from the pre-existing live array.

## Physical work in progress

Unsigned phone/embedded-Watch build joined exit 0. Signed phone/embedded-Watch build with `DEVELOPMENT_TEAM=B222J9J7B8 CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -allowProvisioningDeviceRegistration` joined exit 0. Phone app installation succeeded (`physical-phone-install-20260925.json`).

Direct installation of the embedded Watch app failed with profile error `0xe8008012`; a Watch-destination-specific signed build is the next attempt. No Watch installation or physical media pass claimed yet. Dedicated physical UI smoke test is being added without changing simulator assertions. An owned LAN lab (`device-lab-57c8N3`) is active for the test; it must be stopped and joined when finished.

Phone: iPhone 16 Pro, iOS 26.7; Watch: Ultra 2, watchOS 26.6. Both previously reported Developer Mode enabled. Physical permissions, camera behavior, Watch pairing/scoring, and all exported device media remain to be checked.
