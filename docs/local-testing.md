# Local validation and device qualification

Plan prepared September 13, 2026; milestone 0 validated September 14 UTC.
Environment checks and the native scoring lifecycle now run. Durable match API and
client recovery details are in [native scoring progress](native-scoring-api.md).
The full media pipeline, watch app, and device qualification remain to be implemented.
Follow the [delivery plan](superpowers/plans/2026-09-13-portable-streaming-and-watch.md).

## What is available on this Mac

| Item             | Observed                                                                               |
| ---------------- | -------------------------------------------------------------------------------------- |
| Machine          | MacBook Pro, Apple M4 Max, 128 GB RAM, arm64                                           |
| OS / Xcode       | macOS 26.6.2 / default Xcode 26.6; scoped Xcode 26.2 used for builds                   |
| Docker           | Desktop Linux VM, aarch64, Engine 29.2.1                                               |
| Node             | 25.9.0 in final checks; repository/CI targets Node 22.13+                              |
| pnpm             | Repository pins 9.15.0                                                                 |
| Default FFmpeg   | 8.1.2; has VideoToolbox, but lacks SRT and drawtext                                    |
| Full FFmpeg      | `/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg`, 8.1.2; SRT, drawtext, VideoToolbox present |
| XcodeGen         | 2.46.0 installed during milestone 0                                                    |
| iOS runtimes     | Includes 17.5, 18.5, 26.2                                                              |
| watchOS runtimes | Includes 10.0, 10.5, 11.5, and 26.2                                                   |
| Device types     | iPhone 14, Ultra 2, Series 7 41 mm, and newer devices available                        |

A three-second synthetic 1080p/30 VideoToolbox job completed 90 frames at about 8.9x
real time. A three-second 4K/30 job with drawtext using the full binary completed 90
frames at about 3.1x real time. Both disabled software fallback. These establish short
hardware/filter capability only: no SRT, long soak, phone encoding, or YouTube claims.

## Reproducible milestone 0 commands

From a fresh checkout, install Node 22.13+, pnpm 9.15.0, Docker Desktop, and a full
FFmpeg build with SRT, drawtext, a working H.264 encoder, and a readable font.
For Apple tests, install full Xcode, XcodeGen, and the requested iOS runtime.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
pnpm format:check
pnpm run doctor
pnpm test:container
pnpm test:local
pnpm test:apple
pnpm test:scoring
```

Use **`pnpm run doctor`**, because `pnpm doctor` invokes pnpm's own built-in doctor.
The project doctor prints exact binaries and real six-frame encode/filter results;
an encoder listed by FFmpeg but unusable on the host does not count as a pass.
`--media-only` omits Node/Docker/Apple prerequisites; `--json` emits a report.

On this Mac, default Xcode 26.6 could not resolve build destinations because its
iOS 26.5 platform component is missing. Use the complete existing installation
for each Apple command without changing `xcode-select` globally:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm run doctor
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:apple
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer SCOREBUG_IOS_RUNTIME=17.5 pnpm test:apple
```

The doctor checks tool availability; `test:apple` is the actual build/destination
gate. The runner creates, tests, and removes its own iPhone simulator. Existing
simulators are untouched. Results remain in ignored `ios/build/*.xcresult`.
The UI exercises create, scoring, relaunch recovery, undo, tied-set rejection, and
match end against an owned API/database. Add `--two-phones` for native join/takeover
and cross-device observation. Simulator builds use ad hoc signing for real Keychain
access. Watch and media validation are separate gates.

`test:container` builds and starts the final server image on a random loopback
port, verifies health and authentication, then removes its temporary container and
image. CI also checks the already-built final image. This caught and now guards
against the original missing `@hono/node-server` runtime dependency.
`test:local` starts a uniquely named Compose project, verifies both relay configs
and management authentication, then removes its own containers and volumes.
It requires the fixture ports below to be free; a manually running stack is never
stopped to make room. These startup tests are not end-to-end media tests.

The worker now honors `FFMPEG_PATH` and `FONT_PATH`. `FFPROBE_PATH` is reserved in
worker configuration for the media analyzer; the doctor already uses it. Existing
installations keep PATH-based binaries, the Linux font default, and the legacy
`NVENC_ENABLED` switch. There is no worker encoder auto-selection yet. On this Mac:

```sh
export FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
export FFPROBE_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffprobe
export FONT_PATH=/System/Library/Fonts/Supplemental/Arial.ttf
```

The doctor automatically prefers an installed Homebrew `ffmpeg-full` on macOS;
explicit environment paths override that choice and fail visibly if unavailable.
Use the same paths when starting a worker. No global relinking is needed.

