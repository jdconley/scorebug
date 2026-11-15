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

### Hardware follow-up

The first Watch destination build timed out with an unlock/preparation error; both devices subsequently reported unlocked. The next build reached provisioning and failed because Xcode lacked a signed-in Conley Chaos account and the saved profile excluded the Watch. User signed in; `physical-watch-signed-build-account-20260925` then joined exit 0. Watch installation is being retried with this build.

Phone UI run 1 (`physical-phone-smoke-20260925`, exit 65) failed before test execution while enabling UI automation. User enabled it. Run 2 (`physical-phone-smoke-02-20260925`, exit 65) executed native setup, but the test's cursor-sensitive replacement corrupted the endpoint (`hthttp…`). This does not prove a LAN or app defect. Captured hierarchy and screen recording are under `device-lab-57c8N3/phone-smoke-02-attachments`. A secondary absent-element query in final test evidence is also being corrected.

Physical test specification review fixed two preservation issues before run 2: use `activate()` rather than terminating an already running app, and reserve recording cleanup separately from stream cleanup. Quality review independently found the text replacement problem confirmed by the physical run. These failures remain preserved; no hardware media pass is claimed.

Watch-specific signing, installation and launch now pass after the user signed into the selected team. `physical-watch-install-account-20260925.json` and `physical-watch-launch-20260925.json` retain results.

Phone run 3 (`physical-phone-smoke-03-20260925`, exit 65) stopped before the Film readiness gate. Its screen recording shows a 1Password/Face ID sheet covering the app. User was asked to dismiss it; no authentication bypass or unrelated app changes were attempted. The field-replacement and missing-element fixes received quality approval but have not yet completed a hardware workflow.

The Watch UI test runner also builds with valid signing (`physical-watch-test-build-20260925`, joined exit 0). Its paired scoring test has not been executed against the real phone yet.

### Continued phone diagnosis

User dismissed the authentication sheet. Runs 4–5 still stopped before capture: XCTest supplied a {-1,-1} hit point for the visible Film tab, then an unavailable/covered guard. The tab helper now taps the validated observed center, confirms selection, and attaches only safe tab/keyboard geometry. Quality review approved the center-tap change. A known-idle app restart preceded run 6; no recording was started or removed.

Run 6 reached native scoring Connect with the correct endpoint but received the generic connection failure. The root cause remains under investigation; this is not a camera or streaming result. Run 7 adds temporary DEBUG error-domain/code-only diagnostics, but stopped before submission when iOS did not offer Select All for the secure token field. Both runs joined exit 65, with results preserved. No hardware media pass is claimed.

The original lab `device-lab-57c8N3` was explicitly stopped and joined exit 0. A fresh owned lab `device-lab-N0wYPS` has a two-hour maximum lifetime for continued diagnosis; stop and join it when device work finishes. Setup files contain private development credentials and must not be included in public logs.

### First physical phone vertical pass

Run 8 stopped at the initial tab guard because the prior failed secure edit left the app keyboard active (safe geometry confirms it overlapped tabs). The helper now dismisses only a known native setup keyboard through its own exact Done/Return key and verifies disappearance. Secure token replacement uses a bounded trailing-edge/delete/masked-length check; reviewers approved. A known-idle restart preceded run 9.

`physical-phone-smoke-09-20260925` joined exit 0. The physical iPhone recorded real camera/audio, connected and took native scoring ownership, published SRT, observed worker output, awarded HOME to 1–0, stopped live, continued local recording and exported a new MP4. Evidence: `device-lab-N0wYPS/phone-smoke-09.xcresult`, exported safe phase attachments, and `physical-media-validation.json`.

