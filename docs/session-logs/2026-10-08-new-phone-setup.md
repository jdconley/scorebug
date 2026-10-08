# October8: new phone setup and testing handoff

## Scope and checkout

User replaced the phone and authorized Xcode readiness/setup followed by continuation of the recording/streaming tests. Keep USB charging as the target. Reuse `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, base `1278c56`. No agents, unrelated cleanup, external broadcasts or raw archive recopy.

Artifacts: `artifacts/qa/new-phone-20261008`. New phoneUDID `00008160-000C5CAE20434036`, Xcode-reported iPhone18Pro (`iPhone19,2`), iOS27.0.1/build24A446. Old iPhone16Pro is unavailable; do not transfer old hardware qualification claims to the new phone.

## Readiness and build

- `devicectl list devices`: new phone connected with no DDI.
- Both installed Xcode versions report trusted/manual pairing over wired USB. Developer Mode is disabled and DDI unavailable. Phone is unlocked on the latest lock check; trust alone is insufficient for developer services.
- User was asked to enable Settings → Privacy & Security → Developer Mode, restart, confirm Turn On and unlock. Awaiting reply/observed enabled state; no camera/stream started.
- Installed Xcode26.2/17C52 and Xcode27.0/27A266a. Use `/Applications/Xcode.app/Contents/Developer`; active iPhoneOS SDK27.0. LAN192.168.1.130.
- Current Scorebug and UI runner build-for-testing with generic iOS destination and teamB222J9J7B8 succeeds (`build.log`, exit0). No production app changes were needed for the new compiler/SDK.
- Generic embedded profiles contain the correct Conley Chaos team but not the replacement UDID. Device-destination build with `-allowProvisioningUpdates -allowProvisioningDeviceRegistration` joined70 before compilation: destination explicitly reports Developer Mode disabled (`device-signing-build.log`). Registration cannot finish yet; verify both profiles after the enabled-state build.
- Mac initially7.9GiB free,7.7GiB after new toolchain build. Short archive Stop is small enough; combined/endurance transfer requires more disk capacity. No artifacts, simulators or original media deleted.

## Harness SDK correction

The physical harness hardcoded `Scorebug_iphoneos26.2-arm64.xctestrun` for configuration and binary-input hashing. An Xcode27 build emits `Scorebug_iphoneos27.0-arm64.xctestrun`; stale26.2 products can coexist. Added a real file-selection/hash regression with both SDK runs present; old behavior fails selecting the current run (`sdk-run-red.log`).

The runner now reads its selected `xcrun --sdk iphoneos --show-sdk-version`, validates the version and uses exactly its SDK-specific run for configuration, initial input hashes and post-configuration hashes. Malformed version/path/extra-line inputs reject. The exported hash helper preserves its legacy26.2 default for existing callers; this physical runner always supplies the observed SDK explicitly. Physical/separate-scorer focused checks16pass (`sdk-final.log`). Existing binary mutation protection remains. Physical build now targets the selected device, allows automatic device registration with the chosen team, and uses a60-second destination deadline, so new-phone signing cannot silently reuse generic profiles that omit its UDID. This is CLI setup configuration; actual provisioning/install remains unverified until Developer Mode is enabled.

## Next gates

1. Confirm Developer Mode, DDI mounted, new phone provisioning and unlocked state.
2. Install current signed app and run only `archive-stop`:8-second4K/audio, native Stop/export/playback/relaunch. Approve first-session phone automation prompt when shown. Preserve app data and prior originals.
3. After short Stop succeeds, confirm the new phone's case and moving volleyball/TV audio setup, then one600-second combined trace while USB charging. Actual1080 hold starts only after settled fresh proof. Investigate remaining proof/thermal causes from new bounded diagnostics.
4. Resolve disk headroom before30-/60-minute qualification. Reuse unchanged simulator/Watch evidence; no broad reruns.

No new hardware test pass, thermal stability or sustained1080 claim yet. Plan is goals/current status/TODO; this log owns setup history.

## Developer Mode enabled; signing authentication pending

User confirmed completion. `enabled-details.log` reports Developer Mode Enabled, phone unlocked; `ddi.log` reports usable developer services. Mac free space is now78GiB; no cleanup performed by this task. Disk headroom is no longer the immediate blocker.

First archive-stop attempt `physical-recovery-lWplvW` joined1 before camera/test initialization: build65. Found that shared `runOrdinaryCommand` still pinned Xcode26.2 despite the parent `DEVELOPER_DIR`; its SDK log confirmed26.2. Added an explicit selected-developer option while preserving existing ordinary/simulator defaults and stripping inherited laboratory switches. Regression first failed comparing the child-selected path (`developer-selection-red.log`);3focused actual child/environment/timeout-owner checks pass (`developer-selection-green.log`). The physical harness explicitly forwards its selected Xcode. No production app behavior changed and no broad suite rerun.

Direct Xcode27 device build `enabled-signing-build.log` also exits65: No Account for Team B222J9J7B8; profiles omit new UDID. This confirms a separate signing account blocker. Refreshed Xcode's manual profiles through the account UI; UI shows Conley Chaos LLC/Admin and two provisioned devices. Corrected harness retry `physical-recovery-QTioXe` records SDK27.0, but still joins1/build65 with the same account/profile error. Neither attempt starts capture.

Read-only team metadata confirms B222J9J7B8 is Conley Chaos LLC; do not substitute another developer team. Xcode account sign-in sheet is open, and user was asked to complete Conley account authentication. No password or authentication token inspected/entered. After credentials are usable, run the selected-device build to register/provision the new phone, verify both embedded profiles contain its UDID, then only the short archive-stop test. Expect first-session phone automation prompt. No capture/lab/test process is active now; all build/test attempts joined. Preserve these failures.

## Account authenticated; device profiles ready; certificate trust pending

User confirmed signing in. Archive-stop `physical-recovery-FD2Twd` no longer reports No Account, but build65 stops on a stale cached missing Watch profile path. Cleaned only this project's `ios/DerivedData/PhysicalPhone` build output with Xcode clean (`clean-signing-cache.log`,0); no recordings, original media, results or unrelated simulator data removed.

`physical-recovery-C6gI2y` then builds successfully with Xcode27. App and runner embedded profiles both verify teamB222J9J7B8 and the new UDID. Workflow65 exits before test initialization: Developer App Certificate is not trusted. iOS explicitly directs General → VPN & Device Management → Developer App. User has been asked to trust that certificate, follow any restart prompt and unlock. No fresh camera recording started; runner joined1. Retain both failed onboarding artifacts unchanged.

The next combined test setup question is also pending: moving volleyball/TV sound, USB charging, and which case is on the replacement phone. Short Stop needs only certificate/automation readiness; combined capture must wait for representative scene readiness. No broad simulator, model or Watch test rerun.

Read-only app inventory after the failed runner launch showed only the UI runner installed. Installed the current signed `live.scorebug.app` directly using devicectl (`install-app.log`,0), then verified its installed bundle/version. Both app and runner are now present; no launch or camera capture attempted while certificate trust is pending.

## Phone alert clarifies online verification failure

User reports no Developer App entry in VPN & Device Management. Direct actual-app launch also denies with the generic invalid-signature/entitlements/untrusted-profile security error (`app-launch-trust-check.json`); that error alone does not establish a missing manual trust action. User supplied a screenshot showing “Unable to Verify App,” Internet connection required for “Apple Development: John Conley (X54GG58K58),” and a connected VPN. Online certificate verification is now the explicit phone-side failure; VPN interference is a hypothesis, not a confirmed cause. Asked user to cancel, temporarily disconnect VPN and reopen Scorebug on Wi-Fi or cellular. Do not repeat the absent Developer App menu instructions.

Read-only checks: app `codesign --verify --deep --strict` passes. App and runner signed entitlements match the profile wildcard application identifiers/team/get-task-allow; runner keychain group matches allowed team wildcard. Both profiles include new UDID and expire October8,2027. Both actual signing leaf certificates are contained in their profiles, identify Conley Chaos LLC/B222J9J7B8 and expire September9,2027. No local signing mismatch or expiration found; local verification does not prove Apple online verification succeeds. No certificates revoked/created, no app uninstalled, no capture started.

Apple’s public manual-trust article concerns enterprise apps, so its menu instructions should not have been treated as guaranteed for this Xcode development install. It documents online verification and access to ppq.apple.com: https://support.apple.com/en-us/118254. Await phone network-check result, then confirm launch and retry only short archive-stop. Representative scene/case question remains pending for the later combined capture.

## Device-attestation failure isolated

User reports same alert after VPN-off retry. User declines cellular tests; keep Wi-Fi. Apple explicitly documents PPQ check-in for newer development teams, including development/ad-hoc apps: https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates/. Mac HTTPS ppq endpoint responds404 with successful TLS; not proof phone verification succeeds.

Started focused connected-device Console logs and launched actual app twice. SpringBoard reports Profile Needs Network Validation. `online-auth-agent` asks `mobileactivationd` for client certification, then fails locally obtaining device identity: Failed to create BAA info → Failed to create reference key attestation → Failed to copy attestation key → Failed to copy system key (2), MobileActivation.ErrorDomain/-1. Authorization attempt cannot proceed. Same chain reproduced15:17:22 and15:18:51PDT. Device unlockedSinceBoot=true/passcodeRequired=false; Developer Mode/DDI remain ready. Underlying cause of unavailable device system key is unknown; do not assert defective hardware or reset/erase the device. Excerpts saved to `new-phone-20261008/verification-attestation-observation.txt`; launch JSONs retained.

Full devicectl sysdiagnose could not collect without host password; cancelled rather than request credentials. No full personal diagnostics uploaded or collected. Console streaming paused after reproduction. Asked user to restart phone once, unlock by passcode and retain USB/Wi-Fi; next focused launch checks whether activation/verification services recover. No camera capture/test or certificate changes. User network preferences take precedence; no further cellular request.

## Restart clears launch gate; fresh Stop check running

User restarted and unlocked. First CoreDevice launch timed out while reconnecting. DDI then reports usable, lockState passcodeRequired=false/unlockedSinceBoot=true. Initial immediate retry was still denied, but subsequent focused actual app launch succeeds (`post-restart-logged-launch.json`, exit0, process583). Restart/reconnection preceded recovery; exact mechanism is not proven. No cellular test performed. No certificate/profile replacement needed. Console verification streaming paused before camera work.

Started only archive-stop with current Xcode27/new UDID. `physical-recovery-AYrxbF`: build succeeds and UI runner starts15:22:25PDT. Fresh4K/audio Stop/export/playback/relaunch and native media collection remain in progress; no pass claim yet. No streaming lab or long capture started.

## Fresh Stop records successfully; scan-readiness test race

`physical-recovery-AYrxbF` joins1/workflow65 after actual9-second4K/audio recording and Stop. New archive18CFD610-74F6-4AB4-BA5D-3C07A96EA7D2 is shown Completed; app remains alive. Full export/playback/relaunch and media qualification did not run, so fresh Stop lane remains failed. Failure: export control unavailable/disabled after its8-second tap-readiness wait. Failure screenshot explicitly shows Checking saved recordings and disabled Export MP4, while subsequent actual screen shows scan finished and Export enabled. Model intentionally disables export during integrity scans; entering Recordings starts another scan. The restored phone contains20prior recording directories, including original hour33D2FF99; do not delete any to accelerate tests.

Minimal automation correction adds the existing90-second archive-scan readiness budget for the exact newly completed recording's export button before tapping. This preserves production integrity checks and capture settings; no app behavior change. Existing affected physical test supplies the failing reproduction; retry `physical-recovery-WYC2Bj` (session34389) builds successfully and is running. Reuse all unchanged suites.

## Fresh short4K/audio workflow passes; AAC validation corrected

Second attempt `physical-recovery-WYC2Bj` exports and plays successfully, then the relaunch check fails looking up isEnabled before the asynchronously loaded recording row exists. Added existence guards before enabled queries in both short and combined relaunch checks. Added the same90-second scan-ready wait before combined export to avoid the already observed restored-history race. No production app behavior changed.

Third affected-only attempt `physical-recovery-6GJcoi` joins0: workflow passes recording, Stop, native export/full decode, playback and relaunch. Exact recording38C4425C-3794-4F9F-897C-89D9079BE8B1, MP4 copied without deleting or recopied raw originals:36,862,146bytes,2884Kframes,460,736decoded audio samples,9.6s. Archive-only runner intentionally does not qualify streaming/three saved outputs.

Additional exact-file packet correlation initially fails because the validator includes2,112declared AAC priming samples:452packets contain462,848samples, while AVFoundation returns460,736playable samples, matching stream duration460,736ticks. First packet explicitly declares Skip Samples=2112. Added two focused regressions for multi-packet priming and declared tail padding; both fail before the fix. Validator now applies only explicit FFmpeg Skip Samples metadata, carries start priming across packets and preserves other gaps/sample-count checks. Source: https://ffmpeg.org/doxygen/7.0/group__lavc__packet__side__data.html. Five focused Python tests pass, including omitted packets and a timestamp-gap control. Saved probe failure directory retained; corrected exact-file `short-saved-media-aac/result.json` passes all7gates:3840×2160 H.264/AAC,288frames, continuous audio, normal30fps cadence, A/V ends1.333ms. No second full native decode needed.

User confirms phone pointed at moving volleyball/TV sound, USB connected, and the replacement phone has no case. This is the intended new-phone qualification configuration; earlier iPhone16Pro clear-case baseline is separate. Next: one600-second combined trace after current checkpoint commit, then diagnose its first failing gate before longer tests.

## Combined setup blocked by missing relay image

Checkpoint committed8d7e138. First600-second combined setup `physical-recovery-i1M67t` joins1 before UI workflow/capture: selected phone build passes, but Docker has no local `scorebug/ingest:drain-v1` image. Docker Desktop context is desktop-linux/server29.2.1; image inventory is empty. Lab `device-lab-ICC4GN` startup cannot pull the private/local tag; cleanupFailures empty. Attachment collection64 is secondary because no workflow result exists. No recording/streaming started.

Rebuilding the documented maintained relay via `docker compose -f docker-compose.dev.yml build ingest`, session2114, log `new-phone-20261008/rebuild-ingest.log`. Uses pinned upstream/source checksums and cumulative patches; no historical image overwritten because tag absent. LAN remains192.168.1.130. Next: retry same combined setup after image build completes; no app rebuild/unchanged tests beyond harness incremental build.


## Relay rebuilt; password-saving offer blocks setup before capture

Relay build session2114 joins0; maintained `scorebug/ingest:drain-v1` is available. Combined retry `physical-recovery-1MwykU`/session14447 joins1 after backend readiness but before any capture. After native Score joins HOME/AWAY and takes control, Film Setup is blocked by the observed 1Password Save Password? sheet with Not Now/Save actions. Screenshot `new-phone-20261008/combined-setup-failure.png` proves capture off. Lab `device-lab-1N9IFX` cleans up without failures; no live jobs or capture remain. This is setup interference, not a failed 1080p hold.

Added a physical-test-only helper to decline precisely the observed password-save offer: exact title/body plus Save and hittable Not Now controls. Checks app and SpringBoard accessibility surfaces, never accepts saving or enters credentials. Called before reveal scrolling, avoiding attempts to scroll behind this sheet. Existing failed combined workflow supplies reproduction; next affected-only run verifies the change. User asked to dismiss the current offer manually as well. User reconfirmed no case; USB charging/moving volleyball/audio remain the qualification setup.


Combined retry `physical-recovery-gPzChR`/session30554 joins1 before capture; cleanupFailures empty. No password-save dismissal attachment was emitted, so that helper is compiled but not yet exercised. Film connection and controller preflight completed. Failure screenshot `new-phone-20261008/combined-second-setup-failure.png` shows Checking saved recordings and disabled recording/quality controls; the 4K selector was unavailable. Added the same bounded90-second scan-ready wait before combined 4K selection. No integrity check removed or archive deleted. Next affected-only retry verifies this known readiness race, not an adaptive policy change.

Scan-ready attempt `physical-recovery-wAIojJ`/session71044 joins1 before UI: Docker relay binding127.0.0.1:56587 fails with address already in use. Subsequent read-only lsof finds no listener; cleanupFailures empty. No capture or app workflow ran. Retrying once with newly allocated ports; no unrelated process killed.

Fresh-port retry `physical-recovery-QXrIHg`/session53051 joins1 before capture; cleanup[]. Film start is reported enabled transiently after app activation, but screenshot still shows integrity scan and disabled quality selector. XCTest logs also report an invalid activation point for the 4K segment. Require the explicit scan text to disappear and recording readiness to remain stable for1second, then tap the bounded observed selector center (existing physical tab pattern), and await selected4K/audio description. Preserve all scans/media; no production change.

Retry `physical-recovery-oUR0C0`/session98050 starts successfully: selected4K/audio and recording-requested milestone. Stable scan disappearance/observed-center correction gets past the previously failed setup. Combined ramp/hold/media gates pending.

Combined `physical-recovery-oUR0C0` joins1: actual4K recording advances34.67s, streaming never reaches local publishing, failure Camera did not publish to the LAN worker. Worker transitions waiting_source→idle and reports reporting_unavailable at22:46:57Z. Uplink has six packets outside diagnostic capture window, no established receiver session. Failure cleanup stops recording and joins lab without failures. No ramp/hold samples collected. Existing harness discarded relay logs and API runtime errors; added private per-lab control-plane.log and relay.log before cleanup to locate this startup failure on the next focused attempt. Node syntax checks pass; no production policy change.

Instrumented backend retry `physical-recovery-7bb9KA`/session81234 joins1 at the same Camera did not publish gate; cleanup[]. API remains up, only retained relay error path configuration not found (provisioning GET404 can be expected), no worker-report-unavailable warning in this retry. Therefore backend logs do not prove a server outage. Added debug physical startup-stage/error-type/domain/code diagnostic, with bounded server code only and no localized text/URLs/credentials/bodies, to identify the exact failing phone operation. Recording and transport behavior unchanged. Next focused retry collects the scalar.

Startup-stage attempt `physical-recovery-NTQziR`/34953 and common-error attempt `physical-recovery-C193sP`/3048 both join1 at prepublication gate; cleanup[]. Neither newly instrumented JSON appears in device QA inventory. Built Scorebug.debug.dylib contains new controlFailure/streaming-failure strings, Debug/iOS flags correct and xctestrun target path correct. Explicit `devicectl device install app` of current build succeeds (session54011 joined0) without uninstalling/purging data. Stale test target install is a hypothesis pending the next controlled retry; do not claim it as root cause yet.


## Startup localized to Docker LAN UDP path

Explicit-install retry `physical-recovery-0NbnOK`/session3232 joins1, cleanup[]. Newly added diagnostics now appear: publisherStart raises PublishingSessionError.startFailed; earlier control requests time out (NSURLErrorDomain/-1001). Actual4K recordingEB85D657 runs~36s, thermal nominal throughout. Native UDP forwarding snapshot receives/forwards3handshakes/276bytes, zero reverse packets and no injected/overflow/oversize loss. No receiver session or media-quality downgrade exists in this attempt.

Isolated Mac-only relay probe with the maintained image reproduces LAN-bound Docker UDP failure: FFmpeg caller to192.168.1.130:60995 fails after3s; debug relay sees no connection. Rebinding the same relay/image/config to127.0.0.1:60995 permits the same FFmpeg caller (exit0; relay opened/EOF). Temporary owned probe container removed. Evidence: `relay-transport-lan.log`, `relay-transport-loopback.log`, `relay-transport-loopback-relay.log`. This local comparison proves the failing path on this machine; no claim about Docker-wide cause or phone networking.

Physical recovery/native-worker lane now binds the Docker relay to loopback, advertises loopback to the local worker, and forwards from the existing LAN Node proxy to loopback. The phone still receives the LAN proxy endpoint. Other device-lab lanes/container workers unchanged. Physical harness explicitly installs the current built app before running tests, preserving its data container; explicit reinstall was required to obtain current diagnostics, exact XCTest caching mechanism unproven. Node syntax checks and diff check pass. Next single combined retry verifies actual stream/ramp and hold; no adaptive safety guard changed.

Loopback retry `physical-recovery-UXBE2L`/17450 joins1 before capture: Streaming setup is correctly locked pending reconciliation with the previous temporary backend (failure screenshot saved-connection-block.png). Restored prior owned API from `device-lab-1S4bCE` SQLite and original phone installation credential at its saved endpoint, session23504. No relay/camera started, no Keychain clearing or media deletion. New combined retry proceeds while this API permits ordinary pending-stop/report reconciliation; stop restored API after the new connection is established.

Reconciled retry `physical-recovery-psymmJ`/33476 reaches recording-requested, local-publishing-observed and initial-encoder-ack. Loopback correction removes the previously reproduced startup failure. Prior API restoration session23504 stopped after this fresh Film connection; preserves its SQLite state. Progressive ramp/hold/output evidence pending.


## Native 1080 ramp passes; combined hold sampling boundary corrected

Reconciled `physical-recovery-psymmJ`/33476 joins1, cleanup[]. Actual app publishes, worker produces output; normal360/720/1080 increases each acknowledge/probate/confirm. Native score changes run. Before any confirmed1080 hold starts, direct XCTUnwrap of recoverySample gets nil because the preceding proof read was inside the existing2-second throttle; this is a test boundary bug, not an observed downgrade. Cleanup completes stream Stop, archive continuation and recording Stop. Exact3E9CEA02-92F2-4A6A-ABA5-3879E108AE28 native full export passes (`nativeExport:true`); sustained hold remains failed/unqualified.

Changed only initial combined hold sampling to await the first available sample with the existing bounded recoveryWait (15seconds), then immediately require its original sustains1080 proof. It does not wait for invalid proof to recover and changes no freshness/ownership/resource guard. Next affected-only600-second retry verifies this boundary and the hold. All preceding failed artifacts retained.

Completed short native ramp resources from3E9CEA02:216.8s capture, thermal0/nominal throughout, maximum footprint108.3MiB, average0.413CPU cores, zero late/out-of-buffers/discontinuity/unknown capture drops. Camera pressure nominal during capture; initial/terminal unknown retained. Native full decode6468video frames and10349504audio samples. This is short-run evidence only. Corrected retry `physical-recovery-3CIIBa`/session38419 reaches capture/local publication/worker output; ramp/hold pending.

Corrected `physical-recovery-3CIIBa` reaches confirmed1080-hold-started and first SCOREBUG_HOUR_PROGRESS seconds=0 quality=1080p30:6000000 after normal360/720/1080 acknowledgment/probation/confirmation. Initial throttled sampling boundary is now exercised successfully.600-second hold is running; final resource/geometry/native export/three-output media gates pending.

`physical-recovery-3CIIBa` reports every30-second hold observation at1080p30:6000000 through570s, then confirmed1080-hold-complete/hour-hold-complete. Stream Stop and archive continuation finish, recording Stop requested. One live bounded resource snapshot shows active charging (batteryState2), thermal fair1, nominal camera pressure, footprint~134–141MiB. Final closed resource, geometry, native export and saved-media checks pending; no overall pass claim yet.


## Laptop-move stopping checkpoint

User requests a stopping point. `physical-recovery-3CIIBa`/38419 joins1 with
workflowPassed:true, mediaQualified:false, nativeExport:true, cleanupFailures[].
Native600-second1080p30/6Mbps hold, scoring, stream Stop, archive continuation,
recording Stop, full native export/decode, playback and relaunch pass. Exact
recording00D593CC-FED7-4B08-A13A-5771ADF72BAF/export remain preserved on phone.
Labdevice-lab-kHStcT closes receiver/worker without shutdown failures; current
Docker/process inventory confirms no owned capture/test services remain.

Offline qualifier fails before geometry/resource/saved-MP4 qualification: it picks
a pre-hold polling sample labeled confirmed1080-hold-started instead of the
accepted milestone.sampleIndex. First read3983.135–3983.209; accepted baseline
3985.230–3985.320. Preserve rejection evidence; fix index-range selection with a
regression next session and reuse this capture, without weakening proof guards.
No native MP4 transfer occurred yet; proxy/mock files and QA/xcresult are local.
Closed resource trace reports charging throughout, thermal states0/1 only and
maximum141.3MiB footprint. These observed scalars do not replace final resource
qualification. Full saved-media and30/60-minute endurance remain pending.
No new capture, transfer or extended debugging started after the stop request.
