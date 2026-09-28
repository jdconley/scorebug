# September 28: live source recovery, Mac service, consolidated acceptance

Started at `5ba7bf2` on `codex/local-validation`, authoritative checkout
`/Users/jd/.codex/worktrees/scorebug-local-validation`. Followed the owner's
simulator-first/batched-testing direction. No hardware, subagents, purchases,
external broadcasts, push or PR. Original footage and unrelated simulators preserved.

## Live source interruption

Added `--lane source-interruption` to the ordinary runner and one native UI helper.
A 45-second prepared copy of the volleyball source reaches real file EOF during
publishing. Native UI observes capture interruption and publishing idle, recovers
and exports the interrupted archive, then starts a fresh recording and broadcast
and completes normal stop/export. No API/worker restart fixture in this lane.

Command, using Xcode26.2:

```sh
node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 \
  --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-source-interruption-20260928/input.mov \
  --lane source-interruption
```

`ordinary-native-C7yloY`: runner exit0, one native workflow passes, cleanup failures[];
owned simulator removed and app data retained. The runner correctly keeps
`mediaQualified:false`; separate analysis is in `native-media-verification/`:

- Interrupted archive: 1,320 consecutive source frames from0,44seconds;23 hashed segments.
  Source has1,350frames/45seconds, so one second of uncommitted tail is lost.
- New completed archive:882 consecutive source frames from0,29.4seconds;16 hashed segments.
- Two sessions per output, all H264/AAC, decode/probe without errors. Video gaps≤34ms.
- Final samples show HOME1–0 AWAY in both outputs and a clean archive sample.
- Measured A/V ends: interrupted archive−33.3ms, new archive−4ms;
  direct outputs24.7/44.3ms; proxy outputs19.2/28.6ms.
- Actual SQLite: four accepted start/stop commands with generations1,2,3,4;
  different recording IDs correctly marked interrupted/stopped.

Verifier adapted from retained server-recovery analysis to two archives/two output
sessions. Initial control-data inspection hit nullable `selection` on stop; corrected
the inspection before asserting generation order. No app mutation was needed.
28 focused runner checks pass. Native workflow and offline analysis processes joined.

## Actual Mac service

Added `test-macos-worker-service.mjs` and a worker factory hook in the existing local
lab. Default ordinary worker behavior stays the same. The service runner uses the
compiled production worker, existing private-env validation and generated launchd
plist, with a unique temporary label under its artifact directory. It performs
real API/relay/media/scoring/RTMP/mock-recorder/proxy-MP4 work, then boots out only
its own service and verifies observed child exit and descendant removal.
The service logs a small `macos_worker_exit` event with code/signal, no secrets.

```sh
pnpm --filter @scorebug/home-daemon build
node scripts/test-macos-worker-service.mjs --host 192.168.1.130 --duration 120 --encoder videotoolbox
```

Build passes. First attempt `device-lab-Iw8o04` rejected the lab's empty diagnostic
environment keys before launching a service; its lab cleanup passed. The adapter
now strips only explicitly disabled diagnostic keys and rejects enabled ones;
production service validation remains strict.

`device-lab-P7D4bv/macos-service-result.json`: exit0, actual launchd start and clean
worker exit(code0/signalnull), four owned processes gone and service booted out.
Both12.2second H264/AAC outputs fully decode, sampled score1–0 matches; A/V ends
within70.7ms direct and50.9ms proxy. Source time offsets explain longer audio
stream durations; do not compare durations alone. Lab cleanup failures[].
No persistent LaunchAgent installed. No live owned jobs remain.

Visible-score/end-offset checks ran against these saved MP4s and were then included
in the reusable runner; no second live run just for that consolidation.11 focused
service/options checks pass. Syntax/format/diff checks pass. Last bounded-publisher
cleanup hardening was inspected/syntax-checked, not fault-injected anew.
This short service result does not qualify login/reboot, sustained throughput,
physical capture, external networking or full-stream waveform synchronization.

## Faster future work

Added `docs/simulator-acceptance.md`: one consolidated incremental checkpoint and
platform matrix, with original artifact paths and limitations. It explicitly is
not a claim of a same-revision full regression. Updated README, architecture, local
runbook, service runbook and pure delivery plan; removed stale claims that native
Watch/media features are not implemented.

Added `.github/workflows/native.yml`, filtered to native/vendor/workflow changes:
Swift shared tests, native scoring-model checks and arm64 full phone/embedded-Watch
simulator build. Uses published macOS15 arm64/Xcode26.2 runner configuration.
YAML parses; GitHub execution remains unverified. Existing Linux CI is retained.
No full suite, new hardware attempt or congestion rerun performed.

## Next

Resolve the remaining congestion/healthy-period acceptance using existing captures
and a substantive implementation batch, not another series of tiny timing/GOP
experiments. Keep strict failed results. Audit remaining relay/generation TODOs
against retained real-relay checks before adding duplicate tests. Native CI awaits
an authorized push/hosted run; external and hardware qualification stay deferred.
