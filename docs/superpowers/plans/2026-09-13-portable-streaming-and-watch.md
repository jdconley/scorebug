# Portable streaming and native scoring delivery plan

## Goal

A complete native system: reliable clean iPhone audio/video recording; native iPhone and Apple Watch scoring; adaptive SRT upload to a portable score-overlay proxy; configurable RTMP output to a mock YouTube endpoint that records MP4; and optional proxy-side MP4 of the final overlaid stream.

## Current priorities and iteration policy

**Simulator-first, per the owner's September26 direction. Hardware testing resumes after simulator-testable features work together.** Batch changes, use focused regression checks for changed behavior, reuse incremental builds, and perform broader tests/review at completed workflow checkpoints. Do not repeat full suites, physical signing builds or separate review cycles for tiny changes. This replaces older physical-first and per-slice execution sequencing in subordinate plans.

Keep native recording, real encoding/networking, the real API, proxy and output recorder in integration tests. Where the installed simulator cannot deliver WatchConnectivity setup, an explicit simulator-only setup fixture may exercise native Watch networking/scoring; label that limitation and retain a separate real-companion qualification gate. Never count a fixture as a hardware transport pass.

## Product requirements

- Native scoring only. Score on the filming phone and its paired Watch, or another native phone and that phone's Watch. Scoring must not require camera permission or a browser.
- Support iPhone14 and newer, older capable devices where practical, and the current stable iOS generation plus two previous generations. Preserve iOS17/watchOS10 deployment targets and appropriate availability checks. Cover Ultra2, Series7 41mm and smaller supported Watch layouts.
- Prefer reliability across direct Watch Wi-Fi/cellular and paired-phone fallback. Persist uncertain actions and reuse command identities across retries/routes.
- Clean local A/V recording is required, independent of network and match state, with recovery, playback/export and safe low-storage behavior. Only proxy output receives the score overlay.
- Start upload at the lowest supported quality, then increase with measured headroom. On sustained loss/congestion, return to minimum and recover cautiously. Target30fps and ≥24 freshfps in healthy periods; report transition/outage losses separately.
- Portable proxy configuration must support local/home/cloud hosts, CPU and qualified hardware encoders, explicit endpoints, RTMP/MP4/both outputs, bounded queues, process recovery and secret isolation.
- Preserve source footage, user recordings and unrelated simulators. Use installed runtimes. No cloud purchases, production keys or real broadcasts without owner authorization.

## Current status

| Area | Implemented | Remaining acceptance |
|---|---|---|
| Native match create/discovery/join and phone scoring | Yes; durable commands, takeover, rules, undo, end-set/match, restoration | Native-created two-phone simulator workflow passes; integrated adversarial/reconnect cases remain |
| Clean archive and export | Yes; independent capture, segmented recovery, storage guards, playback/export | Combined failure/restart workflow and current full-feature regression checkpoint |
| SRT → overlay proxy → RTMP and MP4 | Yes; initial/changing score, configurable font, software/VideoToolbox selection, mock destination and proxy recording | Native workflow with worker/control-plane restart; backend capability reporting and installation packaging |
| Progressive upload | Start-low and measured adaptation implemented; two simulator240→360→minimum→360 recovery runs pass |720p→minimum→720p controller/geometry passes; forced collapse still loses live A/V. Higher profiles and sustained operation unqualified |
| Native Watch | Setup, scoring, durable recovery, direct/companion routing and UI implemented | Direct-network simulator scoring/relaunch while phone publishes passes; separate scorer's Watch remains. Real WatchConnectivity simulator registration currently fails7018 |
| Physical system | Phone local archive/native scoring/proxy/mock outputs work; standalone Ultra2 scoring works | Combined paired run and sustained/radio-route testing deferred; uncertain test pairing preserved |
| Portability | Local Mac and container workflows exist; long1080p/4K file replays pass | Install/service/upgrade instructions, backend capability matrix and other-host runtime qualification |

Implementation evidence and failures live in [session logs](../../session-logs/README.md). [NEXT](../../session-logs/NEXT.md) identifies the current checkout, commands and handoff. Checkmarks below mean the stated item is complete, not blanket release qualification.

## 1. Finish the complete simulator vertical

- [x] Run the phone file-capture source through normal archive, publishing and adaptation while a native Watch scores through the real API. Fixture only the setup transport; verify the current match/pairing before mutations.
- [x] While capture and stream continue, relaunch Watch without reinjecting setup; recover the same pairing/score, then score/undo/end with exactly one server outcome per command.
- [x] Verify the complete two-phone vertical: clean archive/export, changing overlay in both proxy/mock MP4s, continuous30fps video, audio synchronization and archive continuation after streaming stops.
- [ ] Fix/verify remote Watch match-end finalization: Watch commands/restoration, frame continuity, audio sync and visible score changes pass, but live audio outlasts video by454ms. Normal phone Stop streaming aligns within24ms.
- [x] Exercise native phone B creating a match, phone A discovering/joining to record/publish, and phone B scoring/undoing without capture permissions. Both native workflows and durable role checks pass on iPhone14 simulators.
- [ ] Extend the separate-scorer workflow through Watch B takeover; finish layout checks on supported small Watch screens.
- [ ] Run scoring reconnect/lost-reply/takeover/stale-command cases against the real API with native restoration; retain existing idempotency, tied-set rejection and durable-outbox coverage.
- [ ] Complete one consolidated simulator regression checkpoint covering native phone, Watch, archive recovery/export and the real local media pipeline. Separate any unsupported simulator OS transport from application feature results.

