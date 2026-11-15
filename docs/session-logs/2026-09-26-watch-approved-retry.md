# Paired Watch retry after automation approval — September 26

Started from clean `98fe93c` on `codex/local-validation`. User reported the prompt approved and both devices ready. No application or streaming-policy changes in this session.

## Results

- Fresh `devicectl device info lockState` succeeded: `passcodeRequired:false`, `unlockedSinceBoot:true`. Evidence: `artifacts/qa/watch-readiness-user-ready-20260926.json`.
- Device-targeted Watch build exited70 waiting for Xcode preparation. Its suggestion that the Watch “may need” unlocking is not evidence of a current lock. Subsequent CoreDevice details reported connected, paired, developer mode enabled; `xcdevice list` reported both phone and Watch available.
- Signed generic-device Debug `build-for-testing` passed for both ScorebugWatch and Scorebug using Xcode26.2 and team B222J9J7B8. Exact commands/results: `artifacts/qa/paired-approved-generic-builds-20260926/`. This avoids requiring device preparation during compilation; the real-device test still must establish automation normally.
- Ran the existing exact paired leaves through `artifacts/qa/run-physical-paired-approved-20260926.mjs`, adapted from the prior ready launcher with current build/source provenance. Run `physical-paired-live-KdfdC1`, lab `device-lab-IxEHXO`. Watch runner launched at09:08:36, then failed initializing UI automation at09:09:37: `XCTFuture Code1000`, “Timed out while enabling automation mode.” Exit65. No XCTest body executed and no phone workflow or camera capture started.
- Root process91214 joined exit1. Lab shutdown joined. All14 recorded execution inputs were rehashed after joining and remained unchanged (`post-run-input-verification.json`). Neither paired workflow nor media qualification passes.

## Interpretation and next action

The previous unreachable-device boundary was crossed, but the Watch automation service remains a distinct blocker. User was asked whether a new prompt is visible and to approve it if shown, or report no prompt. Existing authorization remains acknowledged. Do not repeatedly ask to unlock the Watch or rerun unchanged tests.

An [Apple framework engineer's reply](https://developer.apple.com/forums/thread/831768) calls similar unlocked-Watch preparation errors a possible bug and suggests trying Xcode27. This is context, not proof of this failure's cause or a tested remedy. No toolchain switch, privacy reset, re-pairing, device reboot, or diagnostics upload was performed.

After an actual automation state change, retry the same bounded paired workflow. If no prompt exists, investigate automation initialization itself before another capture. Physical recovery runner LAN permission and a lit moving camera scene remain separate pending prerequisites. Keep full vertical and progressive recovery acceptance open.
