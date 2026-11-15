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

## Direct Watch simulator checkpoint

`ordinary-native-UFjmr8` atb341b94 passed both selected native workflows and durable command checks; cleanup completed. The Watch took control, scored HOME, undid, scored AWAY, relaunched without a setup fixture, recovered its pairing/score and ended the match while the phone recorded/published. Setup transport was explicitly `simulator-fixture`; scoring used real direct HTTP. This is not WatchConnectivity/radio qualification.

The native export contains4978 consecutive frames at30fps with no audio timestamp gaps. Both live outputs contain the same4544 consecutive source frames at30fps with no audio timestamp gaps. The archive continues280frames after live output. Independent A/V waveform and visible score checks are pending; frame/decode checks passed. The launcher preserved84 archive segments and verified all hashes.

Applied the prepared native-created two-phone simulator lane. It starts with an empty API, creates the match through scorer B's native UI, reads back the exact created identity, then launches filming phone A for discovery/takeover/archive/publishing while B scores and undoes. It retains both containers, verifies scorer B remained camera-free and joins both jobs before cleanup. Reuses the existing incremental simulator build directory. Focused affected Node checks:40passed. Full role/media execution is the next checkpoint.

## Native-created phone workflow and deployment docs

`native-created-simulators-opRrou` atf3428a0 passes both native workflows, exact native creation/ownership readback, all six scoring receipts, stream start/stop, independent archive continuation/export, camera-free scorer inventory and cleanup. The initialqJLOHD attempt failed before capture because the keyboard obscured Create; the retry dismisses that keyboard and failure diagnostics now tolerate absent score controls. No media stack changes or unrelated suite reruns accompanied this test-interaction fix. The source archive has3382 consecutive30fps frames and no audio timestamp gaps; remaining offline checks are running.

Strict Watch-run coverage needs correction: audio ENDS454ms AFTER video in both live outputs; it is not missing terminal audio. Archive end alignment passes. Native match end immediately retires the relay path and worker assignment before the phone separately polls and drains; interrupted video tail is a leading hypothesis, not yet proven. Full live waveform/score checks are being completed independently of this retained failure. No trimming, silence padding or tolerance change.

Extended the existing Linux worker runbook with CPU/GPU Compose, protected settings, both overlaid output modes, logs, upgrades/rollback and backup. Flagged actual legacy VPS template gaps (database persistence, relay management, hook routing and old paths) rather than claiming deployment readiness. No service installed or remote host used.

## Full two-phone media acceptance

`native-created-simulators-opRrou/vertical-acceptance.json` binds passing workflows, receipts, export/hash inventory and independent media results. Archive:3382frames; each live output:3112frames, IDs140–3251. All three decode fully at30fps with consecutive source frames, no audio timestamp gaps, passing end coverage and sampled natural-audio synchronization (25archive/23eachlive probes). Both live outputs visibly show0–0→1–0→1–1→1–0→1–1; the archive has no scorebug. It continues130frames beyond live output. This completes the native-created two-phone vertical, not fault/hardware qualification.

Watch runUFjmr8 also passes live waveform synchronization and visible0–0→1–0→0–1 independently; its strict+454ms audio-overhang failure at remote match end remains. Normal Stop streaming in the two-phone run passes the same end-alignment check.

## Direct-minimum720p comparison

`ordinary-native-PvbKtK` ateade9ac completed its native workflow and cleanup. Independent transport/native/geometry replay and transition audit pass: exactly240→360→720→240→360→720, with one downward application. Downward cause560.7–589.8ms after the constraint request, native ACK1017.7–1046.7ms, replacement454ms. Queue diagnostics retain133 overflow packets (90original data,43control), first overflow1101ms, versus309 total previously. This single comparison does not isolate all content/timing variation.

The exported clean archive is11290 consecutive30fps frames, no audio timestamp gaps. Both live outputs fully decode and contain10943frames/10932unique source IDs:93 IDs missing and11 repeated/corrupted observations,15 sequence discontinuities,26 audio timestamp errors, and2.4s maximum video gap. All complete rolling5s windows including the collapse meet24freshfps98.796% of the time; minimum11.4fps. Archive windows remain30fps throughout. Strict media verification fails; later A/V/glyph/phase mapping was intentionally not promoted to a pass. New results improve on the prior162missing-ID/30audio-error run but do not fix severe-congestion media loss.

Post-run orchestration now calls existing verifiers in one artifact helper and retains independent failure statuses. Recovery UI milestones now print concise phase names for the next run, avoiding blind progress polling; this diagnostic-only line passed diff inspection and did not trigger another native/media run. All capture and offline-analysis jobs joined. No physical device, persistent host service, remote deployment, push or PR was used.
