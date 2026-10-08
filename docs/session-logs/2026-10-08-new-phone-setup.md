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
