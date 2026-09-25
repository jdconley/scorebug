# Portable streaming and Apple Watch delivery plan

**Goal:** A reliable, fully working vertical: iPhone camera capture and independent clean A/V recording; native iPhone/Watch scoring; SRT to a portable proxy; live score overlay; configurable RTMP output to a mock YouTube endpoint that records MP4, with an additional proxy-side final-overlay MP4 recording option.

This document tracks goals, current evidence, delivery tasks and acceptance gates. Put commands, failures and test chronology in [session logs](../../session-logs/README.md). Start a new work session from [NEXT](../../session-logs/NEXT.md). Checkboxes track delivery/audit status, not blanket claims of current functionality.

## Current assessment — September 25

- The guarded SDK, publishing adapters, Core rejection settlement and PublishingSession changes are committed through `b65ca7f`; independent specification and quality reviews approve all four checkpoints.
- Owned app checkpoint `a278c0c` passes **614 app-model and 492 Core tests**, plus an arm64 simulator build; Streaming 245 remains the integration baseline. SDK 346 and Media 271 remain the prior component baseline. Specification and quality reviews approve the app integration and Driver cleanup fix. Component results do not qualify production adaptation or the complete paired hardware route.
- The latest adaptive full native laboratory run (`native-app-uG39s5`, `e0477be`) passes the three-phase 240p → 360p → 240p route, archive/live decode, score glyphs and phase/grid audio. It preserves 7,467 archive and 7,008 acquired live frames, with no gaps inside their recorded spans; all 325 delivery windows meet 30 fps.
- A fresh automatic increase after restoration, the wider adaptive ladder, sustained real-camera operation, paired physical Watch scoring, outages and remote hosts remain unqualified. Production automatic increases remain gated; laboratory routes are explicit.
- Native phone scoring, file-driven independent recording and local proxy/overlay/RTMP recording have working local evidence. Thirty-minute 1080p and 4K file-driven CPU-proxy replays passed; this does not qualify camera or thermal behavior.
- Physical Ultra 2 setup through WatchConnectivity, takeover, point, undo and match end passed. The concurrent phone test exposed a corrected status-text locator; the next paired attempt was blocked by Watch destination preparation. The complete paired three-output acceptance remains open. Direct Watch scoring/relaunch also has simulator evidence.
- Current device observations and the selected Conley Chaos LLC signing team are in [NEXT](../../session-logs/NEXT.md). Historical evidence and failures remain in the [lossless legacy archive](../../session-logs/README.md#legacy-provenance).

- The complete local three-output vertical now passes (`native-app-k1oNme`): clean app archive, mock RTMP destination MP4 and proxy overlay MP4, native score changes, full A/V decode and frame checks. Phone/Watch hardware acceptance remains open. See the [device runbook](../../device-testing.md).
- The iPhone app and embedded Watch app build with Conley Chaos LLC signing; both apps are installed and launch on the real devices. The updated physical iPhone vertical passes with visible camera content, a clean 1080p/~30fps archive, native point entry and both overlaid outputs (`device-lab-yk1iYl`, run11). All three files fully decode. The live source remains at the 240p minimum startup profile, scaled to 1080p by the proxy; automatic increases, perceptual sync and sustained operation remain open. Paired Watch testing awaits a coordinated retry: the user identified the missed first-session passcode prompt on the phone as the reason for the automation timeout. Announce a new device-testing session before starting it so the user can approve that prompt; this is not evidence that Watch automation is disabled.

- [x] Stabilize idle capture setup editing against background poll locks; see [focused fix](2026-09-25-stable-capture-setup.md).

## Baseline and owner decisions

- Support iPhone 14 and newer, plus older capable phones where practical; support the current stable iOS release and two previous release generations. Preserve iOS 17/watchOS 10 deployment targets and Series 7 on its supported OS. Historical version claims are evidence at their original checkpoint, not a substitute for checking the current device matrix.
- Required watches: Ultra 2 and Series 7 41 mm; accommodate other supported layouts. Qualify direct Wi-Fi, cellular where service exists, and paired-phone fallback, including route changes.
- Native scoring only: the filming iPhone and its own paired Watch must work together without a second phone/iPad. A separate camera-free native iPhone scorer, or its paired Watch, may join/take over the same durable match.
- Capture/archive and publishing are independent branches. The clean archive includes gym audio and never receives the score overlay; network-only failure must not stop or corrupt recording. Volleyball rules remain configurable.
- The proxy is portable between this Mac, a home host and cloud hosts; support explicit endpoints and CPU/hardware backends only where qualified. Keep control/scoring durable and secrets out of score responses and logs.
- Start live streaming immediately at the lowest qualified profile, then cautiously increase bitrate/resolution with measured sustainable headroom. Target 30 fps and retain at least a 24 fresh-fps motion floor; sustainable image quality takes precedence over nominal maximum resolution.
- Retain bounded queues, actual readback, fresh delivery evidence, prompt pressure reduction/direct minimum reset, healthy recovery holds and bounded retry backoff. SRT retransmission/loss counters do not stand in for decoded fresh-frame loss.
- Use installed runtimes and remove only owned temporary devices/resources. Do not reinstall removed runtimes without a concrete compatibility need, globally relink tools, delete unrelated recordings, or use production stream keys in local smoke tests.

## Order and release gates

**Immediate priority is a complete physical end-to-end smoke test. Advanced adaptive scheduler/research completion is not a prerequisite for this basic vertical.** Physical iPhone/Watch testing is explicitly authorized and the devices are available now. A smoke pass does not close sustained/device/adaptive release gates.

1. Resolve signing against the available physical iPhone/Watch, build/install, and establish camera/microphone permission, trust and networking. Record exact hardware, OS and profile.
2. Record clean local camera A/V and use native phone scoring; start SRT to the Mac proxy and verify a live initial 0–0 overlay followed by a scored change.
3. Send RTMP to the configurable mock YouTube recorder and save its MP4. Add/verify independently configurable proxy-side recording of the final overlaid output to MP4; preserve the phone's separate clean archive.
4. Join/score/undo from the physical Watch while its paired iPhone records and streams. Exercise wrist lowering/reopen and basic reconnect; also cover the other-phone/other-Watch scorer route when available.
5. Stop/export and fully decode all outputs; verify audio, changing overlay, clean archive and recording continuation after live stops. Log any failures honestly and fix blockers to this vertical first.
6. Continue owned app measurement/application integration and a fresh four-phase recovery experiment, then wider profiles, realistic faults and sustained device qualification. Complete YouTube and second-host acceptance after the local vertical.

The milestone backlogs below are qualification groupings, not a rule preventing earlier physical smoke tests. Each implementation slice needs its own relevant checks/review. A transport double plus Mac harness is never labeled an iPhone SRT pass.

## Progressive streaming amendment — September 16

The [progressive adaptation design](../specs/2026-09-16-progressive-streaming-design.md) remains the product contract. Initial qualification settings: >5% missing/late frames over two seconds, or <24 fresh fps over one second, plus proactive queue/transport pressure reduction. Five-second worker windows alone cannot prove these short-window gates. These are test settings, not an industry standard.

- [ ] Qualify 240p/360p low-end profiles and the supported intermediate ladder.
- [ ] Add scoped short-window delivery health and a no-progress watchdog.
- [ ] Add direct minimum reset, precedence over trial rollback, recovery holds and bounded retry backoff to the existing policy.
- [ ] Start the actual native encoder at the minimum before its first sample; acknowledge actual dimensions and configuration during policy bootstrap.
- [x] Qualify candidate-cost, staged admission and two native upward/fault/minimum-reset/ recovery cycles in the local instrumented fixture (`89926f4`, September 24).
- [ ] Extend that qualification to realistic networks, physical devices and remote workers before enabling production automatic adaptation.
- [ ] Measure startup, collapse/reset and recovery on this Mac, then physical phone/watch and portable remote workers, preserving independent local A/V.

## Remaining integration and vertical work

- [x] Pass the short physical iPhone route through clean archive, native scoring, proxy overlay and both MP4 outputs; retain the startup-profile, sync and sustained-operation limits in the current assessment.
- [ ] Complete the authorized physical vertical and record all three artifacts: clean phone archive, mock-destination MP4 and configurable proxy final-overlay MP4.
- [x] Add reviewed, opt-in guarded app application ownership; preserve publication on pre-effect rejection and join shutdown after partial profile application (`064e555`).
- [x] Resolve the full-suite stop/control-poll ordering failure with a deterministic regression, then verify scoped stop before replacement publishing (`265aa0a`, 598 app-model tests pass).
- [x] Review the owned measurement/apply/retry route and resolve Driver tick blocking during rejected-application cleanup. Exact cleanup and settlement remain joined through stop.
- [ ] Complete full-media qualification of the reviewed owned app route. The first real run records all three outputs but does not upgrade. Campaign-aware relay selection is fixed; candidate scheduling must align with fresh source reports before rerunning.
- [ ] Qualify the fresh four-phase automatic post-restoration increase with complete media/evidence checks; do not infer it from component suites or the passing three-phase run. The separate test contract and 390-second source preparation are reviewed/verified; actual native recovery and whole-history qualification remain open. See [four-phase qualification](2026-09-25-owned-recovery-qualification.md).

Implementation references: [owned retries](2026-09-25-owned-measured-retries.md), [probe operations](2026-09-25-owned-probe-operations.md), [guarded admission](2026-09-25-owned-application-admission.md). Session reviews are complete; older “awaits review” prose in subordinate implementation documents is historical. Native integration qualification remains open.

The following **original checkboxes and statuses are preserved**. An unchecked item can have component evidence without its full delivery/qualification audit being complete; do not silently promote it to done.

## Milestone 0: Reproducible environment and regression baseline

- [x] Add a doctor command that reports Node/pnpm, exact FFmpeg/ffprobe paths, SRT, drawtext, fonts, usable encoder backends, Docker, Xcode, XcodeGen, and simulator runtimes. Probe a real encoder job; distinguish available from actually usable.
- [x] Select `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg` on this Mac through configuration; do not globally relink Homebrew or change unrelated projects' toolchains.
- [x] Add configurable binary/font paths; retain existing environment variables with documented migration where necessary. XcodeGen 2.46 was installed during this milestone.
- [x] Fix the production server image's missing workspace dependency links. Test the final image with an HTTP health request, not just `docker build`.
- [x] Add dedicated local Compose services for ingest and output sink, explicit ports, named test volumes, pinned images, and dev-only credentials. Keep production and test secrets separate. Do not run cloud or YouTube output in local smoke tests.
- [x] Capture regressions in `docs/regression-baseline.md` for refresh recovery, late-worker attachment, failed end-game, and tied-set completion as server/native-app regression requirements. Do not invest in repairing or extending the superseded PWA.
- [x] Establish a native scoring-only simulator entry point and shared Swift test target without linking unfinished capture/SRT components. This lets milestone 1 validate native scoring before the media compatibility work in milestone 3.

**Acceptance:** Fresh checkout has documented startup steps; doctor probes an actual encoder; the final server image starts and answers HTTP health. Run relevant typecheck/test/build/format and bounded container checks.

## Milestone 1: Durable match identity and native iPhone scoring

- [ ] Define public snapshots, command envelopes, revision/conflict responses, recording association, source status, desired broadcast state, worker generation, and reports. Add JSON fixtures consumed by both TypeScript and Swift tests.
- [x] Implement SQLite migrations and transactions for matches, scoring authority, command IDs/results, and revisions. Keep stream secrets out of scoring responses.
- [ ] Add active-match discovery, role-based join, capture credential retrieval, and worker snapshot/reconciliation. Separate game creation from recording/publishing.
- [x] Make point/undo/end-set/end-match commands idempotent. Check duplicate IDs before revision checks. Record explicit overrides; reject tied sets and invalid winners.
- [x] Implement configurable set/match rules, including deciding set and win-by-two.
- [x] Build full native SwiftUI Score mode: create/join match, teams/rules, point buttons, undo, set/match completion, and status. Scoring requires no camera permission.
- [x] Restore native app sessions from server state; serialize commands and persist the outbox. Display pending actions and stale/conflict reconciliation. Keep failed end requests visible. Enforce single scorer with explicit takeover.
- [ ] Test duplicate delivery, acknowledgment loss, restart between apply/reply, simultaneous takeover, and delayed commands from a previous scorer or set.

**Acceptance:** Two native iPhone clients create/join, score, restart/reconnect, undo/take over and end a match without camera/browser dependence. No lost/double points, active-game lockout or restart state loss; exercise duplicate/lost replies and adversarial commands.

## Milestone 2: Real local media through a portable worker

- [ ] Implement encoder selection and profile capability negotiation: native VideoToolbox and software first, extensible backend interface for later GPU hosts.
- [ ] Fix SRT credential provisioning, private relay API access, and hook routing. Add real connection tests for valid/invalid publish and read credentials and revocation.
- [x] Wait for source readiness; reconcile late/restarted workers; reject stale generation commands. Report actual first frames/output progress and failures.
- [x] Fix process supervision: spawn errors, awaited async handlers, serialized lifecycle changes, bounded restarts, and SIGTERM/SIGKILL based on process exit.
- [ ] Render initial 0–0 and scaled overlay placement for every qualified resolution. Use packaged/configured fonts instead of a hardcoded Linux font path on macOS.
- [x] Add local sink output and capture a playable 720p30 result. Prove point changes appear in decoded frames using timestamps/frame IDs. Verify audio and synchronization.
- [ ] Inject source loss, delayed start, worker crash, and control-plane restart; assert correct UI status and return to a current-score broadcast.

**Acceptance:** Ten-minute local A/V with changing scores; CPU and VideoToolbox checked by decoded media, timestamps and ffprobe. No secrets in logs; recover within ten seconds of a reachable source returning in the test environment.

## Milestone 3: iPhone recording core and streaming adapter

- [x] Run the HaishinKit compatibility experiment described in the architecture. Record exact dependency version, toolchain, API calls, supported platforms, and buffer/bitrate/statistics behavior. Pin resolution and add iOS simulator/device builds.
- [x] Extract testable capture-source, archive-sink, publishing, and clock interfaces; use fixture samples in Simulator and real AVFoundation capture on hardware.
- [x] Implement independent recording/publishing states and recording-first operation. Offline recording must not invoke game creation as a prerequisite.
- [x] Replace raw passthrough assumptions with valid encoding. Retain delegates and serialize writer access. Bound each queue and protect archive writes from live congestion.
- [x] Implement initialization/media segment storage, atomic completion, manifest, relaunch scan/recovery, playback/export, and safe storage-reserve handling.
- [x] Add camera role joining, truthful status, archive health/space, and explicit recording stop. Remote match end cannot silently discard a recording.
- [x] Feed timestamped motion/audio fixtures through real archive code. Kill the harness during writes at multiple boundaries; recover/export and fully decode.

**Acceptance:** Fixture archive survives network failure and five forced terminations, recovers/exports and fully decodes with measured tail loss ≤5 seconds. Check Swift fixtures, simulator/device compilation and native media/UI paths; phone hardware remains a separate gate.

## Milestone 4: Adaptive quality and measurable reliability

- [x] Implement a pure policy controller with fake time and deterministic telemetry: 30 fps target, 24 fps rolling floor, prompt decrease, 30-second recovery hysteresis, capacity headroom, supported profile limits, bounded queues, and outage state.
- [ ] Track captured/encoded/received fresh frames separately from muxed/duplicated frames. Track archive loss separately from stream loss and output reconnect gaps.
- [x] Implement verified live bitrate changes with native readback, lifecycle guards and measured dual-output continuity; keep archive settings independent.
- [ ] Validate profile-revision boundaries and resolution/keyframe transitions before feeding applied settings back to the automatic policy.
- [ ] Validate stable destination-canvas handling; report source and output dimensions separately. Qualify destination profile changes before enabling them mid-stream.
- [ ] Impair both directions of SRT inside isolated Linux test containers; use tc/netem for UDP bandwidth/loss/delay. A TCP-only proxy is insufficient for the SRT hop.
- [ ] Run deterministic traces: ample bandwidth, step down, partial loss/jitter, total outage, recovery, worker overload, and injected thermal-pressure signals.
- [ ] Tune the proposed thresholds against metrics and motion-heavy samples. Store actual profiles and limits instead of assuming 4K or high bitrate always wins.

**Acceptance:** Controller tests, short impairment matrix and 30-minute media soak. Healthy periods deliver ≥24 fresh fps in 99% of rolling five-second windows; stable 30 fps profiles have <1% fresh-frame loss. Report transients/outages separately without hiding them. Network impairment leaves the archive continuous. No unsupported sustained-quality/latency claims.

## Milestone 5: Watch scoring and complete simulator workflows

- [x] Add a watchOS target independent of camera/media dependencies and a companion setup/join flow within the full native iPhone app. Keep Film and Score roles separate.
- [x] Set iOS 17/watchOS 10 deployment targets and availability-guard newer APIs. Test Series 7 41 mm and Ultra 2 layouts, plus an SE-sized screen. Add watchOS 11 runtime coverage. Series 7 41 mm/watchOS 11.5 passed at `artifacts/qa/native-watch-LAbbIq`.
- [x] Implement HTTP(S) scoring and snapshot refresh on wake. Use scoped Keychain credentials and an expiring pairing code; optionally transfer setup with WatchConnectivity.
- [x] Add home/away score, set/match display, undo, confirmed/pending states, retry, end-set confirmation, and guarded end-match. Do not require a WebSocket on watchOS.
- [x] Persist uncertain commands across suspension and reuse IDs across HTTP/companion routes. Haptics signal server acknowledgment; pending actions look different.
- [ ] Test with dedicated iPhone/watch simulators: native iPhone scorer creates game, capture fixture joins, watch scores, worker output changes, then watch suspends/relaunches and rejoins.
- [ ] Use two dedicated phone/watch simulator pairs: phone A films via fixture capture; phone B scores natively, then watch B paired to phone B takes over. Verify neither requires the camera role or pairing with phone A. Also test watch A scoring while its own paired phone A captures.
- [ ] Test stale offline points, missed replies, takeover, tied-set rejection, and restoration. Treat unsupported simulator connectivity methods as hardware test items.

**Acceptance:** Shared Swift contracts, iOS/watchOS builds/UI and complete local real-API/media workflow. Every score command has one authoritative outcome; pending, accepted and rejected actions are visibly distinct. Simulator success does not certify wrist/network behavior.

## Milestone 6: Physical phone and watch, still using this Mac

- [ ] Record phone/watch models, OS versions, available storage, power arrangement, signing team, and supported capture profiles. Enable Developer Mode and device trust through normal Apple setup when needed. No production stream keys are required yet.
- [ ] Run 10-minute 1080p/30 archive plus local stream, then 4K/30 if the phone supports it. Verify exported archive, audio/video sync, real fresh-frame rate, and changing overlay.
- [ ] Use the physical watch to join, score, undo, lower wrist, reopen, and recover connection. Test paired-phone networking, Wi-Fi without phone reachability, and cellular only if the watch has service.
- [ ] Repeat on both Ultra 2 and Series 7 41 mm while the paired iPhone is actively recording and streaming. Test network route handoff and lost acknowledgments during handoff. Also test native iPhone B and watch B paired to iPhone B joining and taking over scoring while iPhone A keeps recording. Keep phone B camera-free; verify watch B HTTP scoring with its companion app backgrounded.
- [ ] Run two hours at each profile intended for release. Include realistic movement, screen/power settings, streaming reconnects, and storage accounting. Log heat, battery, queue bounds, recording drops, live drops, and recovered media duration.
- [ ] Test source/app interruption, five forced terminations, audio route changes, low-space handling, and recovery/export. Use controlled fixture storage limits before consuming actual device storage. Never delete unrelated recordings to make room.
- [ ] Test app lock/background behavior explicitly and document any capture gap. Repeat a release-like run detached from the debugger to detect debugger-dependent behavior.

**Acceptance:** Clean archive fully decodes and meets recovery requirements; network-only failure never stops it. Watch actions remain correct and measured quality meets the selected profile’s motion targets. Unsupported high profiles stay disabled. Record explicit lock/background gaps and detached-debugger behavior.

## Milestone 7: YouTube and additional worker systems

- [ ] With the owner's test broadcast/key, verify YouTube ingest and playback at each selected profile, including reconnect and resolution transitions. Test 4K normal latency separately from the 1080p lower-delay mode; measure glass-to-glass latency.
- [ ] Move the same fixture and configuration to a home NVIDIA host, then a chosen cloud host. Keep the phone's recording behavior unchanged. Use the local sink first on each host, then the destination after the host passes.
- [ ] Qualify Linux CPU amd64/arm64, NVIDIA, Windows/WSL2, and other GPU backends only with real runtime evidence. Cross-building an image is not encoder qualification.
- [ ] Add native macOS installation/service instructions and Linux Compose CPU/GPU profiles, volumes/backups, upgrades, endpoint configuration, and a doctor command.
- [ ] Test both colocated and split relay/worker layouts, TLS, private management API, firewall reachability, restart recovery, credential revocation, and explicit worker move.

**Acceptance:** Publish a platform matrix of actual tested hardware/profile ceilings. Cross-builds do not qualify encoders. Local mock output precedes external destination/host acceptance; this plan cleanup does not authorize cloud purchases or an external broadcast.

## Definition of done

- Reliable clean phone A/V recording remains independent of live stream availability; recovery/export is measured.
- Native iPhone and Watch apps score the same durable match without duplicate or silently lost points, including the same filming-phone/Watch pair and separate scorer devices.
- SRT reaches the portable proxy, live scores appear in its output, configurable RTMP reaches the mock destination recorder, and configurable proxy-side final-overlay MP4 recording works; phone archive remains clean.
- Stream quality starts low, responds to measured bottlenecks and reports actual fresh-frame delivery with sustainable bitrate/resolution and the ≥24 fps floor.
- This Mac passes the complete local harness; actual phones/watches pass sustained and route-change tests. A second host passes the same conformance suite without source changes.
- CI covers real server-container startup, protocol/scoring regressions, media fixtures and iOS/watchOS compilation; hardware qualification is recorded separately.
- README, architecture, runbook and platform matrix describe measured capabilities. YouTube ingest/playback and latency are checked with the owner’s test destination when authorized.

## Session history and maintenance

Append one [session log](../../session-logs/README.md) per work session with goal, commands/results, decisions, failures, commits and next steps. Keep this plan limited to current status, acceptance and backlog. Update [NEXT](../../session-logs/NEXT.md) for handoff; writing it does not compact the conversation.

The original 3,206-line plan is retained byte-for-byte and as a readable archive with repaired relative links. Known September 25 checkpoints have separately named imported logs; unknown older session boundaries remain unknown. Original checkbox wording/statuses remain above, including partially evidenced open audits.
