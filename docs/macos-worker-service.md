# Native macOS worker service

The worker can run in a terminal or as a per-user launchd agent while that user is
logged in. This packages the existing worker; it does not install the control
plane/relay, create matches, move active broadcasts, or qualify a new encoder.
Use an already configured control plane, worker identity and output identity.

## Prepare a release and private configuration

Use a dedicated checkout at a recorded Git revision, outside temporary worktrees.
Keep the previous built checkout for rollback. Install Node 22.13+ and the pinned
pnpm version, then build this checkout before starting the service:

```sh
pnpm install --frozen-lockfile
pnpm --filter @scorebug/protocol build
pnpm --filter @scorebug/home-daemon build
```

Use full FFmpeg with SRT, drawtext, H.264 and AAC. The system/default Homebrew
FFmpeg may lack these features. Run `pnpm run doctor -- --media-only` separately
to probe the intended backend; service installation does not perform media tests.
Software and VideoToolbox are available choices on this Mac. `nvenc` is accepted
by the worker configuration for other hosts, not a supported macOS GPU claim.

Create private directories (these commands do not start anything):

```sh
umask 077
mkdir -p "$HOME/Library/Application Support/ScorebugWorker" \
  "$HOME/Library/Logs/ScorebugWorker" "$HOME/Library/LaunchAgents"
chmod 700 "$HOME/Library/Application Support/ScorebugWorker" \
  "$HOME/Library/Logs/ScorebugWorker"
mkdir -p "$HOME/Library/Application Support/ScorebugWorker/state" \
  "$HOME/Library/Application Support/ScorebugWorker/recordings"
touch "$HOME/Library/Application Support/ScorebugWorker/worker.env"
chmod 600 "$HOME/Library/Application Support/ScorebugWorker/worker.env"
```

Edit `worker.env` locally. Do not paste tokens into commands, commit this file,
or include it in support logs. This is Node dotenv syntax, not a shell script:
use literal absolute paths, with quotes for spaces; `$HOME` is not expanded.
Replace the example identities, endpoint and secrets with this installation's
values. Avoid trailing spaces inside quotes.

```dotenv
CONTROL_PLANE_URL=https://control.example.invalid
HOME_TOKEN=replace-with-worker-authentication-token
WORKER_ID=mac-worker
OUTPUT_ID=main
ENCODER=videotoolbox
VIDEO_PROFILE=1080p30
FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg
FFPROBE_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffprobe
FONT_PATH="/System/Library/Fonts/Supplemental/Arial.ttf"
SCORE_DIR="/Users/YOUR_USER/Library/Application Support/ScorebugWorker/state"
OUTPUT_MODE=rtmp+record
OUTPUT_URL=rtmps://destination.example.invalid/live/replace-with-stream-key
OUTPUT_RECORDING_DIR="/Users/YOUR_USER/Library/Application Support/ScorebugWorker/recordings"
LOG_LEVEL=info
WORKER_REPORT_INTERVAL_MS=100
```

`OUTPUT_MODE=rtmp` requires `OUTPUT_URL`; `record` requires
`OUTPUT_RECORDING_DIR`; `rtmp+record` requires both. These are proxy outputs with
the score overlay. The phone's clean archive remains independent. Supported
profile names are `240p30`, `360p30`, `540p30`, `720p30`, `1080p30`, `2160p30`;
choose a profile already qualified on this host. Optional existing worker keys
are `DECODER_THREADING=automatic|slice` and `WORKER_PROCESSING=auto|off`.
Other keys, including diagnostic fixture switches and `NODE_OPTIONS`, are rejected.

## Check, run, install and stop

In the following commands substitute the actual checkout and Node paths. Use
the same options when uninstalling. `--label` defaults to `live.scorebug.worker`;
give independent instances distinct labels, identities, state and output paths.

```sh
WORKER_REPO=/absolute/path/to/scorebug-release
WORKER_NODE=/absolute/path/to/node
worker_service() {
  "$WORKER_NODE" "$WORKER_REPO/scripts/macos-worker-service.mjs" "$1" \
    --repo "$WORKER_REPO" --node "$WORKER_NODE" \
    --env "$HOME/Library/Application Support/ScorebugWorker/worker.env" \
    --logs "$HOME/Library/Logs/ScorebugWorker"
}
worker_service check
worker_service plist > /tmp/scorebug-worker-preview.plist
plutil -lint /tmp/scorebug-worker-preview.plist
```