- Clean phone export: 1,199 decoded 1920×1080 H.264 frames, approximately 30 fps, 39.977 seconds, mono 48 kHz AAC.
- Proxy and mock RTMP MP4: each 890 decoded 1920×1080 H.264 frames, approximately 30 fps, approximately 31.334 seconds overall, mono 44.1 kHz AAC.
- All three fully decode video and audio with FFmpeg `-xerror`, exit 0. Proxy and mock frames visibly show HOME 0–0 then 1–0; clean archive has no overlay. Phase evidence shows local recording advancing to 39.39 seconds after publishing returned idle; final recording duration was 40.22 seconds.
- Camera content is almost black, likely an obstructed/dark view; user was asked to uncover and aim the camera at a lit scene. This pass does not qualify visible motion/detail, thermal operation, fresh-frame loss, or perceptual A/V sync. Live video begins about 1.666 seconds after the first audio timestamp; startup behavior needs separate review before sync qualification.
- Lab stopped and joined exit 0; shutdown reports no failures, worker code 0 and no forced kill. Recordings remain on the phone and local copies are retained.

Reinspection of run 6 confirms the local-network permission prompt appeared after the first connection had already failed; the test tapped Allow. Run 9 connected successfully with permission granted. Apple TN3179 explicitly describes this first-use failure and recommends waiting for connectivity. `MatchHTTPClient` now reuses an owned default session with connectivity waiting and 20-second request/resource limits, while preserving injected sessions/transports and issuing no automatic mutation retry. Focused red/green tests: four expected initial configuration failures; 49 focused tests pass after the fix. Specification and quality reviews approve. Actual fresh-permission recovery with the new configuration remains untested. Temporary DEBUG error-code UI instrumentation was removed.

### Paired physical Watch test

Added an explicitly gated physical Watch lane that shares the real phone setup/capture/export flow, receives the real paired identity and setup confirmation, observes the Watch point, and checks recording/publishing/worker output during that nonterminal score. The physical-only Watch runner holds its first point for 30 seconds before undo/away/end. Both reviewers initially identified the missing live assertion during Watch scoring; the added assertion and hold resolve that false-pass gap, and both approved. Swift parse passed; actual paired runs are in progress under `device-lab-yk1iYl` and must be joined and recorded before claiming success.

Paired phone run 1 stopped before capture when a system notification banner interrupted the Server button; Watch run 1 timed out preparing its destination. Both failures remain recorded (phone exit 65, Watch exit 70). Watch lock-state inspection reports no passcode currently required. Refreshing the current signed phone installation was necessary because `activate()` preserves an existing older app process; the new default-session change is committed as `6bcea4e`.

Paired phone run 2 stopped before capture: its 8-second Server-button readiness budget was shorter than the new 20-second failed-old-server recovery request. The Server-only wait is now 25 seconds; overall workflow/cleanup limits remain unchanged. Phone run 3 is underway. The Watch rebuild-for-testing joined exit 0, but Watch run 2 joined exit 65 before any test, timing out while enabling UI automation. User has been asked to enable Watch UI automation; no physical Watch score or paired pass is claimed.

Paired phone run 3 reached Film setup but could not edit its saved old server. Inspection shows `canChangeSetup` also rejects transient `controlBusy`; its generic message does not establish undrained outbox state. The old database already contains stopped recording sequence2 and stopped broadcast generation2 with accepted start/stop receipts. A bounded, owned API-only recovery process restored the same old endpoint/database/phone authorization; the pre-recovery database was copied for evidence. No Keychain or recordings were cleared. A current Watch install attempt timed out establishing its network tunnel; user action for Watch automation remains pending.

Phone run 10 reached editable Film setup after recovery, then failed because Select All disappeared on the plaintext endpoint. With a saved connection, periodic control polls toggle `controlBusy` and disable the whole form, destabilizing keyboard/menu state. This is a product editing defect, not a reason to keep weakening test guards. The approved minimal fix pauses new scheduled control polls only while setup is open and the model is idle and already safe to edit; explicit actions and durable recovery remain unchanged. See the focused stable-setup plan. No further full phone retry until this defect is fixed and reviewed.

