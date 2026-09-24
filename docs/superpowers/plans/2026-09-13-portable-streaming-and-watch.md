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

## Current assessment — September 24

**The latest complete repeated native recovery test passes.** Frozen `23f0479` /
`native-app-Gx1pcB` passes native iPhone scoring, clean recording/export, both measured
admissions, all five 240p/360p phases, two controlled decoder failures, minimum resets
and whole recoveries. The harness exits zero; UI takes 257.764 seconds. All 1,162
tracked hashes stay unchanged, and owned processes, simulator and ingest clean up.
The archive has 6,546 contiguous frames; live has 6,139. Both MP4s fully decode;
108 archive and 102 expected live audio markers match, with at most 65.25 ms live
offset and negligible drift. Archive queue loss/rejection is zero. All 276 deadline
rows replay; the 30 missing deadline observations from intentional faults remain
visible. Independent review and 3,415 tooling tests pass. This remains laboratory
qualification; production upgrades and physical/remote testing retain their gates.

**Earlier baseline:** on frozen `89926f4`, `native-app-cbBvJb` passed native iPhone scoring, independent clean
recording/export, both measured admissions, all five 240p/360p profile phases,
two owned decoder faults, minimum resets and independently reconstructed recoveries.
The full harness exited zero; native UI took 257.729 seconds. All 924 source hashes
stayed unchanged, and worker/recorder exits plus owned cleanup completed.

Two repaired prerequisites made this possible: candidate envelope v5 preserves
actual probe-read intervals across asynchronous waits, and the repeated-fixture
scheduler waits for completed delivery recovery alongside fresh source health.
Campaign two began 4.119877 seconds after the shared recovery proof became available.
It uses a later fresh source reading rather than extending the earlier reading's
expiry. Independent specification and quality reviews approve both changes.

Verification includes 498 passing native model tests and the arm64 simulator build.
Unchanged Core and JS retain their 459/3,349-test passing evidence. The native
qualification uses the existing 180-second repeated fixture, motion/frame-ID/audio
markers, local SRT relay, VideoToolbox proxy, overlay, RTMP and independent recorder.
It is a complete pass for this laboratory route, not production upgrade permission.

The clean archive contains 6,538 contiguous 1080p frames; live contains 6,130 contiguous
source frames, both at 30 fps. Both MP4s fully decode and pass audio/video coverage.
All 102 live audio markers match within 65.583 ms with negligible drift. Audio leads
video by 287 ms. Direct-recorder reconciliation accounts for the 38-frame acquisition
prefix. All 274 delivery rows independently replay with no unknown rows; the 25
missing deadline frames from the intentional faults remain in the evidence. There
are 2,056 cadence reports and no rejected quality events. The candidate-wait trace
closed valid with 1,007 events / 350,355 bytes.

**Representative 4K coverage added:** an explicitly configured native 3840×2160
sender and independent archive now have passing 12-second real-match runs through
both CPU and VideoToolbox proxies. A CPU → VideoToolbox sequence on `b998b5f` retained
all 360 frames in both outputs, zero queue loss, 33–34 ms live frame gaps and stable
67.25 ms measured live audio lag. All 1,148 tracked file hashes stayed unchanged.
Both outputs fully decode; separate visual checks confirm clean archive and live
score overlay. This uses 30 fps SDR normalization and a scheduled bitrate change,
not automatic adaptation, HDR/60 fps, camera capture or relay qualification.

**Transport starvation fixed; 4K audio starvation remains.** Diagnostics measured
synchronous video conversion blocking the stream actor for about 49 ms while the
socket call took 0.014 ms. The transport consumer now drains on its own serial
worker, with publication ownership and cancellation fences. On frozen `582a339`,
the real 4K failure moves to `queueCapacityExceeded(boundary: "audio codec")`:
253 proxy frames, while the clean archive retains all 360 frames and 576,000 audio
samples with zero rejection. All 619 transport sends have complete timing brackets;
maximum send time is 0.909 ms and observed pending payloads never exceed two.
Synchronous conversion occupies about 98% of the final four seconds. This fixes
the measured transport bottleneck but does not establish reliable 4K publishing.

The runtime change passes 297 vendor, 170 Streaming, 10 clean SDKProbe and 499
native model tests, plus the simulator build. The repeated adaptive regression
`native-app-gN2v2o` nevertheless **fails the full harness**: its UI workflow passes
in 260.326 seconds, but only the first increase/fault/minimum reset occurs. The
second bandwidth campaign reports `readinessUnavailable`, and the fault scheduler
times out. Only three of the required five profile phases occur. All 1,153 frozen
tracked file hashes remain unchanged. No second-cycle qualification or full media
qualification is claimed for this failed run; the earlier `89926f4` pass is retained.

**Latest recovery correction:** the reviewed
[one-frame boundary correction](2026-09-24-shared-delivery-readiness.md) passes all
502 native model and 3,353 JS tool tests plus simulator build. Frozen `d73461b`
reaches both probe campaigns and confirms the second trial, but its complete run
`native-app-hT3aOi` still fails: a 261.974 ms cadence sample exceeds the strict
250 ms freshness limit during the first trial. That trial safely rolls back before
any controlled fault. Only four profile phases occur. All 1,155 tracked hashes are
unchanged; UI passes in 262.682 seconds. Retain this failed run and the freshness
limit. Recovered readiness is reachable, but the full repeated route is unqualified
on current source.

**Latest native submission isolation (`f35cbd0`):** audio can now drain while a
single native video conversion runs independently. Settings, replacement, finish
and close retain bounded ownership and session lifetime. Independent review and
306 vendor / 170 Streaming / 10 clean SDKProbe / 502 native model tests plus the
simulator build pass. The maintained vendor patch verifies all 162 upstream hashes.

Two consecutive real 4K cases pass completely. The third finishes streaming but
encodes/delivers only 350 of 360 frames; one aligned second has 23 frames, so the
capped campaign stops. All three clean archives retain all 360 frames and 576,000
audio samples with zero rejection. Audio correlation and full decoding pass in all
six outputs. This resolves the reproduced audio-starvation mechanism; sustainable
4K remains unqualified. No queue or acceptance limits were enlarged.

The strict repeated native run `native-app-aPqApF` completes both owned faults and
all five profile phases, with UI success in 260.773 seconds, but **fails the full
verifier**. At minimum revision 4, a source window crosses its two-second lifetime
between selection (1.983599 s) and evaluation (2.001052 s) and is safely rejected.
That frozen verifier proved only cadence-freshness invalidations;
this distinct source/time rejection was unsupported. Preserve the failed outcome,
exact raw event and both freshness limits. All 1,158 frozen source hashes remain
unchanged. Native recording finishes cleanly; worker/recorder and simulator cleanup
complete. See the [submission implementation and evidence](2026-09-24-video-submission-isolation.md).

**Source-expiry verification implemented:** independent review and all 3,415 tooling
tests pass. The narrow typed proof consumes the rejected source once, grants no
policy sequence or health credit, and preserves independent source/cadence freshness
limits. Readiness also invalidates by evaluation time. A separately labelled raw
reconstruction of `aPqApF` passes with renewed whole recovery; the original full run
remains failed. The subsequent fresh `23f0479` / `Gx1pcB` full run passes as described
above. See the [source-expiry plan](2026-09-24-source-expiry-invalidation.md).

**Next local work:** implement the reviewed [native encoder selection diagnostic](2026-09-24-native-hardware-selection.md),
then measure actual selected acceleration before changing encoder preferences or
attributing the remaining 4K throughput limit. Keep sustainable 4K unqualified until
the representative campaign meets its frame/audio/archive gates.
See the [muxer-pressure investigation](2026-09-24-4k-muxer-pressure.md),
[transport design](../specs/2026-09-24-transport-drain-isolation.md),
[4K plan](2026-09-24-native-4k-match.md) and
[representative-match evidence](../../representative-match-testing.md).
Keep the instrumented fixture for independent frame identity and recovery proof.

Historical failures remain preserved: `3ynqcN` began its second probe before shared
recovery; `q6s6KU` misattributed a saved probe snapshot and retained a separate policy
`time` rejection; `yB8xre` missed a short readiness opportunity whose exact poll
predicate is unknown. A deterministic test shows its 9.409 ms freshness window can
fall between 100 ms polls. `LeTozN` lost the first 395.011 ms of live audio; subsequent
audio-leading runs do not resolve it. Preserve the 100 ms missing-audio gate.

Production automatic upgrades, network-loss recovery, long physical-device thermal
runs, paired-watch hardware networking and other proxy hosts remain unqualified.
The [shared-readiness plan](2026-09-24-shared-delivery-readiness.md),
[probe-read repair plan](2026-09-24-probe-read-intervals.md), and
[repeated verification log](2026-09-17-repeated-native-verification.md) retain evidence.

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

## Progressive streaming amendment — September 16

[Progressive sender adaptation](../specs/2026-09-16-progressive-streaming-design.md)
is now an explicit delivery requirement. Start at the lowest qualified live profile
without waiting for a probe, ramp cautiously with fresh measured headroom, reset to
the lowest profile after sustained excessive video-frame loss, and recover only
after a healthy hold. The researched baseline is OBS-style dynamic bitrate control;
SRT packet loss is separate from actual missing/late video frames.

Initial qualification thresholds are >5% missing/late frames in two seconds, or
<24 fresh fps over one second, with proactive queue/transport-pressure reductions.
These are product test settings, not an industry standard. Current five-second
worker windows cannot prove them; short-window telemetry is required. Existing
experimental high startup and gradual-only downshift do not satisfy this amendment.

- [ ] Qualify 240p/360p low-end profiles and the supported intermediate ladder.
- [ ] Add scoped short-window delivery health and a no-progress watchdog.
- [ ] Add direct minimum reset, precedence over trial rollback, recovery holds and
      bounded retry backoff to the existing policy.
- [ ] Start the actual native encoder at the minimum before its first sample;
      acknowledge actual dimensions and configuration during policy bootstrap.
- [x] Qualify candidate-cost, staged admission and two native upward/fault/minimum-reset/
      recovery cycles in the local instrumented fixture (`89926f4`, September 24).
- [ ] Extend that qualification to realistic networks, physical devices and remote
      workers before enabling production automatic adaptation.
- [ ] Measure startup, collapse/reset and recovery on this Mac, then physical
      phone/watch and portable remote workers, preserving independent local A/V.

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
scores. [Observed worker status](../../worker-status.md) is connected to the API and
native UI; remaining adversarial scoring integration cases still need their full
milestone audit.

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
- [x] Wait for source readiness; reconcile late/restarted workers; reject stale
      generation commands. Report actual first frames/output progress and failures.
- [x] Fix process supervision: spawn errors, awaited async handlers, serialized
      lifecycle changes, bounded restarts, and SIGTERM/SIGKILL based on process exit.
- [ ] Render initial 0–0 and scaled overlay placement for every qualified resolution.
      Use packaged/configured fonts instead of a hardcoded Linux font path on macOS.
- [x] Add local sink output and capture a playable 720p30 result. Prove point changes
      appear in decoded frames using timestamps/frame IDs. Verify audio and synchronization.
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
local CPU and VideoToolbox runs: initial score, point changes without encoder
restart, worker SIGKILL/encoder cleanup, API outage lease/recovery, source-loss
recovery, current-score restoration, and match-end shutdown.
Source-frame barcodes distinguish fresh frames from muxed/duplicated frames. See
[worker runbook](../../../apps/home-daemon/README.md). Both encoders now pass the
[ten-minute 720p30 media and A/V synchronization qualification](../../media-soak.md):
30 fresh fps, zero missing source frames, and all 597 five-second windows healthy.
Capability negotiation and sustained higher-resolution profiles remain pending. Native status
reporting now has separate API/Swift/simulator evidence. The Linux arm64 CPU container also starts and runs the compiled
media pipeline; other hosts and GPU drivers remain unqualified.

## Milestone 3: iPhone recording core and streaming adapter

**Files:** `ios/Project.yml`, `ios/Sources/Scorebug/`,
`ios/Packages/{ScorebugCore,ScorebugMedia,ScorebugStreaming}/`, `ios/Tests/`, `ios/UITests/`,
and native macOS `tools/media-harness/` and `tools/media-sdk-probe/` sharing the media core.

- [x] Run the HaishinKit compatibility experiment described in the architecture.
      Record exact dependency version, toolchain, API calls, supported platforms, and
      buffer/bitrate/statistics behavior. Pin resolution and add iOS simulator/device builds.
- [x] Extract testable capture-source, archive-sink, publishing, and clock interfaces;
      use fixture samples in Simulator and real AVFoundation capture on hardware.
- [x] Implement independent recording/publishing states and recording-first operation.
      Offline recording must not invoke game creation as a prerequisite.
- [x] Replace raw passthrough assumptions with valid encoding. Retain delegates and
      serialize writer access. Bound each queue and protect archive writes from live congestion.
- [x] Implement initialization/media segment storage, atomic completion, manifest,
      relaunch scan/recovery, playback/export, and safe storage-reserve handling.
- [x] Add camera role joining, truthful status, archive health/space, and explicit
      recording stop. Remote match end cannot silently discard a recording.
- [x] Feed timestamped motion/audio fixtures through real archive code. Kill the
      harness during writes at multiple boundaries; recover/export and fully decode.

**Checks:** Swift unit/fixture tests; iOS simulator/device compilation; native macOS
media tests; Simulator UI tests with injected capture; five forced-termination runs.
**Exit:** fixture archive remains playable after network failure and forced termination,
with measured tail loss at most five seconds. This is not yet phone hardware qualification.

**In progress:** the isolated [HaishinKit 2.2.5 compatibility probe](../../capture-sdk-compatibility.md)
passes macOS execution and generic iOS simulator/device compilation at deployment
target 17.0. It verifies actor/settings/PCM method signatures and package slices.
The [native dual-output experiment](../../native-dual-output.md) now exercises
simultaneous 1080p recording and SRT through independent bounded ingress queues.
Short normal, suspended-receiver, and unavailable-receiver cases preserve all
archive video frames and audio. Received bitrate changes from about 6.13 to
1.96 Mbps without reconfiguring recording. Full ARM64 simulator/iPhone linking
requires the now-declared C++ runtime; the resolved Intel simulator slice lacks
SRT symbols. The reusable [recording session](../../native-recording-session.md)
now owns offline startup, bounded sample admission, ordered retries, failure latching,
and graceful stop through an injectable archive sink. The fixture uses this same
session and also exercises recording without creating a publisher.
The [native Film/Score/Recordings app](../../native-film-app.md) now records offline,
preserves native scoring while filming, recovers after termination, and exports
and plays validated MP4s. Its workflows pass on iOS 17.5, 18.5, and 26.2 Simulators;
physical camera behavior remains unqualified. The
[native publishing integration](2026-09-14-native-publishing.md) now connects capture-role
reporting and native streaming controls. The complete native workflow passes on
iOS 17.5, 18.5, and 26.2, including decoded archive/live output and shutdown tails; see
[qualification evidence](../../native-streaming-qualification.md). Sustained
congestion/reconnection and adaptive quality remain pending.

Repeated validation exposed [SDK startup audio loss](../../native-dual-output.md):
the TS writer discards early packets and rebases each track independently. One run
lost five additional initial AAC packets and failed the unchanged 100 ms coverage
gate while the archive remained complete. The [maintained local correction](../../sdk-startup-patch.md)
now passes 35 vendor tests, three PCM clock tests, ARM64 Simulator/iPhone executable
links, and all five real-media scenarios. Both normal streams retain frames 0–419;
the nonzero-clock archive has no blank clock lead-in. Coverage and sync limits
remain unchanged. The [capture owner and iPhone adapter](../../native-capture-source.md)
now provide an injectable source, explicit common-clock startup, callback quiescence
before archive drain, and drop/interruption failure reporting. Eleven new lifecycle
tests bring the shared media suite to 71 tests. Camera configuration runs off the
UI thread and requires an explicit recording action for permissions. The
[native app](../../native-film-app.md) now connects Film, Score, and Recordings to
this source and the shared archive. Simulator workflows cover offline recording,
actual native scoring during capture, stop/relaunch, interrupted recovery, export,
and advancing playback. Model/library tests include slow-disk metrics and scan
exclusion so disk work does not block scoring or compete with capture. Production
publisher orchestration and capture-role registration are integrated, with 68 Core,
89 Media, 69 SDK, 13 Streaming, and 37 Film model tests passing. Next: adaptive
quality/reconnection, sustained load, native Watch scoring, and physical qualification.

The shared [native archive core and Mac fixture](../../native-archive.md) now encode
clean 1080p/30 H.264/AAC, commit recoverable fragments, and export a standard MP4.
The reviewed 14-second native run retained all 420 fresh video frames with a maximum
0.71 ms measured A/V offset. Five forced terminations recovered playable media;
the largest measured tail-loss bound was 2.60 seconds. Shared media unit tests and generic
iOS 17 simulator/device builds cover the native core. Camera integration, production
publishing orchestration, and app recovery UI are implemented; phone runtime media
and sustained operation remain unqualified.

## Milestone 4: Adaptive quality and measurable reliability

The [pure-policy implementation plan](2026-09-14-adaptive-quality-policy.md) starts
this milestone. Its [runtime telemetry contract](../../adaptive-telemetry.md)
records which measurements still need instrumentation before app enablement.

