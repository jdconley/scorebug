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

## Hands-on local stack

For manual app use, the existing
[device lab instructions](device-testing.md#start-the-local-stack) start the API,
SRT relay, software overlay worker and both recording outputs with one command.
Use the generated private `setup.json` to configure the native apps. The lab is
bounded and retains recordings when it stops; no real YouTube destination is used.

The supported colocated media path uses the software proxy. Simulator UHD and
severe-congestion limits, colocated VideoToolbox/probe loss, and abrupt crash tails
remain explicit open items. Do not call those paths green or rerun an unchanged
failure hoping for a pass.