Additional run09 timestamp audit: 1,199 archive frames have strictly increasing PTS with a maximum 35ms gap; both 890-frame outputs have strictly increasing PTS with maximum gaps about 34 ms. There are no gaps over50ms. This describes encoded timestamp cadence, not scene-based fresh-frame identity or perceptual synchronization. API-only reconciliation was explicitly stopped and joined exit 0; the old database and phone recordings remain intact.

Stable setup implementation adds transient sheet presentation state, a background-control wrapper and one scheduled-loop call change. New requests pause only for an open form with no capture and a true existing setup-safety guard. An in-flight poll finishes first; pending reports/commands, stop ownership and storage errors continue recovery. Explicit Connect/Retry and worker polling are unchanged. Six new tests produced five expected red assertions; the green CaptureStreamingModel/ControlPollSchedule selection joined exit 0 with 110 tests passing on the existing macOS FilmModel target/cache. Specification and quality reviews both approved, as did the small UI-test readiness/preflight changes. The current signed phone build-for-testing and explicit idle install/launch passed. Phone run11 is now testing the same old-offline-server form followed by the complete real vertical.

### Updated phone validation and checkpoint

`physical-phone-smoke-11-20260925` joined exit 0 after the current signed app was explicitly installed/launched while idle. It successfully edited the old offline capture connection, connected to the new server and completed the same recording/scoring/SRT/overlay/stop/continue/export flow. The stable-setup fix therefore has both focused regression and physical UI evidence. Latest artifacts: `device-lab-yk1iYl/phone-smoke-11.xcresult`, its phase attachments, `physical-media-validation.json`, and `terminal-recording-reports.json`.

- Clean phone archive: 1,905 decoded 1920×1080 H.264 frames, approximately 30 fps, 63.502 seconds, mono 48 kHz AAC. It now shows visible real camera content and movement; the earlier dark-scene limitation no longer applies to this run.
- Proxy MP4 and mock RTMP MP4: each 1,385 decoded 1920×1080 H.264 frames, approximately 30 fps, approximately 47.143 seconds overall, mono 44.1 kHz AAC. Both visibly show the initial 0–0 and changed 1–0 overlay. The archive stays clean.
- Important quality limit: physical publishing intentionally uses `.minimumStartup` (426×240, 350 kbps) and automatic increases remain gated. The proxy scales this live source to 1080p; its output dimensions do not qualify native 1080p live detail. The phone archive is independently captured at 1080p.
- Full A/V decode with `-xerror` succeeds for all three. Encoded timestamps increase strictly, with maximum gaps 35ms for archive and about 34 ms for outputs; none exceed 50 ms. This is not a barcode-based source-frame identity or perceptual A/V synchronization qualification. Live video starts 0.975 s after the first audio timestamp; startup and sync still need separate qualification.
- UI phase evidence confirms publishing plus worker output during native scoring and recording advancing after live returns idle. Server accepted terminal recording report sequence 2/status stopped before shutdown. The lab then stopped and joined exit 0; worker exited 0 without force, receiver finished and shutdown has no failures. All owned lab/reconciliation processes are stopped. Phone recordings and local evidence are retained.

Watch status remains separate: signed build/install/launch succeeded earlier, but no physical paired scoring test has executed successfully. The latest runner timed out enabling automation; a subsequent install also hit a network-tunnel timeout. User has been asked to check the Watch automation prompt/settings. Do not infer the timeout proves a specific switch is off. Watch scoring, route changes, wrist lowering/reopen, sustained capture, adaptive increases and remote hosts remain open.

### Owner clarification: session authentication

The user explained that the first automation attempt in a new session prompts for the phone passcode, and the unnoticed prompt caused the timeout. The earlier suggestion to check a Watch automation setting was not a confirmed diagnosis. Updated the delivery plan, handoff and device runbook: announce a new device-testing session in advance so the owner can approve the prompt directly on the phone. No device test was started for this clarification, and paired Watch acceptance remains unverified.
