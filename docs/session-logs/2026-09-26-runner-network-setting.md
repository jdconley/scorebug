# Physical runner Local Network inspection — September 26

Starting commit `bcf1707`; plan `001f544`. The prior turn made progress: current signed phone/Watch builds passed, the Watch runner launched, and its automation initialization failure was isolated before capture. No live test process remained. Watch prompt response is pending; no unchanged paired retry.

## Diagnostic scope

Physical recovery is separately blocked by the runner's measured `localNetworkDenied`; Scorebug itself connects. The runner Info.plist already contains NSLocalNetworkUsageDescription and the expected bundle/name. Mirroring was inspected but unavailable while the phone was in use; no attempt was made to lock the phone or change its state.

Added a hardware-only `testPhysicalRunnerNetworkSetting` guarded by `SCOREBUG_PHYSICAL_NETWORK_SETTING=1`. It checks that capture is idle, navigates normal Settings UI, reads the exact ScorebugAppUITests-Runner entry, emits only bounded normalized scalars, and restores Scorebug. It never taps permission switches or approves prompts. Unrecognized navigation remains inconclusive. Existing test lanes retain their default behavior.

Root launcher: `artifacts/qa/run-runner-network-setting-20260926.mjs`. It uses existing tested private-xctestrun configuration and input hashing, builds the current signed phone target, runs only this leaf, and conservatively avoids claiming joined success on any failure. No lab starts. Plan and read-only scope: [diagnostic plan](../superpowers/plans/2026-09-26-runner-network-setting.md).

## Validation

Swift parse and `git diff --check` passed. Current signed phone Debug build-for-testing joined0 (`artifacts/qa/runner-network-setting-build-20260926.log`). Spec review approved Swift `b5ea65f3a98f4e2407b49db182923a0fc3a71648` and launcher `9b62b96447c4d7e1ce6fa6f826b88889cd486f43` after correcting the launcher's unconditional joined claim. Hardware result remains pending.

## Hardware diagnosis

Both independent reviews approved the initial source. Run `runner-network-setting-wdpOOk` on `c70208a` executed the physical phone test, then failed at19.27s: querying Scorebug alerts after Settings activation triggered XCTest `kAXErrorServerNotFound`. The framework exception bypassed Swift deferred evidence/restoration. Root activated Scorebug with documented `devicectl device process launch` without `--terminate-existing`; result confirmed the original PID38707 and no termination. No camera or permission mutation occurred.

Correction `5bd57ea` queries app alerts only where the app reports runningForeground, retaining the separate SpringBoard/deadline guard. Both reviewers approved blob `0f8ad946bfbc4f488529437da193032baff7031b`. Run `runner-network-setting-RYno6J` built and ran, failed safely at2.29s because Settings exposed no hittable table/collection at the initial snapshot. Its JSON explicitly records `settingsVisited:true`, `scorebugRestored:true`, `entryFound:false`, `value:unknown`; this is not evidence that the permission entry is missing. Both process handles joined exit1, and no lab ran.

The final bounded correction waits at most8s for a hittable Settings table, collection, or scroll view, preserving prompt/deadline checks and forbidding app-wide gestures. Spec review approved blob `624eb05f6236189a978cf9a1eb5d9a8983d9ccd9`. One further measured attempt follows quality review; do not repeatedly tune navigation if it remains inconclusive.

## Final result and handoff

Quality review approved the same final blob. Run `runner-network-setting-InECny` on `4209e33` built successfully and ran the exact physical leaf, but the recognized Settings list never became accessible within8s. Test failed safely at11.56s and root process83445 joined exit1. Attachment `64A4277B-B0C4-49AF-94F1-F6CFB3BD0EA6.json` confirms `scorebugRestored:true`, `settingsVisited:true`, `value:unknown`, phase `settings-navigation`. Eight source/binary/configuration inputs were independently reverified unchanged afterward.

No permission state was established, no setting was changed, and no media was captured. Do not describe this as a missing/disabled runner entry or a passing inspection. No more automated Settings-navigation retries are planned. The user's existing request to check the runner switch manually remains pending, alongside the separate Watch automation prompt. The diagnostic remains opt-in and excluded from default functional acceptance. Current code and signed build are valid; the physical adaptive-recovery and paired-Watch acceptance gates remain open.