`plist` is a dry-run: it validates argument shapes and prints only the plist.
It does not read secrets, require a build, write to LaunchAgents or start a worker.
`check` additionally validates the protected environment file, required settings,
executables, font, built entry point and writable state/output directories. Neither
command contacts a server. The environment file and its immediate parent must
belong to you, have no group/other permissions and not be symbolic links.
The logs directory has the same directory protection requirement.

For an explicit foreground run, use `worker_service run`; Ctrl-C forwards SIGINT
to the worker and waits for exit. This **does connect to the configured server**.
Do not run foreground and launchd instances with the same worker identity.

To install and start after the check succeeds:

```sh
worker_service install
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/live.scorebug.worker.plist"
launchctl print "gui/$(id -u)/live.scorebug.worker"
```

`install` writes an exclusive mode-0600 plist and refuses to overwrite an existing
file. It does not load/start the service. The plist contains only paths/arguments,
not the environment values. `bootstrap` starts the worker; launchd restarts exits
with a 30-second throttle and runs it on future logins. Stop using `bootout`, not
by killing the child, which launchd would restart:

```sh
launchctl bootout "gui/$(id -u)/live.scorebug.worker"
worker_service uninstall
```

`uninstall` refuses a loaded service or a plist that does not exactly match the
supplied options. It removes only that plist; configuration, logs, recordings and
the checkout remain. Check launchctl status before removing configuration.

## Logs, upgrade, rollback and backups

Launchd writes `worker.log` and `worker-error.log` under the supplied private logs
directory. Inspect locally with `tail -n 100`; do not publish configuration,
stream URLs or unreviewed logs. Logs are not automatically rotated: stop the service
with `bootout`, archive/rotate these files privately, then bootstrap again. Monitor
log/output disk use and retain or remove only your own completed recordings.

For upgrades, finish/stop the active broadcast first. Keep phone recording
independent. Boot out the service and wait for worker/encoder shutdown; uninstall
the old matching plist using its original checkout/options. Back up the protected
environment file, plist, completed output recordings and the old checkout revision
plus dependency lockfile. Keep secret-bearing backups encrypted/private. `SCORE_DIR`
contains regenerated overlay state, not the authoritative match database. Back up
the separate control-plane SQLite database using its SQLite-consistent backup
procedure; copying a live database file alone is insufficient.

Build the new pinned checkout before installing its new plist. Run `check`, install,
bootstrap, and confirm worker health/current-score output from the control plane.
If it fails, boot out and uninstall that exact new plist, restore the protected
configuration and install/bootstrap from the previous built checkout. Do not point
two running workers at the same identity or overwrite a running checkout. Changing
worker host/identity is a separate explicit broadcast move, not an installation
side effect. See [media qualification](media-soak.md) for output validation.

## Local service acceptance

A short actual launchd run now passes on the development Mac: compiled worker,
real API and authenticated SRT relay, score update, RTMP mock recorder and optional
proxy MP4. Both H264/AAC outputs decode and show HOME 1–0 AWAY; measured A/V ends
differ by 71 ms and 51 ms. The worker exits with code 0 and its service and descendants
are gone after `bootout`. This is not sustained performance or login/reboot testing.

Reproduce only when service behavior changes:

```sh
pnpm --filter @scorebug/protocol build
pnpm --filter @scorebug/home-daemon build
node scripts/test-macos-worker-service.mjs --host <this-Mac-LAN-IP> --duration 120 --encoder videotoolbox
```

The runner writes a private environment/plist under its own `artifacts/qa/device-lab-*`
directory, loads a unique temporary label, and boots out only that service. It does
not install a persistent LaunchAgent or change an existing service. The recording
association is a synthetic source fixture; phone archive behavior is covered by the
[native simulator checkpoint](simulator-acceptance.md). `macos-service-result.json`
records service cleanup and output checks. Service logs include the actual child
exit code/signal without configuration secrets.
