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
