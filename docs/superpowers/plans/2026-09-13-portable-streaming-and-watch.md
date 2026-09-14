# Portable streaming and Apple Watch delivery plan

> **For agentic workers:** Use `superpowers:executing-plans` to execute one milestone
> at a time. Use `superpowers:subagent-driven-development` only when delegation is
> authorized. Checkboxes track delivery, not claims of current functionality.

**Goal:** Record reliable clean video on an iPhone, adapt live audio/video quality,
score from native iPhone or Apple Watch apps, and run the broadcast worker on interchangeable hosts.

**Architecture:** Independent capture/archive and publishing branches feed a portable
relay/worker pipeline. A persistent control plane owns games and scoring commands;
native iPhone and watch clients join the same match. Native macOS acceleration provides
the first complete test environment before physical devices and remote hosts.

**Tech stack:** SwiftUI, AVFoundation/AVAssetWriter, a pinned HaishinKit/SRT release,
WatchConnectivity for optional companion integration, URLSession for watch scoring,
Hono/TypeScript, SQLite, FFmpeg, MediaMTX, Docker Compose, XCTest/XCUITest,
and Vitest. The existing React PWA is a superseded prototype, not a delivery target.

This is a staged delivery plan with explicit experiments and acceptance gates. It
intentionally does not invent unverified Swift media method signatures. The media
compatibility experiment must establish those before detailed implementation of its
adapters. No runtime code was changed while preparing this plan.

## Baseline and owner decisions

The May implementation builds, and its 20 small tests pass, but streaming is incomplete.
The assessment reproduced browser refresh lockout, missing late-worker synchronization,
and a server image that builds but cannot start. iPhone sample forwarding is empty.

Owner decisions: separate scoring/filming devices are acceptable; portable worker is
required; clean local recording is mandatory; favor sustainable image quality above a
24 fps motion floor; include watch scoring; validate locally before phone and new hosts.

Confirmed hardware policy: iPhone 14 and newer, plus older capable phones when practical;
current stable OS plus two previous release generations (currently iOS 17/18/26 and
watchOS 10/11/26). Required watch tests: Ultra 2 and Series 7 41 mm, with layouts that
also accommodate other supported watches. Support phone-routed, Wi-Fi, and cellular
networking, including route changes. Reliability takes priority.

Required workflow: one paired iPhone records and streams while its watch scores;
alternatively the native Scorebug app on another iPhone, or a watch paired to that
other iPhone, joins and scores the same match. No browser scorer is planned. The
paired filming-phone/watch workflow requires no second phone or iPad.
Defaults: clean recording includes gym audio, 30 fps initial target, YouTube remains
the first external destination, and volleyball rules are configurable.

## Order and release gates

| Milestone | Deliverable                                   | Required evidence before proceeding                                |
| --------- | --------------------------------------------- | ------------------------------------------------------------------ |
| 0         | Reproducible local environment                | Correct FFmpeg selected; services and containers actually start    |
| 1         | Shared durable games and native phone scoring | Two clients join; retries/restarts cannot corrupt the score        |
| 2         | Portable worker on this Mac                   | Real SRT input, overlay, local output; CPU and VideoToolbox tested |
| 3         | Recording and publishing core                 | Fixture-driven archive recovery and real media output              |
| 4         | Adaptive quality                              | Deterministic policy tests and impaired-network media measurements |
| 5         | Watch and simulator workflows                 | Score/join/undo/reconnect with authoritative acknowledgments       |
| 6         | Physical phone and watch                      | Two-hour simultaneous recording/streaming and real watch tests     |
| 7         | External destination and other hosts          | YouTube verification, then home/cloud hardware qualification       |

Milestones 1–5 complete locally before physical-device acceptance. A simulator lacking
an SRT binary slice uses an explicit transport test double plus a native macOS media
harness; that result is never labeled an iPhone SRT pass. Each milestone delivers an
independently testable slice. Implement only the next slice, then review its evidence.

## Milestone 0: Reproducible environment and regression baseline

**Files:** `Justfile`, `package.json`, `.github/workflows/ci.yml`,
`docker-compose.dev.yml`, `apps/control-plane/Dockerfile`,
`apps/home-daemon/src/config.ts`, and new `scripts/doctor.mjs`.

