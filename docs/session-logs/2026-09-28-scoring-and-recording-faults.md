# Pending scorer takeover and native recording faults

Start: `codex/local-validation`, `93279ef`, clean. Previous turn made verified progress. Simulator-first; no hardware, long stream repeats or broad suites.

## Native pending-command takeover

Extended the existing loopback fault workflow with `--pending-takeover --ui-only`. After the real API applies the native point, a second fixture actor takes over. The real server rejects one old-owner command (`scorer_changed`) and one old-revision command (`revision_conflict`) without changing the score. The first native app loses its reply, relaunches offline with its actual persisted outbox, recovers the original receipt, observes the other owner with scoring disabled, explicitly takes over, undoes and ends.

`native-scoring-recovery-Ff9bG1`: one native iPhone14/iOS26.2 XCTest passes in60.47seconds. SQLite contains exactly seven intended commands: one accepted point, two accepted takeovers, two rejected stale attempts, undo and end. No duplicate accepted point. Original receipt GET succeeds. Data collection now succeeds after booting the simulator Xcode shut down; persisted `pending-command.json` is retained. The owned simulator and API are cleaned up. Two focused proxy checks pass.

The first attempt `native-scoring-recovery-5cbiS3` failed in the fixture: stale-command HTTP409 was incorrectly expected to be200. A subsequent resume assertion escaped the stdout callback and bypassed runner cleanup. The fixture expectation was corrected; callback failures now reject the running operation through its normal cleanup path. The original Xcode process was inspected live, then independently confirmed terminal before cleanup. Its test-owned app data was copied and its exact simulator deleted; `scoped-cleanup.json` records this. No unrelated process/device was stopped. Failed evidence remains unchanged.

Peer takeover is a real API actor, not a second UI process in this scenario. Separate native two-phone/Watch authority workflows already have their own evidence. This checkpoint proves the pending native owner's restoration and permission changes against that concurrent server state.

## Recording fault batch

Added `NativeRecordingFaultTests/testRecordingFaultRecovery`: source interruption, simulated low available storage, and writer backpressure in one native full-app test. Each starts ordinary offline recording, observes automatic failure, recovers and exports the latest saved recording. Source interruption uses the existing240-frame fixture event. Storage injects the actual writer's capacity probe after8seconds; queue pressure returns false from the real sink wrapper after8seconds, allowing the normal bounded RecordingSession queue to fail. No disk is filled and no recording result or export is mocked. All fault selection is confined to Debug simulator setup; ordinary/default and physical-camera paths are preserved.

`recording-faults-20260928-fixed`: XCTest passes all three cases (67seconds reported test activity;73.76seconds result envelope). Data preservation and owned simulator cleanup pass. Each of three native MP4 exports fully decodes to H264/AAC,180consecutive source frames starting at0 at30fps, no audio timestamp gaps, A/V end difference28ms. Each committed segment's sequence/metadata/byte count/SHA256 passes. All original source segments and exports are retained. Source interruption at frame240 leaves a measured2-second tail loss; storage/queue runs preserve6seconds before their8-second fault deadlines, without claiming exact last-callback tail timing.

Initial compilation needed an explicit Sendable optional closure type. That failed build performed no capture; its empty owned simulator was reused for the corrected batch. A generic follow-up build attempted the unavailable x86_64 SRT simulator library; the explicit arm64 incremental build passes. Existing unrelated Swift concurrency/exhaustiveness warnings remain. No full UI rerun for a static-function-to-Sendable-closure spelling change. All capture/build/analysis handles joined; no remaining owned simulator/process.

The native test can be selected using `xcodebuild ... -only-testing:ScorebugAppUITests/NativeRecordingFaultTests/testRecordingFaultRecovery` on an installed simulator. Exact owned-run/collection and media verification scripts/logs are in `artifacts/qa/recording-faults-20260928-fixed/`. The first compile failure is retained in `recording-faults-20260928/`. Native scoring command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer SCOREBUG_IOS_DEVICE_TYPE=iPhone-14 node scripts/test-apple.mjs --pending-takeover --ui-only`.

## Remaining scope

These recording faults ran offline. Publishing cleanup/restart through a source interruption still needs the real streaming workflow. Severe-collapse live-media quality, sustainable profiles, service operation, consolidated acceptance/CI matrix and deferred hardware/external acceptance remain open. Reuse successful local archive/scoring checks rather than repeat them.