The [live ingress pressure slice](2026-09-15-live-ingress-pressure.md) now connects
time-weighted mailbox occupancy and per-kind dispositions to each publishing attempt
and the native app. The frozen snapshot now exports through the joined native
fixture writer and is required by its strict qualifier. Full Media passes 162 tests;
the export checkpoint passes 89 Film model and 400 tooling tests and the combined
iPhone/Watch Release build, with independent review. The ten-minute native gate now
passes at `11247df` without temporary export tracing: 19,018 archive and 18,620 acquired
live frames at 30 fps, zero source loss, complete encoded tail, and fully conserved
ingress accounting. These measurements do not establish link capacity or enable
adaptation. The [verified live bitrate primitive](2026-09-15-verified-live-bitrate.md)
is now implemented at `48155ea`: dedicated checked native writes/readback, publishing
identity guards, serialized updates and cancellation handling pass 105 SDK and 21
Streaming tests plus simulator/device builds. The five-scenario Mac dual-output run
`dual-output-tT1UH7` passes: both normal streams retain all 420 frames at approximately
30 fps while measured video rates fall from about 6.1 to 2.0 Mbps. All archives retain
420 frames and full audio, including stalled and absent receivers. These short runs
qualify the setter and archive independence, not runtime adaptation or physical
hardware. Production source-clock correlation, profile-transition boundaries and
qualified capacity/pressure inputs remain open.

**Files:** new `ios/Packages/ScorebugCore/Sources/ScorebugCore/QualityController.swift`,
its Swift tests, capture/publish adapter, worker telemetry/profile handling,
shared protocol telemetry fixtures, new `infra/local/netem/`,
`scripts/test-media.mjs`, and `scripts/analyze-media.mjs`.

- [x] Implement a pure policy controller with fake time and deterministic telemetry:
      30 fps target, 24 fps rolling floor, prompt decrease, 30-second recovery hysteresis,
      capacity headroom, supported profile limits, bounded queues, and outage state.
- [ ] Track captured/encoded/received fresh frames separately from muxed/duplicated
      frames. Track archive loss separately from stream loss and output reconnect gaps.
- [x] Implement verified live bitrate changes with native readback, lifecycle guards
      and measured dual-output continuity; keep archive settings independent.
- [ ] Validate profile-revision boundaries and resolution/keyframe transitions before
      feeding applied settings back to the automatic policy.
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

The [receiver-validated trial extension](2026-09-15-receiver-validated-quality-trials.md)
adds an explicit optional strategy for unknown passive capacity: 30 seconds of strong
receiver/pressure evidence can propose a <=10% same-profile bitrate trial, followed
by 10 actual seconds of confirmation under a bounded 22.5-second deadline, or sticky
rollback and a 60-second retry cooldown. The first probation window must start within
5.25 seconds of acknowledgment; see the [native timing correction](2026-09-16-native-trial-confirmation.md). Actual known-ceiling traces refute treating SRT packet-pair
estimates as spare bandwidth. This changes the intended upward-adaptation design;
the default legacy strategy and fixed native runtime remain unchanged. Runtime
frame boundaries/alignment, real trial transients, resolution changes and soak/radio
qualification remain open.

The [encoder configuration boundary slice](2026-09-15-encoder-configuration-boundaries.md)
adds immutable session/configuration identity to qualifying native completions and a
verified receipt naming the last raw submission before a bitrate write. This prepares
runtime frame partitioning; policy acknowledgment, pressure alignment and actual
trial/rollback qualification remain separate work before adaptation is enabled.

The [configuration-associated source interval slice](2026-09-15-configuration-source-intervals.md)
now carries this immutable identity through the production bounded source history.
Matched receiver intervals distinguish verified, unverified, mixed and unavailable
configurations, including native frames lost at the receiver and excluding the prior
anchor. Real fixture history agrees with native callbacks and decoded normal media;
this prepares runtime acknowledgment without enabling automatic adaptation.

The [owned bitrate update slice](2026-09-15-owned-bitrate-updates.md) adds typed native
receipts and session-owned mutation/deadline tasks. Invalid predispatch requests leave
live state intact; uncertain dispatched writes retire the live attempt and shutdown
joins the operation. The clean archive stays independent. Policy acknowledgment,
aligned pressure windows and automatic trial/rollback qualification remain open.

The [quality application owner](2026-09-15-quality-application-owner.md) now binds
verified initial/application receipts to policy revisions and current acknowledgment
time. It rejects stale advice and unsupported profile transitions, and terminal stop
prevents late commits. Outer evidence rejection invalidates recovery and preserves
trial rollback. The owner remains opt-in; source/pressure window alignment and actual
automatic media trials are next before the capture model can enable it.

The [source-aligned ingress pressure slice](2026-09-15-source-aligned-ingress-pressure.md)
adds exact queue integration over receiver-correlated capture boundaries, backed by
bounded scalar state history. Missing/evicted/phase-invalid coverage stays unknown;
querying closed history remains historical. This supplies the queue component of
future aligned policy windows. Transport/thermal/worker alignment and actual
automatic media qualification remain required.

The [measured-duration and transport alignment slice](2026-09-15-aligned-transport-and-window-duration.md)
permits measured policy inputs up to 5.25 seconds without clipping endpoints or
changing frame-rate/recovery thresholds. Retained native transport samples now
support exact-boundary sampled gauge queries with explicitly enclosing counters.
Thermal/worker pressure, receiver freshness and revision mapping still need runtime
integration before actual automatic trial/rollback qualification.

The [thermal history slice](2026-09-15-publishing-thermal-history.md) now collects
bounded OS thermal readings in the existing publication monitor. Historical queries
require retained brackets; missing, gapped and unknown readings cannot establish
nominal pressure. Shutdown freezes history and invalid diagnostics do not stop healthy
publication. Worker pressure, policy mapping/classification and actual automatic
trial/rollback qualification remain open.

The [worker encoder timing slice](2026-09-15-worker-encoder-timing.md) adds optional
bounded, timestamp-correlated submission/completion evidence through a separate
FFmpeg pipe. CPU and VideoToolbox use the same rational correlation; optional hardware
input-frame identities are not assumed.

The [worker processing correlation slice](2026-09-15-worker-processing-correlation.md)
now joins decoder source coordinates to encoder submissions and completions with shared
scope and bounded histories. It distinguishes deliberate cap omissions, pending work
and unknown arrival timing. Reusable local qualification passes CPU 25/30/60 fps and
VideoToolbox 30/60 fps with independent source probes, saved output barcodes and timing
replay. Overall worker pressure still requires runtime capability checks, fresh reports
and backend thresholds qualified on paced media; automatic adaptation remains unwired.

The [live processing window slice](2026-09-15-live-worker-processing-windows.md)
adds pipeline-owned intervals matching the native app's adjacent decoder boundaries,
with pending-to-complete updates and stable completed evidence. Worker startup now
checks optional FFmpeg statistics support with bounded cleanup and keeps unsupported
workers publishing without those diagnostics. A paced local fixture independently
checks real live windows. The [negotiated reporting slice](2026-09-15-worker-processing-reports.md)
now carries atomically sampled processing through the API into exactly matched native
source intervals, retaining decoder-age provenance through pending completion. Threshold
qualification and actual automatic trial/rollback remain next. Automatic adaptation is
still unwired.

The [quality telemetry binding](2026-09-16-quality-telemetry-binding.md) now forms
policy windows from exactly matched source intervals, verified configuration receipts
and aligned queue/thermal/transport evidence. Explicit caller-qualified pressure
limits preserve unknown evidence; capacity remains unknown. Actor-bound evaluation
separates policy ordinals from restarted worker decoder sequences, resets recovery on
scope changes and makes active trial rollback mandatory. Native bootstrap, report
coalescing, deadline polling and real adaptive-media impairment tests are next.

The pure [quality controller](../../adaptive-quality-policy.md) passes 20 focused
tests and the complete 88-test Core suite. Shared Core compiles for arm64_32 watchOS
10, and independent spec/quality reviews approve the source. It is not wired to live
media yet; missing runtime telemetry, profile transitions, impairment, and soak
qualification remain open. The rolling five-second output gate is separate from
the controller's measured 1–5.25-second input windows.

The [worker decoder measurements](../../worker-decoded-video.md) now pass software,
VideoToolbox, and CPU-container timestamp qualifications. Optional bounded windows
travel through the authenticated API to Swift models with per-attempt regression
guards and monotonic age. Capture/encoder correlation and report-transit age remain
open, so the broader fresh-frame tracking item and adaptive enablement stay pending.
The [local observation slice](2026-09-14-local-video-observations.md) now includes
the bounded accumulator, capture hook before archive admission, and actual
VideoToolbox completion hook wired through each app publishing attempt. All 115
Media package tests, 76 SDK tests, 16 Streaming tests, 46 Film model tests, and the
unsigned combined iPhone/Watch Release build pass. Fixed-profile native measurement
qualification passes on iPhone 14/iOS 17.5 at `artifacts/qa/native-app-PzWmTp`:
1,300 consecutive archive frames, 891 consecutive acquired live frames at 30 fps,
and five steady observation windows matching 750 decoded frames exactly. Startup
acquisition and two absent encoded tail frames remain explicit in the report.
Production source-range correlation and the other adaptive inputs remain open;
this does not close the broader runtime tracking gate.
The [report-age slice](2026-09-14-worker-report-age.md) now has its API foundation:
bounded server timing tokens and conservative window-age upper bounds, with 33
focused and 240 total API tests passing. Worker sampling order and native receipt
accounting are separate checkpoints. Sampling after token receipt and resampling
on API restart now pass 25 reporter tests and 132 total worker tests. Native receipt
and local-residence accounting now pass 119 Core and 50 Film model tests, the
arm64_32 watchOS 10 Core build, the combined unsigned iPhone/Watch Release build,
and both reviews. Running-app qualification remains before this closes the
report-transit gap.
The native proof exporter/comparator now passes 58 Film model and 135 tooling
tests, Release compilation and both reviews. Its first isolated run
(`native-app-mIqwM3`) failed because the archive queue overflowed at 34.90 seconds.
Failure preservation and bounded archive diagnostics are now implemented and
reviewed. An intervening run completed its archive but failed live tail alignment;
a separately reproduced control-poll stop race was fixed with 74 Film/119 Core
tests and the combined Release build passing. The maintained native age gate now
passes in `native-app-yCntsf` at `9679081`: 1,225 archive frames, 799 acquired live
frames at 30 fps, four steady observation windows matching 600 frames, and two
helper proof windows matching independent API readings. All media gates are
unchanged. The prior archive overflow and 13 absent terminal encoded frames remain
open diagnoses. Continue the [native tail plan](2026-09-14-native-tail-diagnosis.md);
production source mapping, other adaptive inputs, profile transitions, impairment
and sustained hardware qualification are still required before enabling adaptation.

The subsequent [snapshot-isolation fix](2026-09-14-archive-snapshot-isolation.md)
and [ten-minute qualification](2026-09-14-native-ten-minute-validation.md) now pass
at `a49408c` in `native-app-6o9S2U`: 18,947 consecutive archive frames, 18,532 consecutive
acquired live frames, 30 fps, zero archive rejected/dropped samples and complete live
terminal delivery. Both native report-age proofs match independent API evidence.
This single low-complexity simulator pass does not qualify motion load or physical
hardware. The new [motion workload](2026-09-14-native-motion-load-validation.md) is
implemented and reviewed at `879404d`; its first short native calibration failed
with visible live-image corruption, worker restarts and measured 46.278 Mbps output
against a 6 Mbps request. Archive evidence preservation also failed during simulator
teardown; a state transition race is suspected. Follow the [failure-evidence plan](2026-09-14-motion-failure-evidence.md)
before longer motion runs or enabling adaptation.
The unchanged repeat `native-app-KIC4hs` at `6f1bcd5` preserved a complete, clean
1,190-frame local archive while live media failed A/V tail coverage and frame
identity checks. Failure evidence preservation now works; its bounded shutdown
retry is unit-tested. A separate [structured workload calibration](2026-09-14-structured-motion-calibration.md)
is planned near the intended rates, preserving the original overload case.

The blocks16 workload now has a complete uninstrumented 180-second pass and a
complete instrumented 600-second pass (`native-app-Roau2o` at `02afc61`). The latter
preserves 18,935 archive frames and 18,534 acquired live frames at 30 fps, complete
terminal delivery and all frozen workload/media gates. Export reaches the UI in
40.796 seconds under the unchanged 45-second test wait. Temporary tracing is removed;
the prior intermittent export timeout remains unexplained. See the
[structured-motion evidence](2026-09-15-structured-motion-edges.md) and next
[live ingress pressure slice](2026-09-15-live-ingress-pressure.md). Automatic quality
changes remain disabled; uninstrumented long-run and physical qualification remain.

## Milestone 5: Watch scoring and complete simulator workflows

[Networking design notes](../../watch-networking-design.md) map the existing shared
client to direct/companion routes and distinguish Simulator protocol coverage from
physical paired-device transfer and suspension tests.

The [pairing foundation](../../watch-pairing-foundation.md) now supplies distinct
Watch credentials and durable setup recovery. Real Swift HTTP scoring passed after
a lost pairing reply and API/client restart. The [native Watch app and companion
setup adapters](../../native-watch-app.md) are implemented. The first normal-polling
Series 7 41 mm/watchOS 10.5 UI run passed real redemption, scoring, rejection,
Keychain relaunch recovery, and end-match. Its initial setup was injected; actual
companion exchange and complete media workflows remain open.
The real companion/recording probe now exists, but both the iOS 17.5/watchOS 10.5
and iOS 26.2/watchOS 26.2 pairs fail before setup transfer with a Watch simulator
companion-database error. Sequential preinstallation did not resolve it; Xcode's
no-reinstallation mode rejects simulator destinations. See the native Watch evidence
for exact artifacts. These failures leave the paired workflow gate open.

Configured native scoring now has a bounded paired-phone relay alongside direct
HTTP, durable receipt-first recovery and peer-change invalidation. An injected
two-pair test preserves one real local A/V recording while Watch A recovers a lost
reply and Watch B takes over and scores. Core passes 194 tests, Watch model/gate 43,
phone companion 34 and Film model 86; the final Release iPhone/Watch build passes.
See the [native relay checkpoint](2026-09-15-native-watch-relay.md) for evidence and
limits. This is functional model/media integration, not a successful physical WC
or paired-simulator workflow. The separately scoped
[bootstrap relay](2026-09-15-watch-bootstrap-relay.md) now also supports initial setup
and exact redemption recovery through the paired phone. Its current checkpoint
passes 233 Core, 43 phone companion and 45 Watch model/gate tests, plus the combined
native Release build. Full FilmModels also passes all 87 tests, including the
injected native setup/lost-reply/recovery/score flow. Physical networking
qualification remains a distinct gate.

**Files:** `ios/Project.yml`, shared `ios/Packages/ScorebugCore/` scoring models/client,
new `ios/Sources/ScorebugWatch/`, `ios/Sources/Scorebug/Companion/`,
`ios/WatchTests/`, `ios/WatchUITests/`, and native iPhone scoring tests from milestone 1.

- [x] Add a watchOS target independent of camera/media dependencies and a companion
      setup/join flow within the full native iPhone app. Keep Film and Score roles separate.
- [x] Set iOS 17/watchOS 10 deployment targets and availability-guard newer APIs.
      Test Series 7 41 mm and Ultra 2 layouts, plus an SE-sized screen. Add watchOS 11
      runtime coverage. Series 7 41 mm/watchOS 11.5 passed at `artifacts/qa/native-watch-LAbbIq`.
- [x] Implement HTTP(S) scoring and snapshot refresh on wake. Use scoped Keychain
      credentials and an expiring pairing code; optionally transfer setup with WatchConnectivity.
- [x] Add home/away score, set/match display, undo, confirmed/pending states, retry,
      end-set confirmation, and guarded end-match. Do not require a WebSocket on watchOS.
- [x] Persist uncertain commands across suspension and reuse IDs across HTTP/companion
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

2026-09-14 terminal-delivery checkpoint: `4884734` adds reviewed optional worker
terminal diagnostics. Native run `native-app-VrXKA9` passes all unchanged gates
(1,252 archive / 856 live frames at 30 fps), while worker decoder/output progress
both count 869. A separate short-burst experiment supports recorder-side disconnect
loss in the MediaMTX test sink, with exact native attribution still open. Qualify an
independent terminal-complete RTMP recorder before changing app shutdown behavior;
full findings and limitations are in the [native tail plan](2026-09-14-native-tail-diagnosis.md).

Independent recorder follow-up: `native-app-lyB1el` at efcda56 passes the iPhone 14 /
iOS 17.5 native fixture using `SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1`. All 894 worker
video frames are saved through the native encoder's last frame; the 60-frame
acquisition interval remains explicit. The clean archive retains all 1308 frames,
with no rejected/dropped samples. A/V, scoring, export and age-proof checks pass.
The worker pipeline was terminated gracefully (FFmpeg 255); the receiver ended
naturally (0). See the [native tail plan](2026-09-14-native-tail-diagnosis.md) for
failed precursor runs, recorder fixes, evidence and limits. Sustained native archive
pressure qualification is next; adaptive quality and physical Watch pairing remain
open. The default comparative MediaMTX test endpoint is retained.

The next pressure checkpoint also passes: `native-app-azEu6Y` at `7905d55` performs a
180-second simultaneous hold with the direct recorder. It preserves all 6352 archive
frames and 5968 live frames through the last encoded frame; all 39 steady windows are
30 fps, native scoring/export/A/V and age proofs pass, and archive diagnostics show
zero rejected/dropped samples. The earlier overflow remains unexplained. See the
[sustained native plan](2026-09-14-native-sustained-validation.md) for evidence,
explicit acquisition/initial encoder coverage, history limits and ten-minute next
steps. No adaptive/hardware/Watch or remote-host qualification is implied.