- [x] Add a doctor command that reports Node/pnpm, exact FFmpeg/ffprobe paths, SRT,
      drawtext, fonts, usable encoder backends, Docker, Xcode, XcodeGen, and simulator
      runtimes. Probe a real encoder job; distinguish available from actually usable.
- [x] Select `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg` on this Mac through configuration;
      do not globally relink Homebrew or change unrelated projects' toolchains.
- [x] Add configurable binary/font paths; retain existing environment variables with
      documented migration where necessary. XcodeGen 2.46 was installed during this milestone.
- [x] Fix the production server image's missing workspace dependency links. Test the
      final image with an HTTP health request, not just `docker build`.
- [x] Add dedicated local Compose services for ingest and output sink, explicit ports,
      named test volumes, pinned images, and dev-only credentials. Keep production and
      test secrets separate. Do not run cloud or YouTube output in local smoke tests.
- [x] Capture regressions in `docs/regression-baseline.md` for refresh recovery, late-worker attachment, failed end-game,
      and tied-set completion as server/native-app regression requirements. Do not invest
      in repairing or extending the superseded PWA.
- [x] Establish a native scoring-only simulator entry point and shared Swift test
      target without linking unfinished capture/SRT components. This lets milestone 1
      validate native scoring before the media compatibility work in milestone 3.

**Checks:** `pnpm typecheck`, `pnpm test`, `pnpm build`, `pnpm format:check`;
new `pnpm run doctor`; container startup/health test with bounded timeout and teardown.
**Exit:** fresh checkout has documented startup steps and no false-positive image pass.

**Verified:** [Milestone 0 results](../../milestone-0-results.md).

## Milestone 1: Durable match identity and native iPhone scoring

**Files:** `packages/protocol/src/messages.ts`, new `packages/protocol/fixtures/`,
`apps/control-plane/src/state.ts`, `apps/control-plane/src/routes/games.ts`,
new `apps/control-plane/src/{database,scoring,commands}.ts`,
`apps/control-plane/src/home-bus.ts`, `apps/control-plane/src/index.ts`,
`ios/Project.yml`, new `ios/Packages/ScorebugCore/` scoring models/client/outbox,
new `ios/Sources/Scorebug/Scoring/`, `ios/Sources/Scorebug/UI/ContentView.swift`,
`ios/Tests/`, `ios/UITests/`, and new route/command/recovery tests.

- [ ] Define public snapshots, command envelopes, revision/conflict responses, recording
      association, source status, desired broadcast state, worker generation, and reports.
      Add JSON fixtures consumed by both TypeScript and Swift tests.
- [x] Implement SQLite migrations and transactions for matches, scoring authority,
      command IDs/results, and revisions. Keep stream secrets out of scoring responses.
- [ ] Add active-match discovery, role-based join, capture credential retrieval, and
      worker snapshot/reconciliation. Separate game creation from recording/publishing.
- [x] Make point/undo/end-set/end-match commands idempotent. Check duplicate IDs before
      revision checks. Record explicit overrides; reject tied sets and invalid winners.
- [x] Implement configurable set/match rules, including deciding set and win-by-two.
- [x] Build full native SwiftUI Score mode: create/join match, teams/rules, point buttons,
      undo, set/match completion, and status. Scoring requires no camera permission.
- [x] Restore native app sessions from server state; serialize commands and persist the
      outbox. Display pending actions and stale/conflict reconciliation. Keep failed end
      requests visible. Enforce single scorer with explicit takeover.
- [ ] Test duplicate delivery, acknowledgment loss, restart between apply/reply,
      simultaneous takeover, and delayed commands from a previous scorer or set.

**Checks:** focused Vitest and Swift suites plus XCUITest on two iPhone simulators:
create a match, join from the second native app, score, terminate/relaunch, reconnect,
undo, take over scoring, and end the match without invoking a camera or browser.
**Exit:** no lost/double points or unrecoverable active-game lockout; restarts preserve state.

