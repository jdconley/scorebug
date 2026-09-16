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
