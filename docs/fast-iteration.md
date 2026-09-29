# Fast local iteration

The local feature set has retained integration evidence. Start with the
[acceptance matrix](simulator-acceptance.md) and
[remaining work](superpowers/plans/2026-09-13-portable-streaming-and-watch.md),
not a fresh broad test run. Hardware is deferred.

## Choose one check for the change

| Change | Check after the batch |
| --- | --- |
| Documentation | Review the diff and local links; no app tests |
| Node fixture | `node --test scripts/test/<affected-file>.test.mjs` |
| API or worker behavior | Relevant Vitest file; typecheck the affected package if types changed |
| Native model | Affected XCTest class with existing DerivedData |
| Native UI | Affected simulator workflow, using an installed runtime |
| Contract spanning apps/API/worker | One full vertical checkpoint below |
| Encoder/transport/media behavior | One targeted native media run answering a specific question; inspect saved media |

For example, select one existing test file with
`pnpm --filter @scorebug/home-daemon exec vitest run <test-file>`.
Build `@scorebug/protocol` first only if its sources changed or its output is missing.
Do not run both focused and broad suites for the same unchanged behavior. Broaden
only for a new failure, a changed shared contract or a release checkpoint.

## Full native checkpoint, when needed

Run from the authoritative checkout. Supply the current private LAN address and
an existing prepared 1080p fixture long enough for the workflow. Preserve originals.
This uses the existing runner, two iPhone 14 simulators and a Series 7 41 mm Watch:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
node scripts/test-native-created-simulators.mjs \
  --host YOUR_PRIVATE_LAN_IP \
  --source /absolute/prepared/input.mov \
  --encoder software --watch separate
```

The runner incrementally builds into `ios/DerivedData/OrdinaryNativeApp`, creates
its own devices, runs native creation/scoring/recording/streaming and Watch actions,
and preserves output before removing only its own devices. It requires installed
iOS/watchOS 26.2 runtimes and committed app/fixture source; it does not download
runtimes. Watch setup uses a scoped simulator fixture; scoring uses real HTTP.
This does not qualify WatchConnectivity, radios or physical capture.

The lab records both the overlaid proxy MP4 and mock RTMP destination MP4. The
phone exports its clean recording. A runner pass alone is not media acceptance:
after a media-affecting change, inspect/decode all three and compare audio, frame
continuity and score changes. Reuse the retained verified recordings otherwise.
Do not add a sustained UHD run to this checkpoint unless UHD behavior changed.

## Hands-on simulator session

Use this when you want to operate the apps yourself instead of running UI tests:

```sh
node scripts/simulator-lab.mjs --host YOUR_PRIVATE_LAN_IP --duration 1800
```

The launcher uses the installed iOS/watchOS 26.2 runtimes and Xcode 26.2, builds
incrementally without tests, and opens a camera iPhone 14, a scoring iPhone 14 and
a Series 7 41 mm Watch. It starts the existing local API, SRT relay, software proxy
and mock RTMP recorder. The duration starts when all apps are launched.

The camera uses synthetic A/V by default. Add `--source /absolute/prepared/input.mov`
to replay representative footage instead. The source is copied into the new camera
app container; the original is unchanged. Capture ends at the end of a finite file.

1. On the Watch, tap **Join offered match** while the temporary offer is valid.
   This accepts setup; take over scoring when you are ready.
2. On each phone, open **Score**. The temporary local server and token are prefilled;
   connect and choose the seeded HOME/AWAY match. Take over on the scoring phone.
3. On the camera phone, open **Film → Setup** and enter the same server/token from
   the printed private `setup.json`, worker `mac`, output `local-sink`, then connect.
4. Start recording, then streaming. Score from the other phone or take over on the
   Watch. The Watch is configured for the same match using a scoped simulator
   setup fixture and real HTTP; this does not test WatchConnectivity/radios.
5. Stop streaming, leave recording running briefly, then stop and export it from
   **Recordings**. Stop the lab with Ctrl-C after finishing recording.

The lab preserves the clean recording in the camera simulator and both overlaid
MP4s under its artifact directory; see [output paths](device-testing.md#short-physical-smoke).
It retains the three simulators so you can inspect/export/recover recordings.
`devices.json` identifies them, and `session.json` points to the private lab setup.
No unrelated simulator is modified. Each new launch creates a fresh session and
credentials; remove only those named devices after saving any wanted recordings.
Lab timeout stops the backend; it does not delete devices or stop a local recording.

To run the proxy in the prebuilt Linux CPU image on this Mac's Docker Desktop,
add `--worker-image scorebug/home-daemon:YOUR_TAG` to the simulator launcher or
backend-only device lab. The image must already exist; startup never pulls it.
Build it once with `docker build -f apps/home-daemon/Dockerfile -t
scorebug/home-daemon:YOUR_TAG .`. The lab maps only worker state and proxy recordings,
keeps credentials in a private environment file, and removes its owned container
on shutdown. The lab worker ID remains `mac` for compatibility with app setup.
This local adapter is software-only; production home/cloud configuration remains
in the [worker deployment guide](../apps/home-daemon/README.md#linux-cpugpu-deployment).

For an already installed app or a later physical session, use the backend-only
[device lab instructions](device-testing.md#start-the-local-stack).

The supported colocated media path uses the software proxy. Simulator UHD and
severe-congestion limits, colocated VideoToolbox/probe loss, and abrupt crash tails
remain explicit open items. Do not call those paths green or rerun an unchanged
failure hoping for a pass.

For an interrupted-output investigation, the headless native runner accepts
`--packet-timing on`. This opt-in diagnostic retains the first and last128 numeric
packets per A/V demux/mux lane. Private `packet-timing/*.json` files in the lab
artifact survive worker SIGKILL. Treat any malformed/truncated/pipe-error report as
invalid; compare with saved MP4 packet ends. This adds FFmpeg debug logging overhead
and is diagnostic evidence, not throughput qualification. It is off by default and
currently requires the native lab worker.