**In progress:** [Native scoring API and recovery evidence](../../native-scoring-api.md).
Recording associations, broadcast commands, and the selected-worker snapshot endpoint
are implemented and restart-tested: [media control evidence](../../media-control-api.md).
Relay credential retrieval, source observation, and automatic relay reconciliation
are now integrated. The worker now consumes durable native assignments and current
scores. Observed worker status in the API/native UI and remaining adversarial
integration cases are still required before this milestone is complete.

## Milestone 2: Real local media through a portable worker

**Files:** `apps/home-daemon/src/{config,pipeline,index,client,overlay-text}.ts`,
new `apps/home-daemon/src/{capabilities,supervisor,telemetry}.ts`,
`apps/home-daemon/Dockerfile`, `infra/vps/{docker-compose,mediamtx}.yml`,
`apps/control-plane/src/routes/internal.ts`, new `apps/control-plane/src/ingest.ts`,
new `infra/local/`, `scripts/media-fixture.sh`, and `scripts/test-media.mjs`.

- [ ] Implement encoder selection and profile capability negotiation: native
      VideoToolbox and software first, extensible backend interface for later GPU hosts.
- [ ] Fix SRT credential provisioning, private relay API access, and hook routing.
      Add real connection tests for valid/invalid publish and read credentials and revocation.
- [ ] Wait for source readiness; reconcile late/restarted workers; reject stale
      generation commands. Report actual first frames/output progress and failures.
- [ ] Fix process supervision: spawn errors, awaited async handlers, serialized
      lifecycle changes, bounded restarts, and SIGTERM/SIGKILL based on process exit.
- [ ] Render initial 0–0 and scaled overlay placement for every qualified resolution.
      Use packaged/configured fonts instead of a hardcoded Linux font path on macOS.
- [ ] Add local sink output and capture a playable result. Prove point changes appear
      in decoded frames using timestamps/frame IDs. Verify audio and its synchronization.
- [ ] Inject source loss, delayed start, worker crash, and control-plane restart;
      assert correct UI status and return to a current-score broadcast.

**Checks:** `pnpm test:media -- --profile=1080p30 --encoder=videotoolbox`, then software;
these runner commands are to be created in this milestone. Real ffprobe/frame checks,
not assertions that FFmpeg arguments merely contain an encoder name.
**Exit:** ten-minute local audio/video run, changing scores, no secrets in captured logs,
recovery within ten seconds after a reachable source returns in the test environment.

**In progress:** [Real SRT access and process supervision evidence](../../relay-conformance.md).
Provisioning/revocation and native credential routes pass real audio/video tests;
automatic relay reconciliation is connected. The durable worker consumer now passes
short local CPU and VideoToolbox runs: initial score, point changes without encoder
restart, graceful worker restart, API outage lease/recovery, and match-end shutdown.
Source-frame barcodes distinguish fresh frames from muxed/duplicated frames. See
[worker runbook](../../../apps/home-daemon/README.md). This does not complete the
ten-minute/audio-sync qualification, abrupt worker crash, source-loss recovery,
capability negotiation, or native status reporting gates.

## Milestone 3: iPhone recording core and streaming adapter

**Files:** `ios/Project.yml`, `ios/Sources/Scorebug/Capture/{CameraSession,ArchiveWriter}.swift`,
`ios/Sources/Scorebug/UI/ContentView.swift`,
`ios/Sources/Scorebug/ControlPlaneAPI/ControlPlaneClient.swift`,
extend `ios/Packages/ScorebugCore/`, `ios/Tests/`, `ios/UITests/` from milestone 1,
and native macOS `tools/media-harness/` sharing the media core where supported.

- [ ] Run the HaishinKit compatibility experiment described in the architecture.
      Record exact dependency version, toolchain, API calls, supported platforms, and
      buffer/bitrate/statistics behavior. Pin resolution and add iOS simulator/device builds.
- [ ] Extract testable capture-source, archive-sink, publishing, and clock interfaces;
      use fixture samples in Simulator and real AVFoundation capture on hardware.
- [ ] Implement independent recording/publishing states and recording-first operation.
      Offline recording must not invoke game creation as a prerequisite.
- [ ] Replace raw passthrough assumptions with valid encoding. Retain delegates and
      serialize writer access. Bound each queue and protect archive writes from live congestion.
