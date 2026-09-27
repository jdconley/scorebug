# Simulator-first delivery — September 26

## Direction

The owner requested faster iteration, fewer repeated tests for small edits, and simulator coverage of the complete feature set before further hardware testing. Hardware retries, physical pairing recovery and signing work are deferred. Use the existing authoritative `codex/local-validation` checkout.

## Working approach

- Batch related changes. Run focused regression checks for changed behavior; run broader checks at integration checkpoints.
- Reuse incremental simulator builds. Do not rebuild/sign physical or Release apps for each small edit.
- Review coherent batches rather than running two separate reviews for every minor change.
- Keep full media verification for completed end-to-end runs. Never call an unexecuted or failed workflow green.
- Preserve hardware pending state and old failed artifacts. No more unchanged WatchConnectivity simulator retries: retained runs fail companion registration with WCError7018 before setup.

## Reassessment

Read-only product audit confirms native match creation/discovery/join, capture/scorer separation, durable scoring, Watch routing/recovery, archive recovery/export, configurable overlays/fonts/encoders and RTMP/MP4/both outputs exist. Open plan items often mixed implemented functionality with uncompleted qualification. The delivery plan now separates them.

Immediate batch:

1. Explicit `watch-direct` simulator vertical: real phone archive/publisher, native Watch, API, proxy and mock destination; fixture supplies only a server-issued setup offer because the installed simulator cannot complete companion registration. Preserve the existing real-companion lane and do not claim WatchConnectivity qualification. Relaunch Watch without setup injection while the phone remains live.
2. Progressive transport congestion descends directly to minimum through the existing guarded decrease path. Existing720p evidence shows first loss before the controller reacts, followed by two costly replacements; avoid the intermediate360p step while preserving thresholds, ownership, thermal policy and measured upward recovery. Initial packet loss remains a separate limitation.
3. Complete separate native creator/scorer plus filming phone workflow and process-restart acceptance, then package local worker operation.

## Evidence and limits

Prior exact physical runtime checkpoint is9c22e0c; docs checkpoint9af24df. It passed46 Watch model and37 focused tests and signed builds, but the latest two Watch inspections never entered their bodies because Xcode lost the destination. That hardware blocker is deferred, not fixed.

The existing simulator real-companion failure is `ordinary-native-LhOSEV`; its three video outputs remain continuous, but no Watch offer or command was delivered. Do not rerun the same experiment to rediscover that limit.

## Implementation batch ready

Implemented progressive transport-pressure direct descent to minimum (thermal-only/legacy unchanged); affected Core checks pass. Added `watch-direct` with a loopback-only API, post-phone-readiness issuance of a real server pairing, private simulator fixture delivery, native Watch scoring and a relaunch without setup injection. Existing real-companion/physical lanes remain separate. Focused lane checks and syntax pass. One batched integration review found no concrete blockers.

Added native macOS worker service helper and runbook (explicit plist/check/run/install/uninstall, protected configuration, RTMP/MP4/both, upgrade/rollback/backups). Focused generation tests and plist lint pass. No persistent service was installed or loaded. All build/test jobs joined before simulator capture. Evidence: `direct-minimum-transport-validation-20260926`, `watch-direct-validation-20260926`.