The 600-second attempt `native-app-GyuAnW` at `a2ac272` reproduces archive overflow
at 616.840 seconds of recording. Complete failure evidence survives; recovery gives
616 seconds of consecutive 30 fps video, while 25 accepted terminal video frames
are absent from the recovered archive. Live retains every worker frame through its
last encoded frame. A half-second persistence overlaps a blocked archive append;
a status-read lock dependency is now the focused regression target. See the
[overflow evidence](2026-09-14-native-archive-overflow-diagnosis.md#ten-minute-reproduction-with-recoverable-evidence)
and [snapshot isolation plan](2026-09-14-archive-snapshot-isolation.md). The long
qualification remains failed. This simple fixture also compresses far below the
configured bitrate, so motion-heavy and physical-camera load tests remain required.

The complete ten-minute repeat now passes: `native-app-6o9S2U` at `a49408c` retains
all 18947 clean archive frames and all 18532 worker frames through the final encoded
frame, at 30 fps. All 37894 archive samples are written with zero rejection/drop;
native scoring, post-stream recording, export, A/V, observation and age proofs pass.
The work fixes a deterministic status-read/writer-lock dependency and a separate
long-run validator capacity mismatch; it does not prove all possible persistence
stalls are eliminated. Full evidence and retained failed runs are in the
[snapshot isolation plan](2026-09-14-archive-snapshot-isolation.md#complete-ten-minute-repeat-pass).
The reviewed [motion workload plan](2026-09-14-native-motion-load-validation.md) is
next because current actual encoded payload rates are far below configured rates.
Physical phone/Watch, adaptive quality and other hosts remain unqualified.

### Native adaptive control checkpoint

The [opt-in native quality loop](2026-09-16-native-quality-loop.md) now passes an
actual iPhone 14/iOS 17.5 simulator trial and rollback with clean local recording,
native scoring, complete A/V output and independent pressure/source validation.
A 100 ms local fixture status cadence fits the unchanged freshness budget; normal
worker/phone polling defaults are preserved. The 15-second trial deadline was too
short to confirm ten full seconds of post-change source coverage, so confirmation
timing is the next gate before motion and impairment qualification. This does not
enable adaptive production behavior or finish physical phone/Watch/remote-host work.

The [confirmation timing correction](2026-09-16-native-trial-confirmation.md) now
passes confirmation-required barcode and structured-motion native runs. The motion
run preserves 3696 archive / 3266 acquired live frames at 30 fps, with roughly 12 Mbps
local and 7.3–7.6 Mbps live payload. One 6.6 Mbps trial is confirmed; a subsequent 7.26 Mbps
trial is unconfirmed at stop. Network impairment is next, including the driver's
need for an independently qualified local-pressure decrease path when matched
receiver windows expire. Longer adaptive soaks and resolution/device/host gates remain.

The [local-pressure fallback](2026-09-16-local-pressure-fallback.md) is now connected
to the opt-in native loop, with shared source/local ordering and independent raw
pressure replay. All 178 FilmModel and 869 tooling tests pass. A fresh structured-
motion confirmation run preserves 3607 local / 3209 acquired live frames at 30 fps
with zero qualified loss. Its healthy connection triggers no local reduction and
confirms one 6.6 Mbps trial. Actual network impairment/downward adaptation/recovery
is the next gate; physical phone/Watch and remote-host qualification remain open.

The [publishing-only proxy route](2026-09-16-native-uplink-impairment.md) now passes
an actual 90-second structured-motion simulator run: 3671 clean archive / 3236
acquired live frames at 30 fps, zero qualified loss, native score overlay, complete
A/V output and one confirmed 6.6 Mbps trial. The worker keeps its direct reader
connection. All proxy counters conserve, with no drops/errors/foreign peers and
joined closure. All 180 FilmModel / 872 tooling tests and unsigned Apple Release
pass. This is a pass-through baseline; scheduled bandwidth pressure and recovery
remain the next gate.

The first [scheduled 4 Mbps diagnostic](2026-09-16-native-uplink-impairment.md#first-limited-rate-result-live-recovery-fails)
fails live recovery: bitrate settings decrease, but output stalls and publishing
ends before bandwidth returns. The retained archive recovers 6600 consecutive
frames (220 seconds), with full decode, coverage and sync checks. This is a clean
committed prefix after an interrupted UI test, not a normally finalized capture.
All 883 tooling tests pass for the bounded scheduler and phase verifier. The next
gate measures achieved encoder payload under controlled rate changes; the retained
transport counters alone cannot identify the cause of insufficient rate reduction.

The [isolated encoder diagnostic](2026-09-16-encoder-payload-probe.md#qualified-isolated-result)
now measures all 2402 compressed samples with exact configuration/source ownership
and qualified 30 fps pacing. On iPhone 14/iOS 17.5 Simulator, requesting 1.5 Mbps
produces 5.576 Mbps both after a live reduction and in a fresh encoder started at
1.5 Mbps. The problem therefore is not solely a dynamic update, and insufficient
reduction is already present before transport. Native encoder/rate-control versus
content constraints remain to be distinguished. Network recovery, production
adaptation, physical phone/Watch and other-host qualification remain open.

Further [native encoder comparisons](2026-09-16-encoder-native-properties.md)
reproduce the payload behavior on iOS 17.5 and 26.2 simulators. Moving the expected
frame-rate write before preparation has no effect. A fresh 720p encoder actually
produces more payload for the same structured source than 1080p (7.614 versus
5.576 Mbps), so neither change is promoted as a fix. All four diagnostic runs
qualify 7208 frames, and 897 tooling tests pass. Native property evidence is now
bounded and tied to encoder-session ownership. Physical encoder behavior, reliable
live recovery and archive finalization during failed live tests remain next gates.

The [failed-live finalization checkpoint](2026-09-16-native-failure-finalization.md)
now preserves a normally stopped/exported archive during the scheduled 4 Mbps
failure: 8020 consecutive frames (267.333 seconds) at 30 fps, complete A/V decode
and sync, every accepted sample persisted and zero queue rejection/drop. The
healthy baseline also passes with 3608 local / 3208 acquired live frames. All 901
tooling tests pass. Bounded worker/publication histories now survive workflow
failure. Streaming still fails recovery and retains its nonzero test result;
actual encoder behavior remains the next correction target. The attached phone
now reports iOS 26.7; selected Xcode 26.2 cannot mount its developer disk image,
so installed signing identities alone do not enable physical phone/Watch tests.

The [low-latency and half-resolution comparison](2026-09-16-encoder-low-latency.md)
finds a candidate fallback: fresh 960×540 reduces actual compressed payload from
5.576 to 3.521 Mbps for the same structured source, with all 1202 output frames and
approximately 30 fps pacing. This does not yet prove adequate headroom on a 4 Mbps
wire link or decoded visual quality. The low-latency encoder request is unavailable
in the tested iOS 17.5 simulator (`-12908`); both failed attempts are retained.
All 904 tooling tests and prior raw evidence replay pass. Next qualify this reduced
live profile through the complete pipeline while local recording remains 1080p,
then implement and test bounded dynamic profile changes. Production adaptation,
actual bandwidth recovery and physical phone/Watch/remote-host gates remain open.

The [fixed reduced-profile integration](2026-09-16-native-reduced-profile.md) now
passes both pass-through and scheduled 4 Mbps simulator diagnostics. Actual native
compressed-sample evidence confirms 960×540 before worker scaling. During the
limited run all 5990 acquired live frames survive through the final encoded frame,
while the independent 1080p archive retains all 6365 frames and normally finalizes;
both remain approximately 30 fps with zero qualified source loss. The 60-second
phone-side limit averages 3.880 Mbps wire traffic with zero proxy drops. This
establishes fixed-profile tolerance for this fixture, not automatic adaptation or
a broad network capacity guarantee. The next gate is bounded dynamic profile
replacement and recovery while preserving archive independence. Production
activation, physical phone/Watch and other-host qualification remain open.

The default 1080p regression also passes with 3635 local / 3209 live frames and two
confirmed native bitrate trials, and the unsigned combined iPhone/Watch Release
build succeeds. This checkpoint has 55 streaming, 135 vendor, 183 app-model, 334
serialized worker and 908 tooling tests passing, plus worker typechecking. Retained
parallel worker timing failures are documented in the reduced-profile plan.

The [native resolution transition experiment](2026-09-16-native-resolution-transitions.md)
now preserves all 3600 frames across iOS 17.5 and 26.2 runs of 1080p→540p→1080p.
Actual dimensions, ordered source identity, distinct encoder sessions and sync/IDR
starts qualify, with settled payload 6.020→3.521→6.020 Mbps. Transitions also expose
349–419 ms compressed-output delivery gaps and 41–107 ms first-append blocking.
All 910 tooling tests pass. This is isolated encoder metadata evidence, not decoded
pipeline or adaptive recovery qualification. Next prove outstanding-callback and
stop/cancellation lifetime behavior, then integrate bounded profile changes through
the worker while preserving the independent 1080p archive. Production selection,
physical phone/Watch and other-host gates remain open.

The [explicit encoder replacement lifetime](2026-09-16-encoder-replacement-lifetime.md)
now prepares, drains off the owner and commits only the same healthy native session.
Deterministic tests cover pending callbacks, competing mutations, finish in both
orders, native errors and cancelled stop/restart. Both iOS 17.5 and 26.2 paced
experiments preserve all 3600 frames with old callbacks completed before drain return.
Drains take about 30–89 ms and subsequent first appends 0.95–1.79 ms; output gaps
remain 348–417 ms. All 145 SDK / 55 streaming / 914 tooling tests and unsigned
combined Apple Release pass. SDK patch provenance again round-trips all 162 original
hashes. Next integrate stream-owned ingress pause/deadline/cancellation and actual
profile receipts, then qualify downstream decode and independent recording before
automatic adaptation. Production profile selection remains disabled.

The [stream-owned profile replacement](2026-09-16-stream-profile-replacement.md)
now pauses bounded raw-video consumption during native drain while audio/compressed
output consumers continue. Actual first new-format output and a current encoder
revision establish the receipt; staged settings alone cannot. Cancellation, deadline,
finish and close reject stale state and join native work before reuse. Ten new tests
cover these lifetimes, native errors, counted ingress evictions and continued AAC
transport. All 155 SDK / 55 streaming tests and unsigned combined Apple Release pass.
The app still uses fixed profiles. Next qualify paced down/up transitions through
worker decoding with independent full-resolution local recording, then pressure and
recovery before automatic selection. No seamless transition or physical-device
qualification is claimed by this SDK checkpoint.

The [typed app profile API](2026-09-16-app-profile-transitions.md) now carries native
format/source/encoder receipts through both streaming adapters and PublishingSession.
Bitrate and resolution mutations share admission and shutdown ownership. New tests
reject overlapping mutations, stale source or encoder history, invalid native
receipts and stopped startup. Stop joins late native startup/profile work before
final closure. Source review approved the corrected lifecycle and receipt guards.
Validation passes: 252 media tests, 61 streaming tests, 183 app-model tests and the
unsigned combined iPhone/Watch Release build. This checkpoint supplies the app API;
production still selects fixed profiles. Next add the controlled simulator down/up
fixture and qualify decoded worker output plus independent clean local recording.

The [controlled app transition experiment](2026-09-16-app-profile-transitions.md)
now passes end to end on iPhone 14 / iOS 17.5: actual native 1080→540→1080 sessions,
independently matched callback identities and receipts, decoded worker output,
scoring overlay, A/V sync, and normally finalized independent 1080p recording.
`native-app-HCtRdN` preserves 3378 native frames; all 3318 frames after the explicit
60-frame stream acquisition arrive in the recorder. The archive preserves all
3720 frames. Both media outputs run at approximately 30 fps with zero qualified
source loss. The two compressed-output arrival pauses are 339/419 ms; receiver
wall-clock continuity and automatic adaptation are not inferred from source PTS.

The experiment exposed and fixed FFmpeg filter-state resets and stale padding on
input format changes. Fixed-canvas workers now preserve telemetry/frame-selector
state and evaluate padding per frame; strict decoder/encoder ordinal checks remain.
Software and VideoToolbox probes use square-pixel geometry changes on odd 60fps source
indices and retain all 180 inputs and precisely 90 selected output identities.
191 app-model / 334 worker / 919 tooling tests, type checking and the combined Apple
Release build pass. Next qualify pressure/recovery and newer-runtime behavior before
automatic resolution selection, followed by the remaining soak/device/host gates.

The controlled transition experiment also passes on iOS 26.2 in `native-app-yITrxX`:
3461 native frames across actual 1080→540→1080 sessions, all 3401 acquired live
frames delivered, and 3821 clean 1080p archive frames normally finalized/exported.
Both outputs sustain approximately 30 fps with zero qualified source loss and
matched A/V markers. Compressed-output pauses remain 340/429 ms; this proves
controlled transitions, not automatic congestion recovery or receiver wall-clock
continuity.

The [quality-owner profile binding](2026-09-16-quality-profile-binding.md) now
supports a native resolution replacement followed by a verified bitrate write
on the exact new encoder, under one deadline and one policy revision. Invalid
receipts, expiry, stop or cancellation retire the live attempt without committing
intermediate settings. All 198 app-model tests and the unsigned combined Apple
Release build pass; review found no blocking issues. The app's automatic fixture
still selects one profile. Next add measured multi-profile pressure/recovery
qualification before production activation; the original rate4m recovery failure
is not yet resolved by an end-to-end adaptive test.

The [adaptive profile fixture](2026-09-16-adaptive-profile-fixture.md) now exercises
pressure-driven native resolution changes through the quality owner. Its first
240-second pressure hold (`native-app-TffI7s`) downshifted 1080p to 540p, but the
worker decoder ended and recovery remains unqualified. The one-shot destination
recorder also prevents worker retries, independently of the unresolved first exit.
The local archive passed complete verification: 8712 consecutive 1080p/30 frames,
290.4 seconds, all 145 A/V markers, no archive drops. Core (284), model (200), tooling
(933) and unsigned iPhone/Watch Release checks pass. Next diagnose receiver input
termination and retry recording; production adaptation remains disabled.

The [receiver diagnostic follow-up](2026-09-16-receiver-failure-diagnostics.md)
reproduced the failure in `native-app-NeLIkj`: after packet-decoding warnings, the
SRT reader terminates on H.264 DTS extraction (`too many reordered frames (29)`),
and the worker reports an input I/O error. Later retries fail to open the closed
one-shot recording listener. Fixed-category diagnostics now distinguish those
failures without raw logs; shutdown review fixes and 339 worker/934 tooling tests
plus worker build pass. Next reproduce and repair reader resynchronization and
reconnectable fixture recording before rerunning adaptive recovery qualification.

The [bounded H.264 reader recovery](2026-09-16-ingest-h264-recovery.md) now
reproduces and repairs the DTS-extractor termination caused by missing pictures.
The integrated reader test preserves original timestamps and all test audio units,
resumes video at a validated IDR, and leaves missing frames visible. Relevant Go
and race suites plus 934 tooling tests pass; the pinned patch round-trips exactly.
ARM64/AMD64 images build and launch (AMD64 via local emulation), and all three
relay-clock cases pass with the recovery image.

The native pressure repeat (`native-app-JD0l78`) confirms same-reader recovery
after PES damage and healthy 540p receiver windows. It then fails during the higher
profile trial. The trial had only 227 ms remaining on its source-window-based
recommendation deadline; the underlying native failure needs a causal reproduction.
The live UI check remains failed, without relaxed media gates. Local recording was
stopped/exported and independently passed: all 9824 consecutive 1080p/30 frames
(327.47 seconds), all 163 A/V markers, and no archive drops. One receiver window
contains only 28 fresh frames in five seconds, and the early publishing stop leaves
recovery-traffic coverage incomplete. Next
resolve fresh recommendation admission versus bounded native execution, retain
reconnectable destination work, and rerun adaptive pressure before production
activation. Long soaks, physical phone/Watch and other-host gates remain open.

The [quality application admission fix](2026-09-16-quality-application-admission.md)
reproduces the prior native change failure and separates fresh-advice admission
from a single-use two-second completion budget. Core (292), app-model (201), tooling
(949), unsigned combined iPhone/Watch Release and corrected read-only review pass.
The unchanged pressure repeat (`native-app-9wQGR3`) now completes the native UI
workflow: downshift, higher trial, rollback, later higher trial and controller
confirmation, then normal stop. Actual upgrades take 448/467 ms despite only
137/91 ms remaining on their original fresh advice; bounded completion receipts
verify the fix. The archive preserves all 8136 consecutive 1080p/30 frames over
271.2 seconds and all 135 A/V markers, with no archive drops.

Live qualification still fails: 225 ms A/V coverage discrepancy, 296-frame count
deficit after acquisition plus 43 non-increasing barcodes, and a worst five-second
receiver window at 8 fps. These gates remain unchanged. Next improve timely local
pressure response and verify actual media recovery; controller confirmation alone
does not authorize production adaptation. Physical phone/Watch, longer soaks and
other-host gates remain separate.

The [rapid local pressure checkpoint](2026-09-16-rapid-local-pressure.md) shortens
only downward local evidence to one second and independently verifies the new
version-three contract. All 203 app-model / 959 tooling tests and the unsigned
combined Apple Release build pass. Native pressure run `native-app-HAW17U` completes
its UI workflow and rolls back its first higher trial in 2.53 seconds instead of
about six. The independent archive preserves all 8110 consecutive 1080p/30 frames
and all 135 A/V markers, with no drops.

Live media still fails: 292 ms A/V end discrepancy, a 221-frame count deficit plus
46 non-increasing source barcodes, and a worst five-second receiver window at 5 fps.
The shorter decision window is verified, but is insufficient to protect delivery.
Next isolate earlier congestion detection using actual statistics sampling and
transport thresholds, then backlog/keyframe recovery as indicated by evidence.
Production adaptation, longer soaks, physical devices and remote hosts remain open.

The [fresh transport statistics checkpoint](2026-09-16-fresh-transport-statistics.md)
adds explicit native demand reads to the existing health loop while retaining the
SDK monitor's one-second cadence and counter semantics. All 159 SDK / 61 streaming
tests, unsigned combined Apple Release, read-only review and exact upstream patch
verification pass. Native run `native-app-KyNaNh` confirms 255 ms median actual
collection intervals and a 1.70-second trial rollback. The independent archive
preserves all 8168 consecutive 1080p/30 frames and all 136 A/V markers without drops.

Live A/V coverage now passes, but strict frame identity still fails (142-frame count
deficit plus 55 non-increasing barcodes), and the worst receiver window is 15.2 fps.
Faster sampling is verified, not sufficient recovery. Next measure the negotiated
SRT delivery delay and compare it with observed buildup and pressure thresholds;
the source default is 120 ms but the runtime value was not retained. Keep any
threshold and latency experiments separate. Production activation, device/host
qualification and long soaks remain open.

The [negotiated delay checkpoint](2026-09-16-negotiated-srt-delay.md) retains the
actual native sender delivery delay on each timestamped transport sample. Model,
export and independent-verifier checks pass (253 media, 61 streaming, 204 app-model,
968 tooling), as do the unsigned Apple Release build and read-only review. Native
run `native-app-HUreDi` measures 120 ms in all 998 retained samples. Its clean archive
preserves all 8105 consecutive 1080p/30 frames and all 134 A/V markers without drops.
Live media remains failed: 124 ms end coverage discrepancy, 130-frame count deficit
plus 48 non-increasing barcodes, and worst receiver cadence 14.2 fps.

The measured response budgets now guide the next design: one second of post-change
local evidence plus roughly half a second of geometry-application time cannot
reliably protect a 120 ms recovery delay, while accepted receiver evidence is
already about 1.82 seconds old under a two-second cap. Develop a shorter strictly
downward-only local pressure path using actual transport recovery-budget evidence;
preserve longer source/receiver health checks and upward probation. Earlier native
rate-control limitations remain relevant; do not replace the profile-transition
stress test with a trivially passing bitrate request or relax media qualification.
Production adaptation, long soaks, physical devices and other hosts remain open.

The [faster downward pressure checkpoint](2026-09-16-fast-downward-pressure.md)
adds an explicitly downward-only quarter-second core/app path and simulator RTT
pressure bound to each sample's positive measured delivery delay. Version-four
raw replay preserves all older contracts. 294 core, 208 app-model and 979 tooling
tests, unsigned combined Apple Release and read-only review pass.

In unchanged run `native-app-QEo8uZ`, the first decrease completes about 0.95 seconds
earlier and trial rollback improves from 1.70 to 0.90 seconds. All 8116 archive
frames and 135 A/V markers survive with no archive drops. The worst five-second
receiver window improves from 14.2 to 25 fps; live A/V coverage passes. Full live
qualification still fails on source-identity/presentation cadence: 36-frame count
deficit, but 67 unique positions absent and 31 repeated observations, including 11
non-increasing barcodes. The remaining anomalies cluster at the two downward
geometry changes. Next investigate damaged access-unit/IDR recovery and transport
recovery time together with the bounded receiver freshness budget. Keep production
adaptation disabled and all device/host/soak requirements open.

The [decoder damage diagnostics checkpoint](2026-09-16-decoder-damage-diagnostics.md)
adds bounded missing-reference, invalid-slice and concealment categories, with
INFO diagnostics only for the existing opt-in terminal collector. Worker tests
(341), tooling tests (980), worker build and read-only review pass. Native run
`native-app-OY8jUj` records 175 decode-error and 30 concealment messages while its
PTS telemetry reports unique frames. Full live media still fails: 98 absent source
identities, 35 repeated observations and a worst receiver window of 18.2 fps.
Thus the prior 25-fps run is a promising observation, not sustained qualification.
The clean archive again preserves every frame (8123) and all 135 A/V markers.

Both SRT legs are observed at 120 ms; accepted source evidence remains about
1.82 seconds old. Next measure worker decoder frame-thread buffering separately
from transport recovery delay. A validated slice-threading mode may recover
freshness headroom for a later transport experiment without changing any existing
freshness/media gates. No production adaptation, physical-device or remote-host
completion is claimed.

The [input decoder threading checkpoint](2026-09-16-worker-decoder-threading.md)
adds explicit automatic/slice input decoding while preserving automatic defaults.
343 worker tests, 981 tooling tests, worker build, review and real software plus
VideoToolbox resolution/aspect-transition media checks pass. Native pressure run
`native-app-a0fhIU` reduces median accepted receiver evidence age from 1.824 to
1.324 seconds. All 8153 clean archive frames and 135 A/V markers remain intact.

Streaming still fails: worst receiver window 20.2 fps, 57 absent source identities,
five repeated observations and −169.8 ms end coverage discrepancy. The worker logs
no concealment in this run, but ingest reports damaged PES and timing recovery;
zero decoder messages do not qualify delivery. Next use the measured freshness
headroom for a separate publish-leg SRT recovery-delay experiment, keeping read-leg
settings and every media/freshness gate unchanged. Production adaptation, physical
devices, long soaks and other hosts remain unqualified.

The [publishing recovery-delay checkpoint](2026-09-16-publish-recovery-delay.md)
adds an optional bounded native publishing peer delay; unset defaults, read-leg
settings and capability identity remain unchanged. All 388 API and 982 tooling
tests, the API build and read-only review pass. In native run `native-app-wkcOi6`,
actual native/relay gauges confirm 400 ms publishing recovery and 120 ms read-leg
delay. All 8152 archive frames and 135 A/V timing markers remain intact.

Median receiver evidence age rises to 1.616 seconds under the unchanged two-second
cap. Live end coverage passes and worst receiver cadence is 22 fps, but picture
integrity worsens (142 absent identities, 81 repeated observations) and full live
qualification fails. Thus 400 ms is not promoted to a default or called reliable.
Next inspect encoded-frame bursts and packet/drop/IDR recovery around the downward
geometry changes; compare native receipts and source identities before increasing
buffering again. Production adaptation, physical devices, long soaks and remote
hosts remain unqualified.

The [uplink queue timeline checkpoint](2026-09-16-uplink-queue-timeline.md)
adds bounded payload-free 100-ms event bins and independent chronological/counter
validation to the local test proxy. All 990 tooling tests and final review pass.
In unchanged 400-ms run `native-app-4J8Soo`, both timelines reconcile without
omission. The forward queue drops 1190 overflow packets during two pressure
clusters; a 100-ms bin receives 374 KB while forwarding 51 KB, and observed queue
residence reaches 526 ms. Reverse traffic has no drops. Receiver counters include
late/duplicate traffic and cannot be equated with unique missing video packets.

All 8165 archive frames and 135 audio markers remain intact. Live still fails at
22-fps worst receiver cadence, 102 absent identities, 46 repeated observations and
−145.3 ms end coverage. Next observe actual native SRT pacing settings and distinguish
original/retransmitted/control packet pressure, then test bounded sender pacing.
Do not enlarge queues, freshness limits, or declare the 400-ms setting reliable.
Production adaptation and device/host/soak qualification remain open.

The [relative sender-pacing checkpoint](2026-09-16-relative-sender-pacing.md)
adds opt-in publish-only `maxbw=0` plus actual native pacing diagnostics; defaults
and quality rules remain unchanged. All 391 API, 254 media, 61 streaming, 209
app-model and 1009 tooling tests pass, as do the API/combined Apple Release builds
and review. Native run `native-app-d4raOd` measures effective pacing at 4.78–12.24
Mbps and reduces peak 100-ms traffic from 374 KB to 138 KB and overflows from 1190
to 898, while queue residence remains about 526 ms.

The archive preserves all 8195 frames and 136 audio markers. Live still fails:
14.6-fps worst receiver cadence, 174 absent source identities and 32 repeated
observations, despite passing end coverage. Relative pacing is not promoted.
Next retain actual compressed-frame byte size and keyframe/IDR evidence around
geometry changes before another transport-setting experiment. Prior simulator
unsupported-property findings remain applicable; physical encoder behavior is
still unproven. Production adaptation and device/host/soak requirements stay open.

The [compressed-frame checkpoint](2026-09-16-compressed-frame-evidence.md) adds bounded actual pre-mux byte counts and native sync metadata, with independent phase/source/time reconciliation. All 160 SDK, 61 streaming, 211 app-model and 1014 tooling tests pass, along with the combined unsigned Apple Release build, exact SDK provenance verification and review.

With unchanged settings, `native-app-98ZoEn` preserves all 8176 archive frames and 136 audio markers, but live still fails: 12-fps worst cadence, 171 absent identities and −108.1 ms end coverage. All 7799 compressed records reconcile. Individual frames are at most 47 KB; larger bursts are groups of frames released at encoder drain, 301–395 ms ahead of normal source cadence. Two long loss ranges resume at measured native sync points. The short upward trial produces 7.82 Mbps of video alone on the 4 Mbps link.

Next test opt-in pre-mux source-cadence pacing with bounded ownership and joined cancellation/finish, while preserving every frame and timestamp. A recorded-data replay reduces batches but is not live qualification. Upward trials must separately account for measured profile cost and available capacity. Production adaptation remains disabled; device/Watch/host/soak requirements stay open.

The [source-cadence pacing checkpoint](2026-09-16-source-cadence-pacing.md) adds an opt-in bounded scheduler to the existing native encoded-video consumer. It preserves the initial source clock across replacements, cancels stale waits, and retains a 16-frame/2 MiB-per-frame encoder queue only in this mode; ordinary defaults and transport queues stay unchanged. All 1458 SDK/streaming/app-model/tooling tests and the combined unsigned Apple Release build pass, with exact provenance and review.

In `native-app-xJ7FLN`, all 7828 frames prove actual pacing, and the final ten frames of each phase span about 300 ms instead of 26–80 ms. All 8203 archive frames and 136 audio markers remain intact. Live still fails at 12.8-fps worst cadence, 167 absent identities, 37 repeated observations and −158.2 ms end coverage. The 7.85-Mbps upward trial still overloads the 4-Mbps link. Keep pacing opt-in and production adaptation disabled.

Next establish fresh usable headroom against measured candidate-profile cost before upgrading. First qualify actual SRT bandwidth/ACK evidence against the known rate phases; use bounded probing if it cannot establish capacity. Neither a pacing ceiling nor requested bitrate is sufficient, and disabling all future upgrades would not satisfy the highest-sustainable-quality requirement. Device/Watch/host/soak qualification remains open.

The [native bandwidth estimate checkpoint](2026-09-16-native-bandwidth-estimate.md)
retains the existing actual SRT estimate in bounded diagnostic evidence without
changing controller decisions. All 1239 relevant tests pass. In native run
`native-app-NxygNl`, estimates during the interior 4 Mbps interval range from
41.184 to 7408.020 Mbps; the failed upward trial's latest estimate is 6177.684 Mbps.
The gauge is fresh but unsuitable for capacity admission in this local setup.

All 8200 archive frames and 136 audio markers remain intact. Live delivery still
fails at 15 fps with 176 absent identities, 66 repeated observations and −230.3 ms
A/V end coverage. Keep production adaptation disabled. Next qualify a bounded
additional-traffic probe while preserving the current video profile and archive,
then admit upgrades only with receiver-verified headroom against actual candidate
cost. Do not inject the fixture rate into decisions or disable future upgrades
permanently. Phone/Watch, remote-host and soak qualification remain open.

The [bounded SRT probe checkpoint](2026-09-16-bounded-capacity-probe.md) implements
and qualifies a local installed-libsrt synthetic-load ramp. It withdraws at an
active 4.25 Mbps step on a 4 Mbps path, then delivers 5.989 Mbps against a 6 Mbps
target after independent recovery. All 11,302 baseline and 2,781 probe messages
arrive without loss/duplicates; an expiring native lease stops extra load while
baseline continues. All 1061 tooling tests pass, including review regressions.

This is a transport prototype. It does not qualify native A/V or provide usable
video capacity. Next carry a bounded probe on the actual publishing connection,
obtain attempt-bound receiver byte evidence, and repeat all native archive,
picture/cadence and A/V gates. Preserve the distinction between fast local
pressure and the slower receiver-control feedback path. Production adaptation
remains disabled; phone/Watch, remote hosts and soaks remain open.

The [MPEG-TS padding checkpoint](2026-09-16-mpegts-padding-probe.md) now qualifies
real finite H.264/AAC transport with disposable null padding on the same local
SRT connection. In `mpegts-probe-TZgGv9`, baseline, expired lease and 4 Mbps
constraint runs all preserve the full accepted byte stream and identical decoded
video/audio content and timestamps: 360 pictures and 564 audio frames each.
The native lease stops extra traffic while source replay continues; the
constrained case withdraws at 58.657 ms RTT with a 47 ms send buffer. All 1085
tooling tests and native C++ assertions pass, including cleanup/evidence review
regressions. All owned processes and proxies close and join.

This remains a finite installed-library media prototype. The constrained queue
still reaches 214.722 ms residence, so eventual decode equality does not prove
live frame cadence/freshness. Next integrate native same-connection padding and
attempt-bound receiver accounting before GoSRT demux, with separate fast local
pressure/lease ownership and slower bounded receiver confirmation. Keep existing
picture, cadence, A/V, local archive and measured-profile-cost gates. Production
adaptation and physical phone/Watch, other-host and soak qualification remain open.

The [native padding checkpoint](2026-09-16-native-padding-probe.md) adds a
default-disabled same-connection probe to the Swift publisher SDK. It offers
bounded nonblocking null padding only after media, with synchronized queue
priority, a renewable 300 ms lease and fresh local pressure checks. Finish,
close and configuration changes revoke the shared permit. Review regressions
cover stale queue observations, settings changes during admission and acceptance
accounting when native option restoration fails.

All 190 SDK and 61 streaming-package tests pass, as do exact vendor provenance
verification and the unsigned combined iPhone/Watch Release build. This proves
the native primitive's tested lifecycle and accounting behavior, not receiver
delivery or the 24-fps requirement. App/DEBUG fixture integration and authenticated
pre-demux receiver accounting come next. Production adaptation stays disabled;
native archive/live media, physical devices, other hosts and soaks still require
their existing qualification gates.

The [publisher probe adapter checkpoint](2026-09-16-publisher-probe-adapter.md)
exposes the opt-in capability through the actual `SRTPublisher` and
`SRTMediaPublisher` adapters. Exact UUID/generation handles scope renewal and
cancellation; stop cancels and joins in-flight start/renewal, and settings changes
invalidate pending acknowledgments. Failed renewal revokes the old lease. The
lower adapter now restricts `configure()` to setup before starting.

All 70 streaming-package and 213 app-model tests pass, along with the combined
unsigned iPhone/Watch Release build and targeted review. An owned ephemeral native
SRT connection verifies default-disabled admission and rejection of live
configuration. It does not qualify camera media or live cadence. Next wire the
DEBUG fixture's bounded renewal/export ownership, then authenticated pre-demux
receiver accounting and existing native simultaneous archive/live gates.
Production adaptation and device/Watch/portable-host/soak qualification remain open.

The [native probe fixture checkpoint](2026-09-16-native-probe-fixture.md) wires
explicit DEBUG simulator `renew`/`expire` modes through the fixed540p publishing
factory and the existing full native harness. One owned task starts a bounded
1 Mbps attempt, renews or observes it, then revokes; stop joins the task before
exporting terminal evidence. The harness checks exact attempt/clock scope, bounded
packet counters, lease causality and terminal state, without claiming receiver
capacity. Review regressions reject future renewals and expired-lease revival.

All 1400 app-model/streaming/tooling tests, the ARM64 DEBUG simulator test build
and unsigned combined iPhone/Watch Release build pass. The first actual expired-lease run is recorded below; next execute sustained
renewal and retain all media gates, then add authenticated pre-demux receiver
accounting before capacity admission. The
fixed profile is an isolation experiment; highest-sustainable live quality,
production adaptation, phone/Watch, portable hosts and soaks remain open.

Actual expired-lease run `native-app-f8Su6q` passes on iOS 17.5. Nine native probe
messages (11,844 bytes) stop before the 300 ms deadline; publishing continues
another 90.282 seconds. The independent archive preserves all 3,658 consecutive
1080p30 frames and 60 audio markers. Fixed540p live output preserves all 3,282
identities after its separately accounted 35-frame startup acquisition, with
29.8 fps minimum reported receiver cadence and +24.392 ms A/V end coverage.
Both full decode logs are clean. All owners terminate and the proxy closes with
no drops/errors/pending data; independent artifact verification passes.

This is a passing finite fixed-profile expiry scenario, not adaptive quality or
receiver capacity. The one-message-per-media-opportunity probe underdelivers its
requested rate. Next qualify sustained renewal and pressure, then obtain real
receiver headroom against measured candidate cost. Highest-sustainable quality
and device/Watch/host/soak gates remain open.

The [native renewal/pressure qualification](2026-09-16-native-probe-renewal.md)
now passes on unchanged runtime `857d4ab`. Passthrough run `native-app-BKvdTc`
renews 484 times and accepts 1,502 probe messages over 50.063 seconds. The archive
preserves 3,691 frames; retained live output preserves 3,284 consecutive identities
and all reported receiver windows meet 30 fps. Scheduled 4 Mbps run
`native-app-siyvpV` reports native pressure withdrawal after 1,245 messages,
then continues media for another 138.218 seconds. Its archive preserves all
6,331 frames and 105 audio markers; live output preserves 5,955 consecutive
identities at 30 fps minimum reported receiver cadence. Neither proxy drops
packets; both full decode logs are clean and all owners terminate/join.

Both runs deliver only ~0.316 Mbps additional native payload against the requested
1 Mbps. This establishes the one-message-per-media-opportunity bottleneck, not
usable 1 Mbps headroom. Next implement a bounded optional-send schedule that can
actually achieve the intended load while preserving media priority, then add
attempt-bound receiver accounting and capacity admission against measured profile
cost. Do not infer exact pressure threshold timing from the current reason-only
snapshot. Production adaptation and phone/Watch/other-host/soak gates remain open.

The [probe opportunity scheduler](2026-09-16-probe-opportunity-scheduling.md)
removes the measured frame-rate bottleneck using one coalesced wake signal and
one optional strict timer; the existing transport consumer still sends all media
and drains queued media first. Shared teardown joins entered timer callbacks and
preserves finish/replacement ownership. All 197 SDK and 70 adapter tests, simulator
test build, combined iPhone/Watch Release build and upstream provenance pass.

Actual renewal `native-app-LZBHFN` achieves 0.989926 Mbps accounted against its
1 Mbps request while preserving all 3,727 archive frames / 62 audio markers and
3,351 retained live frames / 55 markers; minimum reported live cadence is 29.6 fps.
The next pressure attempt `native-app-2jcK34` fails archive queue capacity before
probe admission or constrained traffic. It exposes a late synthetic producer
catching up 32 frames in about 130 ms. Its initiating stall is unproven, and this
is an unresolved recording failure, not a successful pressure trial. Next reproduce
and address that archive/source burst, then repeat pressure qualification before
receiver capacity or adaptive upgrades. Physical devices, native Watch networking,
remote hosts and long soaks remain open.

The [synthetic source pacing repair](2026-09-16-fixture-catch-up-cadence.md)
prevents overdue frame deadlines from flooding the archive after a stall, without
changing queue limits or media identities. A deliberate 1.5-second callback stall
preserves all 90 frames and matching audio through the real writer. All 222 app-model,
254 media and 1,112 tooling tests, simulator test build and combined iPhone/Watch
Release build pass.

Actual scheduled-pressure run `native-app-MefG1k` now passes: 6,366 intact archive
frames, 5,990 consecutive retained live frames, all expected audio markers, clean
full decodes and 30 fps minimum reported receiver cadence. The probe reaches
0.991219 Mbps accounted, withdraws on transport pressure, and media continues for
140.312 seconds. The proxy drops nothing; every owner terminates and joins. This
run does not reproduce the original source stall; the dedicated regression covers
that defect. Authenticated receiver-attributed probe delivery and measured candidate
cost remain next, before quality upgrades. Physical capture, Watch routes, other
hosts and sustained soaks remain open.

[Receiver-attributed probe accounting](2026-09-16-receiver-probe-accounting.md)
now marks valid null packets and counts complete probe messages before relay
remultiplexing. The private relay API binds snapshots to the publisher connection;
the native fixture verifies its signed application attempt before redacting/saving
measurements. Malformed, stale, crossed or incomplete evidence cannot pass.

Actual pressure run `native-app-IK5Ns7` delivers all 3,693 sender-accepted messages
(4,859,988 bytes), at ~0.9923 Mbps accounted against 1 Mbps. The independent archive
preserves 6,387 frames; retained live output preserves 6,010 consecutive frames and
30 fps minimum reported receiver cadence. All expected audio markers, full decodes,
proxy conservation and joined teardown pass. The 199 SDK, 70 adapter and 1,139
tooling tests, three relevant Go package suites with race checks, both Apple builds
and exact vendor provenance pass.

Next integrate fresh receiver intervals into production status/policy and measured
candidate-cost admission, including bounded repeated probes/stages. Current proof
is a finite fixed-profile scenario and retains one attempt per connection; it does
not authorize automatic upgrades. Phone/Watch, remote hosts and long soaks remain
unqualified.

[Authenticated receiver probe status](2026-09-16-receiver-probe-status.md) now
carries separately sanitized measurements through the production API, after
signed publisher verification and a post-I/O scope check. Shared iPhone/Watch
code requires the locally owned probe identity, retains immutable publication
and worker scope, and adds API transit, client request time and local residence
to conservative snapshot and last-delivery age. Cache bypass prevents an ordinary
cached status from receiving a fresh local budget. Malformed optional measurements
leave ordinary status usable.

All 437 control-plane, 307 shared-core and 222 capture-model tests pass, along
with typechecking, simulator build-for-testing and combined iPhone/Watch Release
compilation. The byte-limit partial-message boundary and explicit-null metadata
were reproduced and corrected before the final checks. Evidence is recorded in
`artifacts/qa/receiver-status-verification.json`.

Next wire the production probe owner, causal receiver intervals and measured
candidate cost, including bounded repeat/stage behavior. No automatic upgrades
are enabled by this status contract. Physical-device, Watch networking, remote
host and long-soak qualification remains open.

[Native receiver intervals](2026-09-16-native-receiver-probe-intervals.md) now bind
status to the actual local publishing probe and derive causal 1–5 second intervals.
Missing status cannot wash contradictions; lease and report expiry independently
remove usable evidence. Complete-message arithmetic subtracts baseline partial
packets and excludes incomplete endpoint packets. The opt-in fixture exports actual
app observations and checks them against independent publication, receiver and
native owner histories, including conservative request-to-evaluation timing.

All 317 shared-core, 228 capture-model and 1,168 tooling tests pass, as do the
simulator test build and combined unsigned iPhone/Watch Release build. Actual
pressure run `native-app-aNh21w` preserves 6,416 archive frames and 6,040 consecutive
retained live frames, all expected audio markers and clean decodes, with 29.8 fps
minimum reported receiver cadence. All 3,683 accepted probe messages reach the
relay; 18 native intervals cover 36.599 seconds of receiver reads. Probing withdraws
under pressure while media continues another 142.065 seconds. Proxy conservation,
joined teardown and 19 independent damaged-evidence rejections pass. Evidence is
frozen in `artifacts/qa/receiver-interval-final-verification-v2.json`.

Next implement measured candidate cost and bounded repeated/staged probe ownership
before qualified quality-increase admission. Production probing and automatic
upgrades remain disabled. Physical-device/Watch networking, remote hosts and long
soaks remain unqualified.

[Measured native video payload cost](2026-09-16-measured-video-cost.md) now joins
actual encoder identity/timing and compressed sample bytes in a bounded owner per
publishing attempt. It closes after native teardown and exposes only fresh,
complete, coherent intervals. Current measured cost does not prove spare capacity
or predict a different resolution's cost.

All 78 streaming, 229 capture-model and 1,189 tooling tests pass, along with the
simulator test build and combined unsigned iPhone/Watch Release build. Actual
pressure run `native-app-M4cCvu` preserves 6,388 archive frames and 6,012 consecutive
retained live frames, all expected audio markers and clean decodes, with 30 fps
minimum reported receiver cadence. Eight measured windows account for 7,045,658
H.264 payload bytes and peak at 3.527 Mbps despite the nominal 1.5 Mbps setting.
All 3,676 probe messages arrive; media continues 141.075 seconds after withdrawal.
Independent verification and 27 damaged-evidence rejections pass. Evidence is
frozen in `artifacts/qa/video-cost-final-verification.json`.

The user's September 16 clarification makes progressive sender adaptation explicit:
start at the lowest qualified live profile without waiting for a bandwidth probe,
then increase cautiously; sustained excessive frame loss resets live output to
the lowest profile before another gradual recovery. Independent local recording
remains mandatory. The next design must use researched congestion-control behavior
and distinguish transport packet loss from actual missing/late video frames.
Automatic upgrades remain disabled until candidate cost, repeated/staged ownership,
and real transition media continuity are qualified. Physical-device/Watch networking,
remote hosts and long soaks remain open.

[Fixed360 native qualification](2026-09-16-low-profile-qualification.md) adds a
640×360/30 fps candidate with a requested 600 kbps rate to the explicit simulator
fixture and portable worker. The independent archive remains 1080p. 79 streaming,
254 media, 230 model, 344 worker and 1,192 tooling tests, worker typechecking and both
Apple builds pass. Actual run `native-app-3Zrmzl` preserves 6,354 archive frames and
5,961 consecutive retained live frames with all expected audio markers, clean full
decodes, 29.8 fps minimum reported receiver cadence and no proxy drops. Independent
verification and 11 damaged-evidence rejections pass; every owner joins. The initial
540-only UI launcher restriction was reproduced and corrected before the passing run.

Measured video payload still reaches 3.546 Mbps, close to the preceding 540p run's
3.527 Mbps. The nominal 600 kbps setting is not achieved. This qualifies the finite
360p media scenario, not a lower-bandwidth recovery tier. Effective encoder-rate
control/cheaper candidate qualification remains a prerequisite for low startup and
reset-to-minimum. Automatic adaptation and production defaults remain unchanged.
Evidence is frozen in `artifacts/qa/low360-final-verification.json`.

[Native Mac rate-control diagnosis](2026-09-16-native-mac-rate-control.md) now runs
the same isolated encoder workload on this Mac, with separate versioned evidence
and before/after native hardware readbacks. Run `encoder-native-mac-QrOxha` preserves
all 2,402 frames but produces 5.659 Mbps after a live 1.5 Mbps request and 4.936 Mbps
in a fresh low session. This disproves an explanation confined to the simulator;
it does not identify the underlying rate-control cause or qualify low bandwidth.

Two native low-latency experiments are retained as failures: `GO9om3` fails with
unsupported DataRateLimits (-12900), and average-only `mBkLHK` accepts the rate
but fails with generic codec status -1 after one frame. Neither is enabled in
production. All 1,195 tooling tests and the simulator diagnostic build pass; five
old simulator runs replay unchanged. Independent arithmetic/session checks agree
with the baseline and reject 10 damaged variants. The final evidence manifest is
`artifacts/qa/mac-rate-final-verification.json`. Next isolate the exact callback
failure and measure lower-resolution native costs before admitting a recovery tier.

[Encoder pixel-format correction](2026-09-16-encoder-pixel-format.md) fixes the
streaming codec's input attribute: use the raw image's media subtype (NV12/BGRA),
not the general `vide` media type. Three actual sample-format regressions reproduce
the error before the fix. All 201 SDK, 79 streaming and 1,195 tooling tests pass;
the simulator diagnostic and unsigned iPhone/Watch Release build also pass.

Native fixed360 pressure run `native-app-H73kCA` retains 6,448 consecutive archive
frames and 6,043 consecutive live frames, all audio markers, clean decodes and
29.8 fps minimum reported receiver cadence through a measured 60-second 4 Mbps
phase. Independent verification rejects 11 damaged variants. Video cost still peaks
at 3.547 Mbps. The native Mac controlled comparison retains 2,402 frames with
unchanged per-frame byte counts, and low-latency average-only encoding still fails.
The setup defect is corrected; lower-bandwidth fallback and automatic adaptation
remain unqualified. Source/evidence hashes and joined-owner outcomes are retained
in `artifacts/qa/pixel-format-final-verification-v2.json`.

[240p fallback candidate](2026-09-16-240p-qualification.md) adds an explicit
426×240/30 fps native and portable-worker profile, requested at 350 kbps. Actual
run `native-app-hB2BBX` preserves 6,424 consecutive archive frames and 6,049
consecutive retained live frames, all audio markers, clean decodes and 29.6 fps
minimum reported receiver cadence through the scheduled 4 Mbps phase. Native
format evidence confirms 426×240 before the proxy can resize it.

Measured video windows peak at 1.992 Mbps, down from the prior fixed360 run's
3.547 Mbps; the constrained phase averages 2.246 Mbps of wire traffic. This is a
useful cost reduction in separate finite trials, not achievement of 350 kbps or
capacity proof. 80 streaming, 254 media, 231 model, 345 worker and 1,199 tooling
tests, worker typechecking and both Apple builds pass. Independent verification
rejects 11 damaged variants. Evidence is in `artifacts/qa/low240-final-verification.json`.
Next test an explicit 3 Mbps uplink, then minimum-profile transitions and progressive
health/policy integration. Automatic adaptation and production startup remain gated.

[Fixed240 at 3 Mbps](2026-09-16-240p-3mbps.md) now passes in
`native-app-2H0AUs`: 6,386 consecutive archive frames, 5,981 consecutive retained
live frames, all audio markers, clean full decodes and 30 fps minimum reported
receiver cadence. The actual 3 Mbps phase lasts 60,000.510291 ms, carries
16,868,736 wire bytes and drops no proxy packets. Measured video windows peak at
1.989 Mbps. This qualifies a useful lower-bandwidth fixed scenario on the local
simulator, not automatic adaptation or achievement of the nominal 350 kbps setting.

All 1,202 tooling tests pass; three retained 4 Mbps runs replay unchanged and are
rejected under the 3 Mbps expectation. Independent verification rejects 16 damaged
variants. Every process owner joins; hashes are in
`artifacts/qa/rate3m-final-verification.json`. Next qualify controlled
240p → 540p → 240p transitions, then integrate the required short-window health,
minimum reset and progressive recovery policy. Physical-device and remote-host
qualification remain open.

[Controlled minimum-profile transitions](2026-09-16-minimum-profile-transitions.md)
now pass on the iOS 17.5 simulator in `native-app-MLneuc`. Actual native encoder
formats are 240p → 540p → 240p; 3,353 consecutive encoded frames become 3,318
consecutive saved live frames after 35-frame acquisition. The separate 1080p
archive retains all 3,725 frames. All audio markers match and full decodes are
clean. The two encoder replacements each pause compressed output by about 414 ms;
receiver wall-clock continuity and automatic adaptation remain unqualified.

All 1,205 tooling and 233 model tests pass, as do the native simulator workflow and
unsigned iPhone/Watch Release build. Two retained transition results replay
unchanged; the independent audit rejects 18 damaged variants. FFmpeg's observed
SIGTERM/255 shutdown joins successfully under the existing terminal contract,
with the final live frame saved. Sources/evidence are frozen in
`artifacts/qa/minimum-transition-final-verification.json`. Next implement short
health windows/watchdog, priority minimum reset and conservative recovery under
the progressive streaming design, while preserving the receiver-continuity gate.

[Decoder short-window measurements](2026-09-16-decoder-short-windows.md) now attach
to the real FFmpeg decoded-PTS pipe. Constant-space one-/two-second windows and a
unique-frame progress watchdog distinguish live stalls from unstarted, invalid or
closed telemetry. All 360 worker tests, worker typechecking and 1,205 tooling tests
pass. Actual paced/pause/resume run `decoder-cadence-native-Q8lxKX` reconciles 661
snapshots, 22 complete windows and all 478 accepted decoder frames against separate
arrival history and the decoded output. It detects >=1,000 ms without fresh
progress and observes resume in 26.06 ms. Ten damaged evidence variants reject.

The initial UDP fixture required a forced stop and remains a failed qualification;
the rerun uses an explicit finite UDP read timeout and joins orderly SIGTERM/255.
Its measured 187-frame startup burst proves why high arrival cadence alone cannot
qualify healthy source delivery. These local worker snapshots are not yet reported
through authenticated media status or used for quality decisions. Next complete
scoped freshness/reporting, expected-source/lateness reconciliation and direct
minimum reset/recovery. Source/evidence hashes are in
`artifacts/qa/decoder-cadence-final-verification.json`; no new archive, SRT, physical
phone/Watch or remote-worker qualification is claimed by this observer experiment.

[Authenticated decoder cadence reporting](2026-09-16-decoder-cadence-reporting.md)
now carries optional one-/two-second snapshots from the actual pipeline sample
through negotiated worker reporting and authenticated media status into native
wire models. Current private read identity, transport coordinates, scope retirement,
window/progress monotonicity and omission handling gate the API. Server timing-token
bounds plus native request/residence accounting establish snapshot freshness for
an explicitly expected publishing attempt; missing reports never synthesize stalls.

All 445 API, 361 worker, 323 Core, one protocol and 1,205 tooling tests pass, both
services typecheck, and ARM64 simulator/unsigned iPhone+Watch Release builds pass.
All 661 prior real FFmpeg snapshots replay unchanged through authenticated routes
with every age bound reconciled and unauthorized requests rejected. Shared golden
JSON covers native interoperability. Evidence is in
`artifacts/qa/cadence-report-final-verification.json`. This route replay does not
establish a live relay association or physical-device performance.

Next qualify short report/poll timing, expected-source/lateness reconciliation,
and consumption by the priority minimum-reset/recovery controller. Production
worker report cadence remains 1,000 ms; automatic quality behavior is unchanged.

[Progressive minimum-reset policy](2026-09-16-progressive-reset-policy.md) now adds
explicit progressive behavior to the controller and native quality-session adapter.
Frame-floor/source-loss failures and failed trials target the lowest qualified
profile directly, with sticky reset ownership and 10/20/40/60-second healthy recovery
holds. Four healthy seconds permit the next eligible increase; every progressive
increase receives probation, and successful probation clears repeated-failure history.
Unknown evidence cannot erase a pending reset or accumulate healthy recovery.

All 342 Core and 235 native model tests pass, together with ARM64 simulator and
unsigned iPhone/Watch Release builds. Native adapter tests verify direct 1080p ->
240p requests and exact encoder/bitrate receipts before starting the recovery hold.
They use controlled operation receipts, not a new live media run. The source/evidence
manifest is `artifacts/qa/progressive-reset-final-verification.json`.

Production activation is still pending: reconcile short source delivery/lateness
and watchdog evidence, qualify report reaction time, wire actual minimum startup,
and qualify candidate cost/headroom plus real automatic transitions. Native receipt
failure currently retires publishing; minimum-profile reconnect must accompany
activation. The existing driver continues using its legacy default until those gates
are satisfied. No additional physical phone/Watch or remote worker result is claimed.

[Minimum startup and first-frame evidence](2026-09-16-minimum-startup-evidence.md)
now makes normal app connections configure 240p30 before the first live frame. Each
attempt/reconnect owns a fresh constant-size first-frame observer. Progressive
bootstrap joins actual compressed dimensions/source identity to the first native
encoder, then requires a matching verified bitrate receipt before recording applied
settings. Missing evidence has a bounded wait; wrong or late evidence cannot silently
become verified startup. Archive configuration and explicit historical fixtures remain
independent.

Verification: 256 Media, 87 Streaming, 342 Core, 238 native model and 1,206 tooling
tests pass, plus ARM64 simulator and unsigned iPhone/Watch Release builds. Actual
`native-app-UwfiUF` fixed240 streaming passes: first compressed H.264 sync frame is
426x240, all 3,381 native frames are consecutive, and raw first callbacks reconcile
exactly with the production adapter receipt. First local pre-mux output appears
0.500781 seconds after observation begins. Saved live media contains 3,348 consecutive
frames after 33 acquisition frames; the clean 1080p archive contains 3,723 consecutive
frames. Both fully decode, all 55 live/61 archive audio markers match, and owned
processes finish cleanly. Fourteen altered actual receipts reject independently.
Evidence: `artifacts/qa/minimum-startup-final-verification.json`.

This verifies local first-frame encoding and fixed-profile media, not viewer startup
latency or physical minimum-profile support. Actual disconnect/reconnect qualification,
source-timed short delivery/watchdog integration, report reaction timing, fresh
candidate cost/headroom and real automatic transitions remain before progressive
production activation. Normal live publishing currently stays at the minimum until
that automatic recovery path is qualified.

[Fresh decoder-stall minimum reset](2026-09-17-decoder-stall-reset.md) now binds
explicit worker no-progress observations to the current native publishing receipt
and gives them priority in the progressive quality driver. Fresh, post-acknowledgment
one-second stalls latch the existing minimum reset. Replayed/stale/wrong-scope
reports cannot invent a stall; duplicate progress does not repeat encoder writes.
Recovery excludes windows that start before the received stall. The capture helper
works without optional source-frame instrumentation and follows publishing lifecycle
cleanup. These inputs remain separate from source-frame loss and healthy FPS.

All 348 Core and 246 native model tests pass, plus ARM64 simulator and unsigned
combined iPhone/Watch Release builds. Evidence is frozen in
`artifacts/qa/decoder-stall-final-verification.json`. No new live transition or
physical device result is claimed. The default 1,000 ms worker reporting interval
cannot meet the 250 ms conservative watchdog freshness budget. Next qualify actual
fast-report response time, then short source/lateness measurements and candidate
headroom before enabling progressive production adaptation. Existing local recording
and fixed minimum startup continue independently.

[Native fast-report timing](2026-09-17-native-cadence-report-timing.md) now has a
bounded DEBUG simulator audit and an independent checker. Actual fixed240 run
`native-app-ToYhHS` used 100 ms worker reporting and native polling. All 747 settled
reports across 98.481 seconds met the 250 ms freshness budget; p95 age was 219.069 ms,
maximum 247.844 ms, and the largest usable-report gap 164.092 ms. Initial helper
availability took 7.403 seconds from the first status row and is outside this settled
claim. Raw server/request/residence bounds reconcile independently.

Media remained continuous: 3,291 saved live frames after 34 acquisition frames and
3,667 clean archive frames, all expected 54/61 audio markers, and clean full decodes.
All 1,222 tooling, 348 Core and 248 native model tests pass, plus simulator and
unsigned combined iPhone/Watch Release builds. Evidence:
`artifacts/qa/cadence-timing-final-verification.json`. Normal local reporting freshness
is now qualified at this configuration. Controlled-stall/reset reaction timing,
short expected-source/lateness reconciliation, candidate headroom, real automatic
transitions and physical/remote qualification remain. Production adaptation and
normal reporting defaults are unchanged.

[Controlled native decoder stall](2026-09-17-native-controlled-decoder-stall.md)
now exercises a real owned FFmpeg pause with the native progressive controller at
fixed minimum quality. The passing rerun `native-app-hnaYMv` produced one minimum-hold
decision within a conservative 1.443 seconds of last decoder progress, admitted at
234.230 ms sample age, with no redundant encoder write. The 1.970-second pause
resumed successfully. Fresh cached cadence reports are consumed once; new stale
reports still reject and current native ownership is always checked. A first failed
run also exposed the cost verifier's initial-configuration anchor assumption; the
new receipt-qualified path reconstructs that boundary without weakening legacy runs.

All 1,253 tooling, 348 Core and 250 native model tests pass, plus simulator and unsigned
combined iPhone/Watch Release builds. Saved live media retains 3,263 consecutive
frames after acquisition; the independent 1080p archive retains all 3,669 frames.
Both fully decode with passing audio/coverage checks. This saved-media continuity
is distinct from uninterrupted real-time delivery during the injected pause.
Independent timing/cost/frame reconstruction and failed-run evidence are retained in
`artifacts/qa/controlled-stall-final-verification.json`.

Next qualify an actual higher-profile minimum reset write, short source/deadline
measurements, candidate headroom, and full automatic recovery/reconnect. Physical
phone/Watch and remote-worker gates remain. Production reporting and automatic
adaptation defaults remain unchanged by the explicit simulator experiment.

[Controlled native 540p-to-minimum reset](2026-09-17-native-stall-profile-reset.md)
now passes through the actual progressive controller, native encoder and local
SRT/proxy/RTMP path. In `native-app-1wOipN`, a 1.973-second owned decoder pause produced
one reset decision within a conservative 1.311 seconds of last decoder progress.
The verified native replacement completed in 462.511 ms after admission. Actual
540p/240p frame phases, old/new encoder identities, both native receipts and first
new-format downstream delivery reconcile independently. No native source frame was
dropped during replacement.

The independent 1080p archive retains all 3,670 frames; saved live media retains
3,262 consecutive frames after acquisition. Both fully decode and retain every
expected audio marker. The deliberate pause still interrupts real-time delivery;
saved continuity is a separate claim. All 1,272 tooling, 348 Core and 252 native model
tests pass, plus ARM64 simulator and unsigned iPhone/Watch Release builds. Evidence:
`artifacts/qa/stall-reset-final-verification.json`.

Next complete short expected-source/deadline reconciliation, actual candidate
cost/headroom and bounded upward recovery, then minimum reconnect and longer automatic
runs. Production minimum startup remains in place. Physical iPhone/Watch and remote
CPU/GPU/cloud qualification remain outstanding; the test's deliberate 540p startup
is isolated to its explicit DEBUG simulator mode.

[Delivery deadline evidence](2026-09-17-delivery-deadline-evidence.md) now supplies a
bounded worker arrival timeline and a conservative native classifier for on-time,
late, missing and uncertain frames. Buffered catch-up cannot repair missed deadlines;
uncertain timing cannot provide complete healthy-delivery evidence. Review's exact
deadline boundary finding is fixed and covered by a failing-then-passing regression.

Actual local FFmpeg run `decoder-delivery-native-AQldhi` passed: 478 decoded frames,
661 snapshots, a bounded 256-arrival history and clean output decode. Independent
reconstruction matched every arrival identity and retained coverage boundary and
rejected six corrupted variants. All 1 protocol, 371 worker, 358 Core, 1,272 tooling
and 252 native model tests pass, with worker/API typechecks, ARM64 simulator and
unsigned iPhone/Watch Release builds. Frozen evidence:
`artifacts/qa/delivery-deadline-final-verification.json`.

This is a local observer/classifier checkpoint. Authenticated compact reporting,
complete native source/configuration matching and controller integration are next.
Measured full-history reporting at 10 Hz would cost about 1.16 Mbps before overhead,
so it must use bounded deltas/coalescing. Production automatic adaptation remains
disabled until those gates and candidate-headroom/recovery checks pass. Physical
phone/Watch and remote CPU/GPU/cloud qualification remain outstanding.

[Incremental delivery reporting](2026-09-17-incremental-delivery-reporting.md) now
carries bounded arrival history through capability-negotiated worker reports and
opted-in authenticated status queries. Acknowledged cursors avoid repeating the full
ring; lost acknowledgements, API restarts and client cursor loss resynchronize safely.
Frozen samples cannot be made fresh by a new timing token, including after omission.

Actual FFmpeg/HTTP fixture `incremental-delivery-native-r4qx4E` reconstructed 478
arrivals across 161 status reports, with nonempty acknowledgement loss at ordinal160,
API restart/full worker snapshot at208 and client resynchronization at304. Delivery
payload averaged 22.541 kbps including acquisition/resynchronization; complete HTTP
bodies averaged 62.462 kbps upstream and 70.034 kbps downstream before network overhead.
Saved output fully decodes. Independent reconstruction rejects six corrupted variants.
All 6 protocol, 378 worker, 448 API and 1,272 tooling tests and both TypeScript
application typechecks pass. Evidence: `artifacts/qa/incremental-delivery-final-verification.json`.

Next bind this stream into the native consumer, current publication/worker epoch and
complete capture/configuration windows. The local experiment qualifies authenticated
HTTP reporting, not physical phone deadlines or relay attachment. Automatic quality
recovery, candidate headroom, reconnect, physical Watch/phone and remote worker gates
remain open.

[Native incremental delivery consumer](2026-09-17-native-delivery-consumer.md) now
reconstructs reports in Core and consumes them in the capture app. Native queries
opt in with validated cursors, while scoring clients retain ordinary status requests.
The tracker requires current publication/epoch/attempt ownership, forces a full base
after binding changes, rejects retired contexts and prevents frozen-sample freshness
from being restored by a later reply. Omission, expiry and detach clear availability.

Swift and TypeScript both reconstruct the exact 161 real FFmpeg/HTTP packets and 478
arrival tuples from the shared trace. Native HTTP/tracker replay uses explicit fixture
publication identity and a generated full response after epoch change; it does not
prove physical publication binding or capture-to-worker deadlines. Independent
fixture/provenance reconstruction rejects five corruptions. All 372 Core, 253 native
model, 7 protocol and 1,272 tooling tests pass, plus ARM64 simulator and unsigned
combined iPhone/Watch Release builds. Evidence: `artifacts/qa/native-delivery-final-verification.json`.

Next complete native source/configuration windows and decoder PTS projection, then
qualify deadline loss/floor decisions against actual simulator capture. Automatic
recovery, candidate headroom, reconnect, physical devices and remote workers remain
required; this consumer checkpoint enables no new quality decisions.

[Delivery source windows](2026-09-17-delivery-source-windows.md) now prove complete
one/two-second captured-source expectations and project every expected frame into
the bound decoder PTS domain. Local encoder omissions remain in the denominator.
Retained capture/completion brackets, exact encoded provenance, verified settings
and checked wrap arithmetic prevent incomplete history from becoming false health.
The app adapter binds classification to current native ownership and authenticated
sample age, and rejects decoded arrivals for explicitly unencoded captures. Uncertain
timing cannot establish healthy on-time FPS.

Independent review's unmatched right encoder bracket counterexample is fixed with a
failing-then-passing regression. All 372 Core and 265 native model tests pass, including
12 new source/adapter tests; ARM64 simulator build-for-testing and unsigned combined
iPhone/Watch Release builds pass. All 24 prior frozen evidence files remain unchanged.
Evidence: `artifacts/qa/delivery-source-final-verification.json`.

The adapter is ready for capture-loop window scheduling and actual simulator/relay
deadline qualification. It does not yet drive automatic quality decisions. Candidate
actual-cost/headroom, recovery, reconnect, physical phone/Watch and remote worker
qualification remain required.

### Native deadline monitor checkpoint

[The native monitor](2026-09-17-native-deadline-monitor.md) now schedules bounded
one/two-second source windows from current capture and authenticated worker evidence.
An independent verifier reconstructs raw reports and checks the native results.
Actual simulator run `native-app-AG9LAw` emitted 150 windows: 124 classified,
26 freshness-unknown. The owned 2.040-second decoder pause produced deadline
failures while the independent 1080p archive fully decoded with 3,658 frames and
60/60 audio markers. Final buffered live output also fully decoded without source
loss; eventual arrival does not erase missed deadlines.

The experimental one-second deadline provided no proven healthy windows because
normal arrival intervals commonly straddle that deadline. Measured upper latency
p99 is 1.201 seconds among matched arrivals in classified one-second windows.
The next separately recorded experiment will test a 1.5-second budget with the
same 250 ms freshness cap and owned decoder pause. This is an experimental margin,
not a production default. Automatic adaptation/recovery remain gated.

All 372 Core, 273 native model and 1,313 tooling tests pass, with ARM64 simulator
and unsigned combined iPhone/Watch Release builds. Independent review closed
older-anchor export, sticky tracker exhaustion and conservative age-bound findings.
Evidence: `artifacts/qa/native-deadline-final-verification.json`. Candidate actual
cost/headroom, recovery, reconnect, physical devices and remote workers remain open.

[The explicit 1.5-second deadline experiment](2026-09-17-deadline-baseline-experiment.md)
now proves healthy baseline delivery and disturbance detection in actual simulator
run `native-app-AozzeP`. It independently reconciles 136 classified windows and
retains 15 freshness-unknown windows. There are 87 healthy one-second windows and
44 healthy two-second windows. The owned 1.965-second decoder pause produces a
zero-on-time-FPS one-second window and a two-second window with 35/60 frames
missing at measurement; the overlapping lanes are never summed into recovery.
A later continuous 31-second span proves healthy receiver delivery only.

Independent 1080p archive: 3,678 fully decoded frames and 61/61 audio markers.
Live output also fully decodes with zero eventual source loss. All 372 Core,
274 native model and 1,317 tooling tests, ARM64 simulator and unsigned combined
iPhone/Watch Release builds pass. Source and all previous evidence are preserved
in `artifacts/qa/deadline-baseline-final-verification.json`. Next connect scoped
deadline failures to minimum-reset decisions and qualify actual reset/recovery;
the experiment does not yet activate automatic adaptation or qualify physical
devices, candidate headroom, or remote workers.

[Deadline-reset ownership integration](2026-09-17-deadline-reset-integration.md)
now maps fully classified one-second floor and two-second loss failures into scoped
Core minimum-reset decisions. Independent lane watermarks permit overlapping
failure observations without giving recovery credit. Native owner tests dispatch
and acknowledge a minimum-rate reset once; malformed, stale, retired or mismatched
measurements cannot initiate it. Classification retains its exact revocable worker
context authority, and admission separately rechecks status expiry before the next
health poll. Already justified reset intent survives later telemetry retirement.

The Core and native admission checkpoint is independently reviewed and tested.
Driver activation, decision export and a new actual reset experiment are the next
steps; the injected native-operation test does not qualify physical encoder behavior
or automatic recovery. Evidence: `artifacts/qa/deadline-reset-final-verification.json`.

The same deadline-reset plan now has a verified driver checkpoint. Explicit
simulator run `native-app-DcUNqI` disables the earlier stall watchdog and legacy
recovery credit, then admits a zero-on-time-FPS one-second deadline failure during
an owned 2.051-second decoder pause. It holds minimum quality without recreating
the encoder. The independent verifier binds the decision to raw reports, source
frames and current authority, including intervening retirement and status expiry.
It reconciles 134 classified and 16 unknown windows; unknown evidence stays unknown.

The independent 1080p archive finishes with 3,716 frames, zero source loss and 61/61
audio markers. Live 240p output also fully decodes with 54/54 markers. All 385 Core,
286 native model and 1,378 tooling tests pass, plus simulator and unsigned combined
iPhone/Watch Release builds. Reviews are approved; frozen evidence is recorded in
`artifacts/qa/deadline-driver-final-verification.json`. Next qualify higher-profile
deadline-triggered writes and controlled recovery/headroom. Minimum-hold behavior
does not prove those gates; production adaptation remains disabled.

[Deadline-triggered profile reset](2026-09-17-deadline-profile-reset.md) now passes an
actual iPhone 14/iOS 17.5 simulator experiment (`native-app-2ocCqq`). After14 healthy
one-second540p windows and6 healthy two-second windows, an owned1.983-second decoder
pause produced16 timely frames out of30. One deadline decision changed the native
encoder from540p to240p, with the first new frame at0.476seconds and acknowledgment
at0.477seconds after the decision. Fresh before-pause and stalled in-pause scoped
PTS samples bind the fault to that decision without mixing Node and phone clocks.
The receiver decoded the first new-format source frame and complete tail.

The independent 1080p archive finishes with3686 fully decoded frames, no source loss
and61/61 audio markers. All1442 tooling,385 Core and287 native model tests and both
Apple builds pass; reviews are approved. Frozen evidence:
`artifacts/qa/deadline-profile-final-verification.json`. Next qualify measured
candidate cost/headroom and minimum-first upgrades/recovery; reconnect/soaks,
physical phone/Watch and remote workers remain open. Production adaptation remains
disabled until these gates are satisfied.

[Staged probe wire foundation](2026-09-17-staged-probe-wire.md) adds an explicit
versioned stage ordinal to optional null-packet measurements. The relay accepts
ordered stages, isolates their delivery counts, and preserves cumulative traffic
limits and invalid-evidence state across replacements. Existing v1 probes remain
unchanged; native publishing still emits v1 and authenticated consumers still reject
unqualified v2 evidence. This is a prerequisite for repeating measurements after
conditions improve, not proof of spare capacity or completed automatic upgrades.

Verification passes 204 SDK tests, 61 control-plane tests, 23 receiver-probe tests,
three Go relay packages with race detection, both maintained patch provenance
checks, ARM64 simulator build-for-testing and unsigned combined phone/Watch Release.
Evidence: `artifacts/qa/staged-probe-wire-final-verification.json`. Next carry stage
identity through authenticated status and current native ownership, join replacement
owners, enforce cumulative sender limits, then qualify repeated native probes and
fresh candidate cost. No new live-media or physical/remote qualification is claimed.

[Staged probe status and ownership](2026-09-17-staged-probe-status.md) now carries v2
identity through authenticated status and native matching. Stage changes retain
connection clock and cumulative accounting; retired stages cannot become current
again. An SDK-owned revocable authority accompanies local snapshots, so a response
arriving after cancellation cannot supply measurement evidence. Local health also
withdraws evidence before its old lease expires when the owner is revoked, and a
measurement gap requires a new window baseline. Recording ownership stays active
in the injected cancellation tests.

Verification passes 397 Core, 206 SDK, 88 streaming, 479 control-plane, 1442 tooling
and 292 native model tests, workspace typechecking, plus simulator and unsigned combined phone/Watch builds
(including arm64_32), with approved reviews and SDK patch provenance. Frozen evidence:
`artifacts/qa/staged-probe-status-final-verification.json`. Native live probes still
emit v1: joined repeated native owners, cumulative sender budgets and actual staged
media qualification follow. Measured candidate cost, automatic upgrades/recovery,
physical phone/Watch routes and remote deployment remain open.

[Native staged probes](2026-09-17-native-staged-probes.md) now provide opt-in SDK
start/replacement on one publication. Replacement retires the old native permit,
joins its wake owner, carries every accepted message into the cumulative budget,
and checks identity/configuration again after each suspension. Failed admission
can be retried; old UUID/stage requests cannot replace a newer owner. V1 remains
the default. Qualification campaigns retain 32-stage, 60-second and 16-MiB limits
across replacement; these are not the final full-game recovery policy.

Verification passes 397 Core, 224 SDK, 88 streaming and 292 native model tests, both
Apple builds (including Watch arm64_32), patch provenance and spec/quality reviews.
Mutations confirm the tests catch lost cumulative bytes and premature republishing.
Frozen evidence: `artifacts/qa/native-staged-probe-final-verification.json`. Next
wire staged APIs through publisher adapters and the DEBUG scheduler, then qualify
actual staged SRT with independent local recording. Measured candidate cost,
automatic upgrades/recovery, long-session campaigns, physical phone/Watch and
remote workers remain open; production adaptation is still disabled.

[Staged publisher adapters and DEBUG scheduler](2026-09-17-staged-probe-publishers.md)
now expose the native staged lifecycle to the app. Both adapters reject wrong stage,
identity or campaign accounting and preserve joined operation cancellation. A bounded
DEBUG schedule runs 500 kbps, 1 Mbps and 2 Mbps owners, collecting retirement totals
and timestamps before replacement. Missing final shutdown evidence invalidates an
admitted run. Legacy behavior remains available; CLI staged qualification is still
closed pending independent verifier support.

Verification passes 99 streaming and 298 native model tests, including native
loopback adapter replacement/retry and the 12 DEBUG fixture tests, plus simulator
and unsigned combined phone/Watch builds. Both embedded Watch slices are present;
reviews are approved. Frozen evidence:
`artifacts/qa/staged-probe-publisher-final-verification.json`. Next update independent
sender/receiver/interval verifiers and staged relay selection, then perform the real
multi-stage A/V and local archive qualification. Measured candidate cost, automatic
upgrades/recovery, long-session campaigns and physical/remote qualification remain
open. Production quality adaptation remains disabled.

### 2026-09-17: staged probes qualified through the native media pipeline

[Staged probe qualification](2026-09-17-staged-probe-qualification.md) now verifies
three native SRT probe stages at 500 kbps, 1 Mbps and 2 Mbps against authenticated
relay polling and app receiver intervals. Publication clock and cumulative byte
budgets survive replacements. Impossible pacing bursts, lease-boundary
acceptance and contradictory interval histories fail qualification. Staged runs
select a separately pinned relay image; legacy image defaults remain intact.

The full fixed540p iPhone 14/iOS 17.5 simulator run `native-app-PnVEYX` reconciled
3,411,072 accepted/delivered payload bytes. It qualified 18 independently covered
intervals (six per stage), explicitly excluding three polling-boundary intervals
from qualified totals while validating their histories. The independent 1080p
archive had 3,639 consecutive source frames/60 audio markers; live 540p had 3,264
consecutive frames/54 audio markers. Both decoded with zero source loss; minimum
reported receiver cadence was 29.8 fps. The DEBUG probe fixture now polls within
the 300 ms observed lease; expiry, revocation and normal production cadence remain
unchanged.

Tooling 1,609 and native model 299 tests passed. Frozen evidence:
`artifacts/qa/staged-probe-qualification-final-verification.json`. Next combine
fresh measured candidate encoding cost (keyframes, audio, mux and overhead) with
repeated native headroom observations, then qualify minimum-first upward trials
and recovery. Long-session campaign policy, sustained impairment/thermal tests,
physical iPhone/Watch routes and portable remote CPU/GPU deployment remain open.

### 2026-09-17: bounded candidate video encoding

[Candidate encoding](2026-09-17-candidate-encoder.md) now measures actual H.264
output at a proposed profile using the publishing codec and settings. A separate
single-use owner admits at most four unresolved raw inputs, 121 total frames,
4.25 seconds of source time and eight seconds of admission time. It reconciles
every accepted frame with native completion and compressed output from one encoder
session, retaining initial-keyframe bytes. Cancellation and finish join native work
before returning. Closing admission checks the deadline independently of the timer.

The Streaming adapter binds results to recording, match, broadcast generation,
publishing attempt and applied revision. Actual native tests cover scaling and the
app's 426×240 H.264 High-profile recipe. This is finite video-payload evidence;
it does not yet qualify a complete fresh scene window, audio/mux/transport cost,
spare bandwidth, or concurrent encoder resource impact. Capture fan-out, pressure
cancellation and candidate/headroom admission remain the next integration step.
Production automatic quality increases remain disabled.

Verification passes 240 SDK and 105 streaming tests, simulator build-for-testing,
unsigned combined phone/Watch Release (including arm64_32), patch provenance and
spec/quality review. Frozen evidence:
`artifacts/qa/candidate-encoder-final-verification.json`. The close-owner test now
establishes completed media sends before requiring connection reuse; a controlled
case separately verifies terminal cancellation during an entered send. No live
transport behavior changed.

### 2026-09-17: candidate sampling integrated; native buffering gate remains open

[Candidate sampling](2026-09-17-candidate-sampling.md) now reuses raw video from
the bounded publisher path after primary append, with a four-second finite-window
owner, pressure/ownership cancellation and joined shutdown. Simulator opt-in
exports bounded actual H.264 payload evidence. Independent verification checks
identity, exact source coverage, codec output, timings, pressure and outstanding
input occupancy. Review-driven regressions cover delayed primary startup and
impossible encoder-concurrency evidence. Normal production adaptation is unchanged.

Two iPhone 14/iOS 17.5 native trials (540p and 360p candidate, 240p live, 1080p archive)
failed candidate qualification at the existing four-unresolved-input limit. Both
trials drained all four admitted outputs and preserved their independent archive
and live recordings with zero source-frame loss and matched audio markers. They
are negative candidate trials, not measured spare bandwidth or positive candidate
cost. The positive full-pipeline measurement gate remains open.

Next diagnose native encoder buffering with the actual structured 1080p source,
including a verified frame-delay setting shared by proposed live and candidate
recipes. Preserve the hard resource bound and retain failed evidence. Complete
cost admission, automatic upward trials/recovery, long-session campaigns, physical
iPhone/Watch routes and portable remote workers remain pending.

Verification passes 123 Streaming, 308 native model and 1,613 tooling tests, the
unsigned phone/Watch Release build and SDK provenance. Both simulator workflows
completed, while their independent candidate gates correctly failed. Frozen evidence:
`artifacts/qa/candidate-sampling-final-verification.json`.

### 2026-09-17: native candidate buffering isolated; frame-delay setting unsupported

[Frame-delay diagnostic](2026-09-17-candidate-frame-delay.md) uses the exact shared
360p candidate settings and the structured 1080p source. In the iPhone 14/iOS 17.5
simulator, both unchanged four-frame controls produced no output during more than
one second of native submission idle time, then emitted all four frames on drain.
Setting MaxFrameDelayCount to three failed with `kVTPropertyNotSupportedErr`
(-12900). This identifies reproducible native buffering, but qualifies no remedy.
Production encoding and its four-unresolved-input bound remain unchanged.

The diagnostic preserves raw evidence on failure and separately validates source
identity, native timing, outstanding-input bounds and property status. All 85
focused verifier tests and 1,698 tooling tests pass, as do simulator
build-for-testing, SDK provenance and spec/quality reviews. Frozen evidence:
`artifacts/qa/candidate-frame-delay-final-verification.json`.

Next measure the default encoder's required buffering depth in a finite test-only
experiment with explicit raw-byte accounting, before revising any production
resource bound. Complete candidate cost, automatic upward trials/recovery,
long-session campaigns, physical phone/Watch routes and remote workers remain open.

### 2026-09-17: candidate startup buffering depth measured

[Buffer-depth diagnostic](2026-09-17-candidate-buffer-depth.md) completed five
fresh native sessions with the shared 360p recipe and structured 1080p input. Both
16-input and 20-input cases first produced output after the 14th submission and
peaked at 43,606,080 unresolved raw bytes (about 41.6 MiB). Four-input, eight-input
and repeated four-input controls produced no output during more than one second
of native idle time, then drained every frame. All 52 inputs reconciled exactly.

This supports revising the candidate resource model while keeping its ingress
queue bounded: propose 16 total unresolved inputs plus a 64 MiB aggregate raw
payload cap, with reservations released only on validated compressed dequeue.
Production bounds remain unchanged in this diagnostic. The revised owner must
still pass simultaneous archive/live/candidate testing before quality admission.
The measurement establishes observed simulator behavior, not physical-device
support or complete streaming cost.

Verification passes 74 focused and 1,772 tooling tests, simulator build-for-testing,
the native experiment and unchanged SDK provenance. Raw evidence is retained in
`artifacts/qa/encoder-buffer-depth-oICaqc`; source and evidence hashes are recorded
in `artifacts/qa/candidate-buffer-depth-final-verification.json`.

### 2026-09-17: bounded candidate measurement qualified during recording and streaming

[Candidate resource bounds](2026-09-17-candidate-resource-bounds.md) now preserve
the four-entry raw ingress queue while permitting at most sixteen unresolved
inputs and 64 MiB of aggregate raw payload. Count and byte reservations are
released only after validated compressed dequeue. Fresh native evidence includes
admission timestamps and actual raw byte sizes; independent version 2 verification
reconstructs the bounds. Historical version 1 checks remain available.

Three native simulator trials qualified 360p, 540p and 1080p candidate encoding
alongside 1080p local recording and 240p live publishing. Each candidate reconciled
121 frames over four seconds, peaking at fourteen unresolved inputs and 43,606,080
raw bytes. Measured pre-mux video costs were approximately 3.72, 3.67 and 6.88 Mbps,
respectively. All archive and received-live saved ranges were consecutive at
approximately 30 fps, with all expected audio markers matched and no pressure
counter increases. These are finite simulator measurements, not physical-device
or sustained thermal qualification.

SDK 243, Streaming 123, native model 309 and tooling 1,795 tests passed, along with
simulator and unsigned combined phone/Watch builds, both Watch architectures,
SDK provenance, spec and quality reviews. A stale incremental Streaming consumer
layout was resolved by a clean rebuild with unchanged sources; the failed and
clean evidence is retained. Frozen evidence:
`artifacts/qa/candidate-resource-bounds-final-verification.json`.

Next combine fresh candidate video cost with audio/mux/transport cost and repeated
fresh headroom observations, then enable and qualify upward trials and recovery.
Normal production automatic upgrades remain disabled. Long-session campaigns,
physical phone/Watch networking and portable remote workers remain open.

### 2026-09-17: finite candidate audio/video mux accounting implemented

[Candidate transport cost](2026-09-17-candidate-transport-cost.md) now provides a
bounded off-network owner that feeds compressed H.264 and AAC-LC through the
production MPEG-TS muxer. It counts actual mux bytes and separately rounded
1,316-byte SRT payload chunks, including startup headers, program tables and
padding. It creates no output queue, task or socket. Input counts, compressed
bytes, source span, formats and packet structure have explicit limits.

The candidate encoder can deliver validated compressed frames synchronously to
this owner. Rejection fails only the optional measurement; cancellation and native
cleanup remain joined. Review caught and regression tests reproduced a native
failure-forwarding race and metadata-only initial-keyframe validation. The fixes
check the native failure latch at consumption admission and require an initial
IDR plus slice data in every video input.

Final verification passes 34 focused tests, 259 SDK tests, 123 clean Streaming
tests, 309 clean native model tests, and 1,795 tooling tests. Exact mux comparisons
cover eight payload sizes; a real VideoToolbox encode feeds the public measurement
hook. Clean simulator and unsigned combined phone/Watch Release builds pass, with
arm64 phone and arm64_32/arm64 Watch binaries. All 162 upstream hashes and the
maintained patch round trip verify; spec and quality reviews approve. All 3,562
prior frozen evidence files are unchanged. Evidence manifest:
`artifacts/qa/candidate-transport-cost-final-verification.json`.

This qualifies the accounting primitive, not a fresh concurrent native A/V cost
window, decoded audio quality, network delivery or spare capacity. Next connect
fresh live AAC to the candidate's source window, export independently verifiable
accounting, and test it alongside recording, live publishing and repeated fresh
headroom probes. Production automatic upgrades remain disabled until that combined
admission is qualified. Physical-device networking and remote workers remain open.

### 2026-09-17: fresh candidate audio/video transport cost qualified

[Fresh candidate A/V windows](2026-09-17-candidate-av-window.md) now pair actual
live AAC packets with bounded off-network candidate H.264 and feed both through
the production MPEG-TS muxer. The owner binds one publishing generation, source
window and candidate identity; rejects stale or incomplete audio; caps pending
payload; and joins cancellation and native completion. Version 3 scalar receipts
allow independent exact replay of timestamp headers, program tables, packet
padding and separately rounded SRT payload messages.

Fresh 360p, 540p and 1080p simulator trials each reconciled 121 candidate frames
over four seconds alongside independent 1080p recording and 240p live publishing.
Actual combined application-payload costs were about 3.925, 3.867 and 7.145 Mbps
for this structured source. All archive/live saved frame ranges were consecutive
at approximately 30 fps with all expected audio markers, and candidate-window
pressure counters stayed unchanged. Initial acquisition is accounted separately.
The measurements include audio and mux packaging, but do not establish spare
capacity, retransmission cost, decoded candidate quality or physical-device limits.

Verification passes 266 SDK, 139 Streaming, 310 native model and 1,878 tooling
tests; simulator and unsigned combined phone/Watch builds; both Watch
architectures; SDK provenance and independent reviews. A native trial exposed a
verifier assumption that no-reordering requires absent DTS. Regression tests now
accept DTS exactly equal to PTS and still count its additional header bytes. The
failed run remains frozen; all three qualifying trials are fresh. Evidence:
`artifacts/qa/candidate-av-window-final-verification.json`.

Next combine these fresh costs with repeated fresh headroom observations from the
same publication, then qualify upward transitions and recovery. Production
automatic upgrades remain disabled. Long sessions, physical phone/Watch networking
and deployment on other proxy systems remain open.

### 2026-09-17: concurrent candidate cost and receiver load qualified locally

[Candidate cost and receiver headroom](2026-09-17-candidate-headroom.md) now has
an explicit simulator route combining minimum-quality live publishing, independent
1080p recording, fresh candidate A/V encoding and staged native SRT probes. Only
staged-v2 permits up to 12 Mbps; legacy-v1 remains capped at 2 Mbps. Payload/time
budgets, renewable ownership and joined teardown remain bounded, and the fresh
relay image leaves earlier qualification images intact.

Two fresh native runs each reconcile 121 candidate frames and their actual AAC,
MPEG-TS and per-message IPv4 accounting. The 360p candidate costs 4.072 Mbps and
requires 5.090 Mbps with the 25% margin; repeated receiver intervals confirm at
least 10.024 Mbps of padding payload. The 1080p candidate costs 7.405 Mbps and
requires 9.257 Mbps; repeated delivery confirms at least 9.770 Mbps. The comparison
credits no nominal current live throughput. Exact probe identity, current leases,
clock bounds, candidate overlap and receiver endpoints after candidate completion
are independently checked; the latest eligible intervals control the result.

Both archive/live saved ranges are consecutive at approximately 30 fps, with all
expected audio markers and no candidate-window capture/publishing drop or rejection
increases. Review exposed cached-lease and out-of-order async read failures. Tests
reproduce them; bounded fresh revalidation and lifecycle checks prevent false
cancellation, stale admission and overwriting joined evidence.

Verification passes 270 SDK, 398 Core, 139 Streaming, 327 native model, 480 API and
1,902 tooling tests, the relay probe race suite, type checks, provenance, clean
simulator and unsigned phone/Watch builds, and independent reviews. All 4,839 prior
frozen evidence files remain unchanged. Evidence manifest:
`artifacts/qa/candidate-headroom-final-verification.json`.

This is a historical local-IPv4 load qualification, not online admission or proof
of sustained physical-device capacity. Results explicitly report media health
qualification and upgrade authorization as false. Negative cases are covered in
automated tests; combined native impairment/withdrawal campaigns remain open.
Next add a candidate-specific runtime admission type, correlate fresh online media
health, and exercise upward trials, rollback and recovery. Production automatic
upgrades remain disabled. Long sessions, phone/Watch networking and remote proxy
deployment remain open.

### 2026-09-17: measured candidate admission and owned application contract

[Runtime candidate admission](2026-09-17-runtime-candidate-admission.md) now has a
measured-only Core strategy and a separate event that consumes fresh candidate
load without recounting healthy source windows. Healthy media alone cannot
increase quality. Actual whole-stream candidate cost, conservative receiver clock
bounds, two consecutive delivered-padding intervals and the 25% margin determine
whether Core may recommend the exact next recipe.

The typed native cost converter verifies encoder identity/recipe, bounded source
and host times, frame throughput and latency, complete AAC continuity and mux
accounting. The app adapter binds that result to the acknowledged native receipt,
current probe lease and revocable candidate/receiver ownership. Session admission
also requires the same authenticated worker publication as the qualified source
health. Authority is checked again immediately before native application; admitted
work then owns its separate two-second completion deadline and ten-second trial
confirmation. Expected probe retirement during an admitted change does not revoke
that application.

Review regressions cover zero-duration overlap, invalid clock watermark poisoning,
historical receiver intervals surviving ordinary two-second polling gaps, cached
candidate revocation, same-tick source/candidate admission and preservation of
pending downward advice. Verification passes 426 Core, 143 Streaming, 350 native
model and 306 independent replay tests. Build and evidence checks are recorded in
`artifacts/qa/runtime-candidate-admission-final-verification.json` after completion.

This contract checkpoint keeps production increases disabled. The model provider
and explicit live simulator route still need wiring and independent trial,
withdrawal and rollback qualification. Existing fixed-profile headroom evidence
remains unchanged. Phone/Watch networking, long sessions and other proxy hosts
remain open; the goal is still active.

### 2026-09-17: measured candidate provider and native integration diagnostics

The current model now supplies typed candidate evidence after bootstrap, with
fresh native probe reads and ownership checks after asynchronous work. The
explicit measured simulator route combines source health, deadline monitoring,
actual candidate cost and receiver padding at baseline 240p/target 360p. It requests
100 ms worker reports, an explicit 1.5-second delivery budget, and raw report
capture; the separate 250 ms freshness limit remains unchanged.

Native diagnostics exposed and reproduced integration failures that unit tests
alone did not catch: reporting at 1 Hz could not satisfy freshness; the old 1-second
delivery budget was below measured normal latency; the driver could consume its
one-shot candidate 128 ms before matching source health; and the first healthy
post-upgrade delivery could incorrectly invalidate a trial solely because its
owned encoder revision changed. The caller now defers candidate evaluation until
fresh matching overlap exists. Successful native/policy acknowledgment advances
delivery revision and clears lane watermarks while retaining worker authority.
Actual authority replacement and bad delivery still invalidate/reset.

The independent candidate witness replay checks the exact latest receiver pair,
raw candidate cost, native lease/counter consistency and conservative clock
chronology. It explicitly grants neither media health nor upgrade authorization.
Diagnostic C independently proves 130 healthy deadline windows and continuous
30 fps archive/live media. Diagnostic D performed native 240p→360p→240p with exact
profile/bitrate receipts and continuous 30 fps media; its reset exposed the
revision-bookkeeping bug above. Diagnostic E verified the correction and exposed
an older cadence snapshot surviving actor waits. The driver now reads current
cadence and matching diagnostics after those waits, with exact recording/session
ownership. Diagnostic F upgraded and reset correctly when the current report
aged from 218 ms to 261 ms, crossing the unchanged 250 ms freshness limit. Its
archive and live output fully decoded at approximately 30 fps with no fixture
frame loss. Sustained ten-second confirmation still needs telemetry scheduling
work and independent native transition/lifecycle evidence.

Detailed evidence, failures and next steps are retained in
[the runtime integration plan](2026-09-17-runtime-candidate-admission.md). Full
native transition/lifecycle replay, sustained trial confirmation and controlled
withdrawal/rollback qualification remain open. The fixed-profile validator is
kept strict and rejects a stream that changes dimensions. Production automatic
upgrades, physical-device performance and other proxy hosts remain unqualified;
the autonomous goal stays active.

This integration checkpoint passed all 374 FilmModel tests, 451 affected independent
replay tests, clean simulator build-for-testing and unsigned iPhone/Watch Release
builds. Reviews approved the runtime and timing regression fixes. The immutable
manifest is `artifacts/qa/measured-live-trial-final-verification.json`; all six native
diagnostics retain their failed whole-run status and original evidence.

### 2026-09-17: native measured transitions and lifecycle evidence

The explicit measured simulator route now exports complete native phase evidence
and a separate bounded lifecycle history. Stop joins encoder changes, bitrate
writes and terminal probe reads before exporting. Completed candidate diagnostics
remain immutable while runtime authority still retires immediately. Reviews and
382 model/502 affected Node tests passed.

A native run independently verified 240p→360p→240p, exact profile/bitrate receipts
within their owned application deadlines, and all 121 measured candidate frames
within the actual baseline and decoded stream. The 1080p local recording and live
output fully decoded at approximately 30 fps with no frame loss after initial
acquisition and all audio markers. Evidence is indexed by
`artifacts/qa/measured-transition-final-verification.json`.

The trial reset when the current report exceeded 250 ms, so sustained confirmation
is still unproven. Next improve telemetry scheduling without loosening freshness,
then join admission, lifecycle and post-change health into the full independent
native-trial gate. Production increases and physical/remote performance remain
unqualified; the goal stays active.

### 2026-09-17: monotonic telemetry polling and stage timing

Control polling now uses fixed monotonic start-to-start slots, skips overruns and
preserves sequential requests, interval changes and cancellation. A bounded DEBUG
audit separates maintenance, HTTP, native probe reads and processing. Freshness
limits and ownership guards are unchanged. All 390 FilmModel tests, clean simulator
and unsigned phone/Watch Release builds passed; both reviews approved.

The native comparison improved median report spacing from 133 ms to 100 ms.
Independent replay verified the 240p→360p→240p sequence, native receipts, candidate
source correspondence and continuous 30 fps archive/live media with all audio
markers. The trial nevertheless reset after approximately 9.3 seconds on delivery
freshness; sustained confirmation remains unproven. Exact delivery evidence across
policy actor waits and worker timing-token age are the next investigation, along
with the full independent measured-trial gate. Evidence is indexed by
`artifacts/qa/telemetry-scheduling-final-verification.json`; production increases and
physical/remote performance remain unqualified. The goal remains active.

### 2026-09-17: fresh worker timing and observed native confirmation

Worker/API registration now negotiates a fresh timing challenge immediately before
each sample. The server keeps one independent session-bound token; old token
issuance, report idempotency, ownership and 250 ms consumer freshness remain
conservative. Repeated cadence samples retain their original age. The reporter
keeps coalescing, a shared deadline and bounded session recovery. All 500 server
and 392 worker tests, affected builds/typechecks and two independent reviews passed.

The native comparison reduced median audited report age from 178 ms to 73 ms.
The controller logged trial confirmation after upgrading from 240p to 360p and
stayed there until stop, approximately 69 seconds after acknowledgment. Independent
replay verified native phases/receipts, candidate source correspondence, all 147
healthy deadline windows and continuous 30 fps archive/live A/V with all markers.

This is observed runtime confirmation, not complete independent trial admission
qualification. The full harness still rejects the changing stream at its old
fixed-format gate. Next join candidate witness, native probe retirement, lifecycle
and policy probation into the complete measured verifier, then exercise controlled
withdrawal/recovery and longer sessions before physical devices and other hosts.
Production increases remain disabled; the goal stays active. Details and evidence
are in [the fresh worker timing plan](2026-09-17-fresh-worker-sample-timing.md) and
`artifacts/qa/fresh-worker-timing-final-verification.json`.

### 2026-09-17: complete measured native trial qualification

The explicit measured route now independently joins startup, candidate A/V cost and
actual source correspondence, receiver load/admission, causal native probe retirement,
owned encoder/bitrate application, all intervening cadence reports and sustained
post-change health. The fixed-profile gates remain strict. All 2,080 tool tests and
independent reviews pass; the old successful diagnostic qualifies and an old reset
diagnostic rejects without changing either artifact.

Fresh iPhone 14/iOS 17.5 run `native-app-LkAs1j` passes the complete native harness:
240p→360p, approximately 15 seconds of independently reconstructed probation, and
69.6 seconds at the higher profile through stop. The clean 1080p archive has 3,671
frames and all 61 audio markers; live output has 3,296 acquired frames and all 55
markers. Both decode at approximately 30 fps without source loss after accounted
initial acquisition. All 145 measured delivery windows are healthy, with no unknown
classifications. Scoring, archive diagnostics, ingress and direct recorder checks
also pass.

This qualifies one successful local measured increase. Production increases remain
disabled. Next qualify controlled withdrawal/reset/recovery and longer adaptive
sessions, then physical phone/Watch networking and other proxy hosts. Details are
in [the combined verifier plan](2026-09-17-combined-measured-trial-verifier.md) and
`artifacts/qa/combined-measured-trial-final-verification.json`. The goal remains active.

### 2026-09-17: measured fault/recovery verifier and streamed-audio startup failure

The local measured route now has a separate mandatory recovery verifier. It joins
confirmed admission, exact owned decoder-pause evidence, either native delivery-loss
or decoder-stall reset, native application receipts, and at least ten seconds of
whole healthy source windows after resumed progress, covered independently by both
delivery lanes. The original successful-trial gate remains strict. All 2,269 tool
tests and final combined reviews pass.

Unchanged run `native-app-mnaRRb` qualifies by independent retrospective recovery
replay; its original harness exit remains 1. Earlier runs retain their failures:
`native-app-PZGuFl` had a stale pre-pause observation, and `native-app-TPUMig` had a
late control-polling gap. The fixture's scoped process revalidation fixed its own
pre-pause delay without changing freshness limits. The cause of the separate
control-maintenance delay remains unresolved.

Fresh frozen-source run `native-app-4xzLz8` still fails the complete harness: its
streamed output starts audio 429 ms after video, beyond the unchanged 100 ms budget.
The independent local archive passed, with 3,609 consecutive 1080p frames and
aligned audio/video start. Next diagnose streaming audio startup and obtain a full
native recovery pass before repeated ramp-up, longer runs, physical devices and
other proxy hosts. Production increases stay disabled; the goal remains active.
See [the recovery plan](2026-09-17-measured-posttrial-recovery.md) and
`artifacts/qa/measured-posttrial-recovery-final-verification.json`.


### 2026-09-17: fresh candidate startup and repeated native scheduling

The subsequent full native run `native-app-ceM4Yc` passed the complete single-cycle
streaming/scoring/export harness: 240p→360p, controlled decoder stall, fallback,
and approximately 15 seconds of reconstructed healthy recovery. The independent
1080p archive contained 3,675 consecutive frames and all 61 audio markers; acquired
360p live output contained 3,299 consecutive source frames and all 55 expected
markers, both at 30 fps. Production automatic upgrades remained disabled.

The next native DEBUG checkpoint adds two bounded probe/candidate campaigns,
current recovery readiness at a newer applied revision, joined retirement before
reuse, and protection against delayed callbacks crossing campaign boundaries.
All 438 FilmModel, 458 Core and 2,304 tools tests and the unsigned iPhone/Watch
Release build passed. The single-cycle harness rejects repeated mode until its
independent replay supports both campaigns. No repeated native run is qualified
by these component tests.

Next implement the versioned two-cycle verifier and two controlled faults, then
run and independently decode the full repeated stream and archive. Physical
phone/Watch networking and portable proxy hosts remain later gates. See the
[repeated native campaign plan](2026-09-17-repeated-native-campaigns.md).


### 2026-09-17: repeated native evidence replay foundations

The independent native probe replay now validates two original v3 campaigns with
separate budgets and joined terminal ownership. Raw receiver validation preserves
v3 campaign counters and publication totals across restarts. A new explicit v9
native media export and replay cover all five 240/360/240/360/240 phases with exact
encoder receipts and decoded boundary frames. These component results grant no
capacity, policy or production upgrade permission.

All 439 FilmModel and 2,459 tool tests passed, as did the arm64 simulator and
unsigned iPhone/Watch Release builds. Generic Intel simulator linking failed
because the bundled SRT archive lacks the required x86_64 symbols; that original
failure remains recorded. No full repeated A/V run has been performed.

Next join both original candidate measurements/revisions with receiver intervals,
replay the complete policy and fault/recovery timeline, and add the two owned
faults to the native harness. The harness continues to reject repeated mode until
that combined gate exists. See the [repeated verification plan](2026-09-17-repeated-native-verification.md)
and `artifacts/qa/repeated-native-verification-*` evidence. The full goal remains active.

### 2026-09-17: repeated candidate and receiver evidence ownership

The repeated receiver replay now reconciles all six probe stages against raw
native acceptance, with separate campaign counters and continuous publication
totals. Both candidate A/V measurements are independently checked against their
real baseline frames and original campaign/revision, native lease and pacing
history. Native interval exports preserve campaign identity and reject crossed
owners before deduplication.

All 440 FilmModel and 2,565 tool tests passed, along with the arm64 simulator and
unsigned iPhone/Watch Release builds. These checks cover the new evidence
boundaries; they do not qualify a complete repeated ramp. Remaining work is the
interval/admission/lifecycle joins, full policy and fault/recovery replay, and
the two-fault native harness. Production automatic upgrades remain disabled.
See the [repeated verification plan](2026-09-17-repeated-native-verification.md)
and `artifacts/qa/repeated-native-binding-*` evidence.

### 2026-09-17: repeated native lifecycle and probe retirement

Repeated lifecycle replay now matches all four native profile changes and five
bitrate writes to the original revision/receipt chain, independently replaying
the five media phases. Both probe campaigns are tied to their actual trial
requests and joined cancellations, with the correct startup/reset baseline.
The checks handle native UUID formatting differences and valid probe renewals
after the admission snapshot while rejecting stale or crossed authority.

All 2,711 tool tests passed; 269,193 prior evidence files remain unchanged.
Receiver interval and full candidate admission replay remain next, followed by
complete policy/fault/recovery replay and the two-fault native run. No complete
repeated A/V qualification or production automatic upgrade permission is claimed.
See the [repeated verification plan](2026-09-17-repeated-native-verification.md)
and `artifacts/qa/repeated-native-lifecycle-*` evidence.


### 2026-09-17: repeated receiver intervals and complete admissions

Both ramp-up admissions now replay their own raw candidate A/V cost, native
acceptance, receiver intervals, worker ownership and actual profile requests.
The second admission retains its original reset baseline and revision, with
fresh captured receiver evidence and 25% measured padding headroom. Cross-proof
checks reject impossible accepted-data bursts and backward progress where the
recorded read order is known. Unselected rows may invalidate evidence but cannot
replace the captured admission pair.

All 2,843 tool tests passed, including 132 new cases; independent specification
and quality reviews approved the admission boundary. All 269,231 frozen evidence
files remain unchanged. Runtime sources are unchanged, so no new native build
or full A/V run is claimed at this checkpoint. Next replay both complete policy,
fault and recovery cycles and add causally triggered faults to the repeated
simulator harness. Production automatic upgrades remain disabled. See the
[repeated verification plan](2026-09-17-repeated-native-verification.md) and
`artifacts/qa/repeated-campaign-admission-*` evidence.


### 2026-09-17: repeated fault causality and shared raw media replay

Both controlled pauses now retain their original confirmation, candidate,
trial/reset revisions, native media phase and decoder process ownership. The
second cycle must show new decoder progress, and each resumed observation must
remain inside its own campaign. Candidate and confirmation receipts are tied
directly to the actual trial so mutually consistent but foreign evidence cannot
qualify a fault. Existing single-cycle raw media checks are shared without
changing their qualification requirements.

All 2,903 tool tests passed, including 60 new repeated-fault cases. All 269,285
frozen evidence files remain unchanged. Runtime sources are unchanged; no new
native build or full repeated A/V run is claimed. The global policy and healthy
recovery replay, second-campaign readiness join and causal two-fault native
harness remain pending. Production automatic upgrades remain disabled. See the
[repeated verification plan](2026-09-17-repeated-native-verification.md) and
`artifacts/qa/repeated-policy-replay-*` evidence.


### 2026-09-17: complete repeated policy replay and native readiness joins

The repeated verifier now consumes one original global history through both
trial confirmations, controlled faults, resets and recoveries. Recovery requires
at least ten seconds of whole healthy source windows after resumed progress,
independently covered by one- and two-second delivery lanes. The next probe's
captured readiness is tied to its actual configuration and reconstructed health;
all evidence needed for the preceding recovery must exist before that probe
starts. Native evaluation time is distinguished from delayed diagnostic logging.

The raw composition now invokes media, lifecycle, admission, policy, readiness
and delivery-coverage checks. Positive component integration covers decoder
stalls, delivery failures and mixed routes with raw admissions and lifecycle.
These fixtures still supply explicit source/media contracts, so they are not a
complete positive raw-media or native A/V run. The repeated harness still needs
live confirmation checkpoints, both causally owned pauses and the raw gate wired
into its existing recording, scoring and A/V checks.

All 3,005 tool tests passed, including 102 new cases. All 269,319 frozen evidence
files remain unchanged, and runtime source has not changed. A legitimate final
source-export suffix during shutdown is checked without adding health credit;
consumed intervals must match the original array prefix. The current stop export
has no independent terminal policy cursor, so it cannot distinguish a removed
last decision from a never-consumed source tail. Interior omissions still reject.
Production automatic upgrades remain disabled. See the
[repeated verification plan](2026-09-17-repeated-native-verification.md) and
`artifacts/qa/repeated-policy-integration-*` / `repeated-global-policy-*` evidence.


### 2026-09-23: resumed decoder-freshness verification

Resumed review fixed a false-freshness acceptance in the new global verifier.
Repeated decoder timestamps must retain one feasible last-arrival time across
reports and both faults; legitimately cached snapshots remain accepted. New
synthetic cadence, raw deadline packets and owned-pause samples share a physically
consistent arrival schedule. All 3,016 tooling tests and 344 focused new/legacy
tests pass; the new policy suite contains 74 cases. The saved native run also
passes a read-only timing-bound check for 1,039 applicable reports. All 269,319
previously frozen evidence files remain unchanged after the resumed check.
Full repeated native A/V qualification and production upgrades remain pending.


### 2026-09-23: live checkpoints and supplied match footage

The repeated simulator route now has bounded asynchronous live quality
checkpoints and a reader that retains original event indices, requires actual
trial/receipt ownership and waits for a whole post-confirmation source window.
Stop drains the terminal checkpoint. Connecting this boundary to both controlled
pauses and the complete native harness remains next; production upgrades stay
disabled.

Both supplied recordings are identified and fingerprinted without modifying the
originals. Twelve-second 1080p and 4K excerpts pass all four local proxy processing
checks (CPU and VideoToolbox, 360 frames each). The 4K input is HLG HDR and is
explicitly tone-mapped for the SDR test stream. A first SRT→proxy→RTMP content
replay failed on five undelivered final frames; a separate drain diagnostic also
failed and is preserved. Neither is counted as end-to-end qualification. See
[the footage assessment](../../representative-match-testing.md) for commands,
measurements, limitations and the next network checks.

Verified checkpoint: 3,043 tool tests and 446 FilmModel tests passed (including
28 driver tests); all 27 checkpoint-reader tests passed. The arm64 iOS 26.2
simulator build and unsigned iPhone/embedded-Watch Release build passed.
Independent specification and quality reviews approved the frozen runtime/test
sources. All 269,407 earlier evidence files and both supplied original videos
were verified unchanged. Evidence is under `artifacts/qa/repeated-live-checkpoint-*`.
This is a harness foundation checkpoint; full repeated native A/V qualification
and the real-match network test remain open.