- [ ] Implement initialization/media segment storage, atomic completion, manifest,
      relaunch scan/recovery, playback/export, and safe storage-reserve handling.
- [ ] Add camera role joining, truthful status, archive health/space, and explicit
      recording stop. Remote match end cannot silently discard a recording.
- [ ] Feed timestamped motion/audio fixtures through real archive code. Kill the
      harness during writes at multiple boundaries; recover/export and fully decode.

**Checks:** Swift unit/fixture tests; iOS simulator/device compilation; native macOS
media tests; Simulator UI tests with injected capture; five forced-termination runs.
**Exit:** fixture archive remains playable after network failure and forced termination,
with measured tail loss at most five seconds. This is not yet phone hardware qualification.

## Milestone 4: Adaptive quality and measurable reliability

**Files:** new `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`,
its Swift tests, capture/publish adapter, worker telemetry/profile handling,
shared protocol telemetry fixtures, new `infra/local/netem/`,
`scripts/test-media.mjs`, and `scripts/analyze-media.mjs`.

- [ ] Implement a pure policy controller with fake time and deterministic telemetry:
      30 fps target, 24 fps rolling floor, prompt decrease, 30-second recovery hysteresis,
      capacity headroom, supported profile limits, bounded queues, and outage state.
- [ ] Track captured/encoded/received fresh frames separately from muxed/duplicated
      frames. Track archive loss separately from stream loss and output reconnect gaps.
- [ ] Implement bitrate changes and validate resolution/keyframe transitions. Do not
      reconfigure the archive in response to venue bandwidth changes.
- [ ] Validate stable destination-canvas handling; report source and output dimensions
      separately. Qualify destination profile changes before enabling them mid-stream.
- [ ] Impair both directions of SRT inside isolated Linux test containers; use tc/netem
      for UDP bandwidth/loss/delay. A TCP-only proxy is insufficient for the SRT hop.
- [ ] Run deterministic traces: ample bandwidth, step down, partial loss/jitter, total
      outage, recovery, worker overload, and injected thermal-pressure signals.
- [ ] Tune the proposed thresholds against metrics and motion-heavy samples. Store
      actual profiles and limits instead of assuming 4K or high bitrate always wins.

**Checks:** controller unit tests, short impairment matrix, 30-minute media soak.
**Exit:** healthy periods deliver at least 24 fresh fps in 99% of rolling five-second
windows; stable 30 fps profiles have under 1% fresh-frame loss. Measure adaptation
transients/outages separately, without excluding them from the report. Archive stays
continuous during network-only impairment. No false sustained quality or latency claim.

## Milestone 5: Watch scoring and complete simulator workflows

**Files:** `ios/Project.yml`, shared `ios/Packages/ScorebugCore/` scoring models/client,
new `ios/Sources/ScorebugWatch/`, `ios/Sources/Scorebug/Companion/`,
`ios/WatchTests/`, `ios/WatchUITests/`, and native iPhone scoring tests from milestone 1.

- [ ] Add a watchOS target independent of camera/media dependencies and a companion
      setup/join flow within the full native iPhone app. Keep Film and Score roles separate.
- [ ] Set iOS 17/watchOS 10 deployment targets and availability-guard newer APIs.
      Test Series 7 41 mm and Ultra 2 layouts, plus an SE-sized screen. Add watchOS 11
      runtime coverage; that release generation is not currently installed on this Mac.
- [ ] Implement HTTP(S) scoring and snapshot refresh on wake. Use scoped Keychain
      credentials and an expiring pairing code; optionally transfer setup with WatchConnectivity.
- [ ] Add home/away score, set/match display, undo, confirmed/pending states, retry,
      end-set confirmation, and guarded end-match. Do not require a WebSocket on watchOS.
- [ ] Persist uncertain commands across suspension and reuse IDs across HTTP/companion
      routes. Haptics signal server acknowledgment; pending actions look different.
- [ ] Test with dedicated iPhone/watch simulators: native iPhone scorer creates game, capture fixture
      joins, watch scores, worker output changes, then watch suspends/relaunches and rejoins.
- [ ] Use two dedicated phone/watch simulator pairs: phone A films via fixture capture;
      phone B scores natively, then watch B paired to phone B takes over. Verify neither
      requires the camera role or pairing with phone A. Also test watch A scoring while
      its own paired phone A captures.
