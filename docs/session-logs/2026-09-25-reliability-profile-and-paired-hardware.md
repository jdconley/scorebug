# Reliability timing and paired hardware

## Scope and starting state

Continue the complete native recording/scoring/streaming vertical after the platform research. Start: `eff8465`, `codex/local-validation`, `/Users/jd/.codex/worktrees/scorebug-local-validation`. The previous research turn made progress: published evidence changed the next action from reducing buffers solely to meet 1.5 seconds to comparing deliberate broadcast timing profiles. The full goal remains active.

The physical smoke has priority. In parallel, implement coherent diagnostic timing profiles with separate media and report freshness. No production adaptation qualification or old-evidence relabeling is implied.

## Physical preparation

- Fresh device inventory: iPhone 16 Pro (`iPhone17,1`), iOS 26.7, connected; Ultra 2 (`Watch7,5`), watchOS 26.6, initially available/paired. LAN `192.168.1.130`.
- Announced the possible first-session phone passcode prompt; passcode stays on the device. Asked that the camera face a lit scene and Watch remain unlocked nearby.
- `physical-research-phone-build-20260925`: signed `build-for-testing`, exit 0. Fresh process inventory found no Scorebug process; explicit current app installation `physical-research-phone-install-20260925` exited 0.
- `physical-research-watch-build-20260925`: exit 70, destination preparation timed out while connecting. Retained this failure. A subsequent device-details query established a connected developer tunnel, enabled developer services, and a lock query reported no passcode required.
- `physical-research-watch-build-connected-20260925`: signed build-for-testing exited 0 after that connection-state change. No repeated launch of a still-running process.
- Builds use Xcode 26.2 and Conley Chaos LLC `B222J9J7B8`. Phone and Watch executable hashes, model/OS and source checkpoint are in `artifacts/qa/device-lab-IWDkV4/build-provenance.json`.
- Fresh lab `device-lab-IWDkV4`: VideoToolbox proxy, private-LAN scoring/SRT, loopback mock RTMP recorder, optional proxy final-overlay MP4, 1800-second upper duration. Credentials loaded from its private setup file into the phone test's environment; not placed in command arguments.
- The Watch runner starts first. Both tests use the already-built `eff8465` products; concurrent experimental timing edits do not qualify as hardware-tested code.

## Timing contract decision

The current delivery scheduler waits for capture-window end + decoder budget + 250 ms, while consumers separately expire capture windows at two seconds. Increasing only the decoder budget would make the evidence expire before it can be consumed.

Proposed experimental profiles retain a 500 ms consumption allowance: decoder budgets 1500/2000/3000 ms, maximum capture-window evaluation ages 2000/2500/3500 ms. Keep completed-window report age at 2000 ms, delivery/cadence samples at 250 ms, and observed decoder stalls at 1000 ms. These are explicit test policies, not industry standards. Candidate/probe/authority/lease deadlines remain independent.

New profiles must be accepted only on the complete owned diagnostic route and bound to trusted host selection in all relevant audit envelopes. Old runs keep their original strict settings. The unfinished whole-history recovery qualifier must continue refusing a full pass.

## Results and next work

- Watch runner `41571` joined exit 65: the runner failed to initialize UI testing because enabling automation mode timed out. Test case never began. The phone runner was deliberately not started. The user's earlier passcode-prompt explanation is relevant; a new async question requests approval directly on the phone and an unlocked nearby Watch. No retry until the device state changes or the user reports readiness.
- The unused lab was stopped by SIGTERM to its exact observed process. Root handle `33924` joined exit 0; its shutdown evidence is retained. This attempt produces no new physical media qualification.
- The preliminary export listing used the wrong `Documents/Recordings/Exports` path and failed; retained logs document it. The correct `Library/Application Support/Scorebug/Recordings/Exports` listing succeeded. Export verification must select the newly created export, never an old recording.
- A source inspection confirms real-camera adaptation remains unimplemented: `PublishingQualityDriver.fixture` returns nil outside debug simulators. Added an explicit real-camera integration/verification checkbox to the delivery plan so the fixed-profile physical smoke cannot close progressive streaming.

Timing implementation is in progress. Review and verify the full propagated contract, run fresh comparisons, and finish the complete owned recovery verifier before enabling the controller for real-camera capture. Physical retry needs a fresh lab and the pending automation prompt resolved. A successful UI workflow alone does not prove three-output media acceptance.