## 2. Make adaptive streaming reliable

- [x] On progressive transport congestion, descend directly to minimum without an unnecessary intermediate encoder replacement; preserve other pressure behavior and measured upward admission.
- [x] Measure720p increase → direct minimum fallback →720p recovery on the simulator. Controller/transport/geometry and clean local archive pass; failed live-media evidence is retained.
- [ ] Reduce the remaining severe-congestion damage: latest run has93 missing source IDs,11 repeated/corrupted observations,26 audio gaps and a2.4-second maximum video gap. Preserve actual metrics and failed outputs; do not equate a controller pass with a media pass.
- [ ] Finish delivery-evidence retention/terminal coverage and missing-live-audio/shutdown diagnosis where still relevant to current runs; do not raise audit limits or pad silence to conceal loss.
- [ ] Verify stale reports/no-progress handling, native readback and revision/keyframe boundaries, thermal/queue pressure, partial loss, total outage and restoration.
- [ ] Qualify sustainable profiles and transport overhead for each supported backend/device. Unsupported4K remains disabled. Maintain bounded continuous adaptation for full-match durations.
- [ ] Choose and document production latency/SRT policy from measured results; current diagnostic timing profiles are experiments, not industry standards.

Healthy-period acceptance: ≥24 freshfps in99% of rolling five-second windows; stable30fps profiles have<1% fresh-frame loss. Report transients/outages explicitly. Network failure must not stop or corrupt the clean archive. Existing stricter experimental contracts retain their original results.

References: [progressive design](../specs/2026-09-16-progressive-streaming-design.md), [ordinary recovery](2026-09-26-ordinary-recovery-integration.md), [platform research](../../research/2026-09-25-live-platform-adaptation.md), [transport budget](2026-09-26-ordinary-transport-budget.md).

## 3. Complete local resilience and deployment

- [ ] During native capture, test source interruption, worker crash/restart and control-plane restart. Return to the current score and reachable source; keep archive continuous.
- [ ] Consolidate archive forced-termination/relaunch/export, low-space and queue-pressure coverage with the full app. Check recovery tail loss≤5seconds; preserve existing outputs on error.
- [ ] Verify valid/invalid SRT credentials, revocation, stale worker generations, late attachment and scoped cleanup in the complete local stack.
- [ ] Add explicit backend capability reporting/negotiation beyond static encoder selection; distinguish configured, available and runtime-qualified profiles.
- [x] Provide a native macOS worker service helper and [runbook](../../macos-worker-service.md) with configuration, logs, backup, upgrade and rollback. Generation/configuration checks pass; actual launchd service operation remains to verify.
- [x] Document Linux worker Compose CPU/GPU configuration, output modes, upgrade/rollback and current qualification limits. The VPS Compose template now uses persistent storage and the managed native relay; its local wiring/persistence check passes.
- [x] Repair and locally verify VPS Compose: persistent native database, private authenticated relay management, generation-scoped paths, durable API-container recreation and stop cleanup. CI reuses its built images for this check.
- [ ] Verify actual external Linux deployment networking/TLS/media and the Mac service against the local mock output.
- [ ] Update README, architecture, runbook and tested platform matrix. Add/verify CI for protocol/scoring, real server-container startup, native builds and simulator/media checkpoints appropriate to CI resources.

## 4. Deferred hardware and external acceptance

- [ ] Restore physical device readiness and safely reconcile the preserved test-owned pending Watch pairing after identifying it. Do not blindly clear Keychain or uncertain commands.
- [ ] Verify same-phone/Watch and separate-phone/Watch scoring on Ultra2 and Series7 while filming; wrist lowering/reopen, direct Wi-Fi/cellular where available, paired fallback and route handoff.
- [ ] Run10-minute1080p30 then supported4K30 capture, followed by two-hour tests at release profiles. Measure fresh frames, A/V sync, heat, battery, storage, reconnect and archive continuity.
- [ ] Verify camera/audio interruption, lock/background, low space, forced termination and detached-debugger behavior on real devices. Record actual OS/profile ceilings.
- [ ] Move unchanged proxy configuration/conformance tests to home and cloud hosts. Qualify Linux amd64/arm64 CPU, NVIDIA, Windows/WSL2 and other backends only on actual runtimes.
- [ ] Test colocated/split relay-worker layouts, TLS/private management, firewall access, restart, credential revocation and explicit worker moves.
- [ ] When authorized with a test destination/key, verify YouTube ingest/playback, reconnect, profile changes and glass-to-glass latency. Local mock output remains the default.

## Completion criteria

All simulator-testable features work together, including clean recording, native phone/Watch scoring and restoration, adaptive live upload, overlay proxy and both output recordings. Faults have bounded, truthful outcomes and recording survives network failure. Documentation reflects measured capabilities. Hardware and remote-host qualification are separately recorded and must pass before claiming those configurations release-ready.

Keep this document limited to goals, current status and outstanding work. Put commands, experiment history, review details and per-session results in separate logs.