- [ ] Test stale offline points, missed replies, takeover, tied-set rejection, and
      restoration. Treat unsupported simulator connectivity methods as hardware test items.

**Checks:** unit tests for shared Swift contracts, iOS/watchOS build and UI suites,
and complete local multi-client exercise against the real API and local media pipeline.
**Exit:** every scored command has one authoritative result; UI clearly distinguishes
pending, accepted, and rejected actions. Simulator success is not wrist/network certification.

## Milestone 6: Physical phone and watch, still using this Mac

**Files:** test evidence under ignored `artifacts/qa/`; profile defaults only after qualification.

- [ ] Record phone/watch models, OS versions, available storage, power arrangement,
      signing team, and supported capture profiles. Enable Developer Mode and device trust
      through normal Apple setup when needed. No production stream keys are required yet.
- [ ] Run 10-minute 1080p/30 archive plus local stream, then 4K/30 if the phone supports it.
      Verify exported archive, audio/video sync, real fresh-frame rate, and changing overlay.
- [ ] Use the physical watch to join, score, undo, lower wrist, reopen, and recover
      connection. Test paired-phone networking, Wi-Fi without phone reachability, and
      cellular only if the watch has service.
- [ ] Repeat on both Ultra 2 and Series 7 41 mm while the paired iPhone is actively
      recording and streaming. Test network route handoff and lost acknowledgments during
      handoff. Also test native iPhone B and watch B paired to iPhone B joining and taking
      over scoring while iPhone A keeps recording. Keep phone B camera-free; verify
      watch B HTTP scoring with its companion app backgrounded.
- [ ] Run two hours at each profile intended for release. Include realistic movement,
      screen/power settings, streaming reconnects, and storage accounting. Log heat,
      battery, queue bounds, recording drops, live drops, and recovered media duration.
- [ ] Test source/app interruption, five forced terminations, audio route changes,
      low-space handling, and recovery/export. Use controlled fixture storage limits before
      consuming actual device storage. Never delete unrelated recordings to make room.
- [ ] Test app lock/background behavior explicitly and document any capture gap.
      Repeat a release-like run detached from the debugger to detect debugger-dependent behavior.

**Exit:** clean archive passes full decode and recovery requirements, network-only failure
never stops it, watch actions remain correct, and measured quality meets the selected
profile's motion targets. Unsupported high profiles remain disabled on that device.

## Milestone 7: YouTube and additional worker systems

- [ ] With the owner's test broadcast/key, verify YouTube ingest and playback at each
      selected profile, including reconnect and resolution transitions. Test 4K normal
      latency separately from the 1080p lower-delay mode; measure glass-to-glass latency.
- [ ] Move the same fixture and configuration to a home NVIDIA host, then a chosen
      cloud host. Keep the phone's recording behavior unchanged. Use the local sink first
      on each host, then the destination after the host passes.
- [ ] Qualify Linux CPU amd64/arm64, NVIDIA, Windows/WSL2, and other GPU backends only
      with real runtime evidence. Cross-building an image is not encoder qualification.
- [ ] Add native macOS installation/service instructions and Linux Compose CPU/GPU
      profiles, volumes/backups, upgrades, endpoint configuration, and a doctor command.
- [ ] Test both colocated and split relay/worker layouts, TLS, private management API,
      firewall reachability, restart recovery, credential revocation, and explicit worker move.

**Exit:** documented platform matrix lists tested hardware/profile ceilings and evidence.
No cloud purchase, deployment, or external broadcast occurs as part of this planning task.

## Definition of done

- Reliable clean phone recording is independent of live stream availability.
- Native iPhone and watch apps score the same durable match without duplicate or silently lost points.
- Stream quality responds to measured bottlenecks and truthfully reports fresh-frame delivery.
- This Mac passes the full local harness and the actual phone/watch pass sustained tests.
- A second worker host passes the same conformance suite with no source-code changes.
- CI includes real server-container startup, protocol/scoring regressions, media fixtures,
  and iOS/watchOS compilation; hardware qualification remains a separately recorded gate.
- README, architecture, runbook, and platform matrix reflect measured capabilities.