Reproduce the short 4K capability probe (generates no file and starts no broadcast):

```sh
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -hide_banner \
  -f lavfi -i testsrc2=size=3840x2160:rate=30 \
  -vf "drawtext=fontfile=/System/Library/Fonts/Supplemental/Arial.ttf:text='Scorebug test':fontsize=64:x=40:y=40" \
  -t 3 -c:v h264_videotoolbox -allow_sw 0 -b:v 30000000 -f null -
```

This specific font path exists on this machine. Installation packages must provide or
probe a font rather than assume it exists everywhere. Use
[FFmpeg's SRT options](https://ffmpeg.org/ffmpeg-protocols.html#srt) with units checked;
SRT latency expressed in microseconds must not be confused with milliseconds.

## Local topology

```text
Fixture publisher or simulated capture
           │
           ▼
MediaMTX ingest (Docker, SRT 18890/UDP)
           │
           ▼
Native worker (VideoToolbox or software)
           │
           ▼
Local output sink (Docker, RTMP 11935/TCP)
           │
           ▼
Recorded output + decoded-frame/audio analysis

Native iPhone scorer / simulated watch ──► control plane (18787/TCP)
No scoring web server is required.
```

Use the isolated Compose project named `scorebug-qa` with public, test-scoped credentials.
A separate SQLite database will be added with durable game state in milestone 1. Relay and sink are separate services so source and output
failures can be injected independently. The control plane runs natively for rapid
iteration and also has a separate final-container startup test.

Local default ports bind to loopback. The later physical-device profile explicitly
binds API and ingest to the Mac's LAN interface with test-scoped credentials. The
relay management API remains private. Configure the test relay to reach the host
control plane through `host.docker.internal`, not container-local `127.0.0.1`.

The accelerated worker runs on macOS. A separate Linux CPU-worker profile tests
container packaging; Docker on this Mac does not prove NVENC or Apple GPU passthrough.
Do not point automated local tests at YouTube.

### Start and stop the local services

```sh
pnpm local:up
pnpm dev:api
# Ctrl-C stops the API. In another terminal, or after stopping it:
pnpm local:down
```

The native API binds `127.0.0.1:18787`; the scorer's default simulator address is
`http://localhost:18787`. `dev:api` reads `infra/local/.env.example` using Node's
`--env-file`; existing shell environment variables take precedence. Start it in a
shell without production token/host overrides. No `.env` with production secrets
is read. The API is still the in-memory prototype and can only support the older
contracts until milestone 1.

`docker-compose.dev.yml` pins MediaMTX 1.21.0, with independent ingest and output
services. Host listeners are loopback-only: SRT 18890/UDP, RTMP 11935/TCP,
ingest management 19997/TCP, sink management 19998/TCP. Management requires
`qa-admin` / `qa-admin-not-production`. Media credentials and encryption passphrases
are visibly test-only in `infra/local/ingest.yml` and `sink.yml`.
Configuration follows the [pinned MediaMTX reference](https://raw.githubusercontent.com/bluenviron/mediamtx/v1.21.0/mediamtx.yml).

Only `fixture` ingest and `live/fixture` output paths exist. Per-game credential
provisioning and the worker bridge are milestone 2; creating a game does not yet
make its SRT path usable. RTMP output is a local test destination. Nothing here
starts YouTube output. Both smoke runners handle cancellation and report cleanup failures; an in-flight
Docker operation can take up to its two-minute timeout before teardown. The named recording volumes survive `local:down` and expire
recordings after 24 hours while the service runs. To deliberately erase only this
manual test stack's recordings, use `docker compose -f docker-compose.dev.yml down --volumes`.

### Reproducible test media

Generate a short motion-heavy fixture with a visible frame number and timecode, plus
periodic synchronized audio pulses. Repeat it with continuous timestamps for soaks.
Store a manifest of frame rate, duration, dimensions, frame/time mapping, audio markers,
and checksum. Include 720p, 1080p, and 4K sources; add consented volleyball footage for
visual tuning once available. Synthetic footage provides a deterministic first gate.

The analyzer must inspect the full output, count fresh source frame IDs (not duplicates),
check PTS monotonicity and gaps, decode all audio/video, measure pulse/video alignment,
and inspect overlay changes at known times. A successful connection or ffprobe metadata
alone does not prove a correct broadcast.

## Remaining test runner interfaces

These are planned interfaces unless explicitly described above. Milestones 1–5
expand the current foundation into media, scoring, and watch qualification.

| Planned command                                               | Behavior                                                                     |
| ------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `pnpm run doctor`                                             | Report exact tools, protocol/filter support, usable encoders, and runtimes   |
| `pnpm test:integration`                                       | API + SQLite + real worker WebSocket + native client game/recovery contracts |
| `pnpm test:media -- --profile=1080p30 --encoder=videotoolbox` | Fixture → SRT → overlay → local sink → analysis                              |
| `pnpm test:media -- --profile=1080p30 --encoder=software`     | Same assertions with CPU backend                                             |
| `pnpm test:media -- --profile=2160p30 --encoder=videotoolbox` | 4K capability/quality qualification on this host                             |
| `pnpm test:network`                                           | UDP impairment matrix, report quality transitions and archive continuity     |
| `pnpm test:archive`                                           | Native shared media harness, forced termination, recovery, full decode       |
| `pnpm test:apple`                                             | Current: Swift tests + iOS setup UI; watch and scoring suites planned        |
| `pnpm test:soak -- --minutes=120`                             | Sustained run with metrics and output artifacts                              |

Each runner allocates its own state/ports or fails clearly on conflict; writes evidence
under ignored `artifacts/qa/<run-id>/`; returns nonzero when a requirement fails; and
stops only its own processes/containers. Avoid privileged network changes on the Mac,
shutdown of unrelated simulators, and blanket Docker cleanup. Preserve failure evidence.

## Gate A: Server and native iPhone scoring

1. Create one match, join native scorer and capture roles, and attach a worker after creation.
2. Score and undo; verify server state, other client snapshots, and rendered output.
3. Terminate/relaunch the native scoring app and restart API/worker; recover the same match and score.
4. Drop acknowledgments after commit, resend the same command ID, and verify one point.
5. Exercise concurrent/delayed scoring, explicit takeover, stale outbox, and set changes.
6. Reject a tied end-set; validate win-by-two, deciding set, match end, and manual override.
7. End during a network failure; retain a truthful pending/error state and reconcile.
8. Launch the final server container and check HTTP readiness with its own dependencies.
9. Run XCUITest on two iPhone simulators: create/join, score, undo, relaunch, reconcile,
   and take over. Score mode must work with camera/microphone permissions denied.

Pass: no lost or duplicated accepted commands, no refresh lockout, and eventual snapshots
match the authoritative database. Proposed local scoring acknowledgment p95 is under
500 ms; point-to-overlay p95 under one second. Measure them separately from viewer delay.

## Gate B: Actual local media and impairments

Use the real native worker, encrypted SRT, and local sink. Test valid credentials,
wrong publish/read credentials, and post-match revocation. Confirm media readiness
rather than treating socket connection as proof of frames.

Run these scenarios against both source and output paths where applicable:

| Trace           | Proposed stimulus                               | Required observation                                          |
| --------------- | ----------------------------------------------- | ------------------------------------------------------------- |
| Healthy         | 50 Mbps capacity, 20 ms delay, no injected loss | Stable qualified profile and A/V sync                         |
| Bandwidth fall  | 50 → 8 → 3 Mbps, two minutes each               | Bounded queue and quality decrease; archive unaffected        |
| Loss/jitter     | 1%, then 3% packet loss; 80 ms ± 30 ms delay    | Measure recovery/drop cost; no unbounded live backlog         |
| Outage          | 15 seconds with no delivery                     | Truthful reconnect state; recording continues                 |
| Recovery        | Restore 50 Mbps after outage                    | Output resumes, current score restored, cautious upgrade      |
| Worker overload | Limit CPU or inject slow encoding               | Lower viable profile or explicit failed preflight             |
| Process restart | Kill worker/API/sink independently              | Durable match, no duplicate stream owner, supervised recovery |

Use Linux `tc`/netem in dedicated Docker network namespaces with only test-local
`NET_ADMIN`. Shape both SRT directions, including ACK/retransmission traffic; account
for added latency in interpreting recovery. A TCP-only fault proxy cannot validate SRT.
For phone tests, route its SRT destination through the same explicitly exposed test
shaper. Do not change the host's Wi-Fi, routing, or firewall for automated impairment.

Proposed pass criteria:

- 30 fps target; during stable viable periods, at least 24 fresh fps in 99% of rolling
  five-second windows and under 1% fresh-frame loss on an unimpeded qualified profile.
- Report outage and adaptation windows separately and include their total durations.
  Do not remove poor windows to manufacture a passing overall result.
- Step down after sustained overload is detected; resume output within ten seconds of
  restored reachability in the fixture scenario; wait 30 seconds before upgrading.
- Under network-only impairment, archive timestamps and image quality stay independent.
- A/V alignment stays within 100 ms after startup/transition settling. Report gaps and
  settling duration, and fail on accumulating drift.
- No sustained memory growth after warmup; all media queues remain within configured bounds.

These thresholds are initial acceptance targets to calibrate using evidence, not a
claim that arbitrary cellular conditions can always maintain 24 fps.

## Gate C: Shared recording core and simulators

Use fixture capture injection. Run the actual archive implementation in a native macOS
harness and in simulator tests where APIs support it. Test preview/UI without pretending
the simulator supplies the phone camera's encoder, thermal behavior, or sensor quality.
Build for both simulator and generic iOS device to catch platform/linking differences.

Create dedicated Scorebug simulator devices during implementation, leaving existing
project devices untouched. Example for the lowest supported generation:

```sh
SCOREBUG_SIM_PHONE=$(xcrun simctl create 'Scorebug QA iPhone 14' \
  com.apple.CoreSimulator.SimDeviceType.iPhone-14 \
  com.apple.CoreSimulator.SimRuntime.iOS-17-5)
SCOREBUG_SIM_WATCH=$(xcrun simctl create 'Scorebug QA Series 7 41mm' \
  com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Series-7-41mm \
  com.apple.CoreSimulator.SimRuntime.watchOS-10-5)
xcrun simctl pair "$SCOREBUG_SIM_WATCH" "$SCOREBUG_SIM_PHONE"
```

These device types/runtimes exist locally; the example was not executed during planning.
Build the compatibility matrix with OS-supported pairs: iOS 17/watchOS 10, iOS 18/watchOS
11, and iOS 26/watchOS 26. watchOS 11.5 is now installed and its native UI run passes. Add Ultra 2
and small SE layouts. Test with the newest available minor runtime before release, even
though 26.2 is the installed current-generation runtime used for initial local work.

After the planned targets and test bundles exist:

```sh
cd ios
xcodegen generate
xcodebuild -project Scorebug.xcodeproj -scheme Scorebug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Scorebug.xcodeproj -scheme Scorebug \
  -destination "platform=iOS Simulator,id=$SCOREBUG_SIM_PHONE" test
xcodebuild -project Scorebug.xcodeproj -scheme ScorebugWatch \
  -destination "platform=watchOS Simulator,id=$SCOREBUG_SIM_WATCH" test
```

`ScorebugWatch`, its UI test target, and a Debug-only initial setup fixture now exist.
Use `pnpm test:native-watch` for the owned real-API Watch workflow; it supplies the
expiring setup and creates/removes only its own simulator. Directly invoking the UI
scheme without that setup is not a complete test command. See the
[native Watch evidence and limitations](native-watch-app.md). The vendored SRT
simulator binary requires ARM64; use Apple Silicon simulator destinations.

`pnpm test:paired-watch` is the separate real-companion/recording probe. It owns its
simulators and API, requires actual WatchConnectivity setup, and decodes the exported
archive. The older simulator pair currently fails companion registration; this is
an open qualification gate, not a passing command. See the linked Watch evidence
for artifacts, runtime selectors, and the distinction from injected setup tests.

Recording tests: initialization segment durability; termination during a segment and
between file rename/manifest update; no disk space; append/finalize errors; interrupted
export; and a crash followed by relaunch recovery. Fully decode recovered recordings,
compare expected duration/frame IDs, and require tail loss at most five seconds in five
forced-termination trials. Test low-space conditions through injected limits first.

## Gate D: Watch and complete local workflow

- Run native iPhone and watch HTTP scoring against the real API while fixture media
  traverses the worker. No PWA or embedded browser participates.
- Use two dedicated phone/watch pairs: phone A captures; phone B scores in its native
  app; then watch B paired to phone B scores after explicit takeover. Also run watch A
  scoring while its own paired phone A captures. All clients join the same match.
- Verify point/undo acknowledgment, 41 mm layout, error states, end-set confirmation,
  foreground wake refresh, pending commands after termination, and scorer takeover.
- Drop a reply after a committed point, then retry via another route with the same ID.
  Verify it is counted exactly once and pending clears only on authoritative resolution.
- Test optional WatchConnectivity setup and opportunistic relay with doubles when a
  simulator method is unavailable. Never mark that as physical transport coverage.

The watch must use HTTP(S), not a persistent WebSocket. Apple states that simulator
networking can allow operations real watches disallow; see [TN3135](https://developer.apple.com/documentation/technotes/tn3135-low-level-networking-on-watchos).
Apple also requires real-device validation of [WatchConnectivity transfers](<https://developer.apple.com/documentation/watchconnectivity/wcsession/transferuserinfo(_:)>).

## Gate E: Physical phone and both watches, using the Mac as proxy

Use a test LAN profile with the Mac's reachable LAN address. iPhone `localhost` is the
phone itself. Bind only the necessary test API/media ports, use scoped credentials,
and keep management ports private. Grant local-network permission through the normal
OS prompt. Prefer trusted local TLS; if needed, use narrow Debug-only local-network
exceptions, never a global production ATS bypass or disabled certificate verification.
Developer Mode, signing, trust, and camera/mic prompts require normal device setup.

Required combinations:

| Phone / controller                               | What it proves                                                         |
| ------------------------------------------------ | ---------------------------------------------------------------------- |
| Paired iPhone films; Ultra 2 scores              | Required one-phone workflow, larger watch UI                           |
| Paired iPhone films; Series 7 41 mm scores       | Required one-phone workflow, smaller screen/older hardware             |
| Filming iPhone A plus native scorer on iPhone B  | Separate native scorer and explicit takeover                           |
| Filming iPhone A plus watch B paired to iPhone B | Separate watch scorer; no pairing to the filming phone                 |
| iPhone 14 family where available                 | Minimum required hardware performance; simulator alone is insufficient |
| Older supported phone if available               | Capability-based fallback, without a universal 4K promise              |

Use the owner's actual installed OS; do not downgrade or repeatedly re-pair a watch just
for a test. Test each existing pairing in turn. Physical iPhone model is not yet supplied;
record it before selecting capture profiles. If no physical iPhone 14 is available, mark
that performance qualification unverified while retaining compilation/UI compatibility.

Begin with ten minutes at 1080p/30, then 4K/30 if supported. Repeat the sustained test
for each profile being enabled. Two hours of simultaneous capture, streaming, and watch
scoring must run with realistic motion, screen state, power source, and temperature.
Test a release-like build detached from Xcode as well as an instrumented build.

For both watches test every available route: paired-phone proxy, known Wi-Fi without
phone reachability, cellular with an active plan, and transitions between routes. The
OS chooses routing; observe conditions and outcomes instead of claiming deterministic
radio selection. GPS-only or inactive-cellular devices still must work via phone/Wi-Fi.
While cutting phone connectivity, distinguish expected stream loss from archive failure.

Include wrist lowering/waking, haptic acknowledgment, app relaunch, timeout after server
commit, and scoring while the paired camera app remains foreground. No additional phone
is needed for the paired filming-phone/watch case. Separately test the native app on
phone B and watch B paired to phone B taking over and returning control. Use existing
pairings; phone B does not record or request camera permission. Verify watch B scoring
while its own companion app is backgrounded.

Test recording through network-only outages; calls and camera/audio interruptions;
manual lock/background; low storage; and five forced app terminations. Export to Files,
fully decode off-device, compare timestamps/audio markers, and verify no scoreboard was
burned into the local archive. Record OS-caused capture gaps honestly.

At 30 Mbps, two hours of video alone is about 27 GB (decimal). Recovery segments plus
export may temporarily require roughly twice the recording size, plus reserve. Base
actual space preflight on the selected profile and export strategy; do not fill the
owner's device or remove unrelated files.

## Gate F: YouTube, then other proxy systems

After local and device gates pass, use a designated private/unlisted test broadcast with
a supplied stream key. Confirm YouTube ingest health, actual playback, output resolution,
audio, score timing, reconnect, and measured glass-to-glass latency. Test 4K normal latency
and 1080p lower-delay separately; [YouTube's guidance](https://support.google.com/youtube/answer/2853702?hl=en)
does not support the old universal 5–10 second expectation for 4K.

Then run the same fixture and conformance suite on home NVIDIA, cloud CPU/GPU, and later
other backends. Qualify each architecture on real hardware before publishing support.
Reuse configuration and worker code; only endpoints, credentials, paths, and encoder
selection should change. Test colocated and split services, restart, and explicit worker
handoff. A cloud host needs approval/credentials/cost selection at that execution stage;
none is provisioned by this plan.

## Evidence and reporting

Every run records commit, OS/device model, dependency versions, encoder, selected source/
archive/output profiles, network trace, frame/drop/latency measurements, A/V alignment,
archive/export results, score command results, and recovery duration. Redact credentials
and private footage from logs. Preserve local artifacts for review without uploading them.

Report separately: implementation present, automated test passed, simulated behavior,
physical-device behavior, and platform qualification. No green unit suite substitutes
for a recovered phone recording or sustained real-media test.
