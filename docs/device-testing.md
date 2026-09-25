# Native phone and Watch testing

This route runs the real Scorebug apps against a Mac development server. The phone keeps its clean camera/audio archive; the proxy overlays the score and saves a second MP4 while sending RTMP to a local mock YouTube recorder. No external stream key is used. Start with a short smoke test before the sustained device gates in the [delivery plan](superpowers/plans/2026-09-13-portable-streaming-and-watch.md).

## Start the local stack

Use an installed Node/pnpm, Docker, FFmpeg with SRT/drawtext/H.264/AAC, and a font. From the repository root:

```sh
pnpm --filter @scorebug/protocol build
# Find the active LAN address; the phone must reach this interface.
ipconfig getifaddr en0
# Substitute that address. Default duration is 30 minutes; Ctrl-C stops early.
node scripts/device-lab.mjs --host 192.168.1.130 --duration 1800 --encoder software
```

Use `--encoder videotoolbox` for the Mac hardware encoder. `FFMPEG_PATH`, `FFPROBE_PATH` and `FONT_PATH` override local tool discovery. Only an explicitly selected private IPv4 address assigned to this machine is accepted. Management and the mock RTMP listener remain on loopback; scoring and encrypted SRT bind to the selected LAN address.

The command prints its unique artifact directory and `setup.json` path. That private file supplies the server URL, installation token, worker `mac`, output `local-sink`, and seeded HOME/AWAY match. Enter these in the native app. Tokens are generated per run; a fresh lab has a fresh database and requires its new setup. Stop recording/streaming before switching servers.

The lab stops after the requested duration or Ctrl-C, joins its worker, finishes the mock recorder, and removes its own relay container. It retains the database, logs, configuration and media. `shutdown.json` records cleanup results. The mock receiver accepts at most eight connections per lab run; restart the lab if that development limit is reached. A ready message establishes server startup only, not phone connectivity or media delivery.

## Install the native apps

Use Xcode 26.2 at `/Applications/Xcode-26.2.0.app/Contents/Developer` on this Mac. Select the owner's developer team for both Scorebug and ScorebugWatch, then build/run the Scorebug scheme on the attached phone. The Watch app is embedded; verify installation in the paired Watch's app list. Enable Developer Mode, trust the Mac and unlock the devices when required. Physical build compilation has passed; signing and device installation are separate checks.

## Short physical smoke

1. In **Score**, enter the server/token from `setup.json` and connect to the seeded match. Explicitly take over scoring.
2. In **Film → Setup**, enter the same server/token, worker `mac`, output `local-sink`, and connect. Start recording; allow camera, microphone and local-network permissions. Confirm elapsed time advances before starting streaming.
3. Start streaming and wait for both camera publishing and worker output status. Award a point in the native Score tab, then return to Film. Status alone does not prove the MP4; check it after stopping.
4. Open Scorebug on the paired Watch. In the phone's **Watch** tab, send its configured match and wait for the Watch confirmation. Explicitly take over on the Watch, score and undo while the phone keeps filming. Lower your wrist and reopen; record what actually survives and whether pending points reconcile.
5. Stop streaming and leave recording running for at least three seconds. Stop recording, open **Recordings**, and export the clean MP4. Stop the lab once the worker has finished.
6. Copy the phone export through Xcode's app-container tools or Files. Fully decode all three outputs, check gym audio and synchronization, confirm the archive has no overlay and the other two have the correct score changes. Preserve failures and exact hardware/OS details in the [session log](session-logs/README.md).

Artifact locations:

- Phone archive/export: Scorebug's Recordings library on the device.
- Proxy overlay: `<artifact>/proxy-recordings/attempt-*/overlay.mp4`.
- Mock YouTube: `<artifact>/reconnecting-recorder/session-*/sink-recordings/direct.mp4`.
- Receiver connection manifest: `<artifact>/reconnecting-recorder/manifest.json`.

Each retry produces a separate recording. Do not concatenate them and call it continuous delivery. Example full-decode check (substitute a recording path):

```sh
/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg -v error -xerror -i recording.mp4 -map 0:v:0 -map 0:a:0 -f null -
```

## Automated simulator vertical

This fixture uses an owned temporary simulator and synthetic timestamped camera/audio. It checks native recording, native point entry, SRT, live overlay, RTMP, all three MP4s, frame identities, audio and recording continuation after streaming stops. It cannot qualify the physical camera or paired Watch.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
SCOREBUG_IOS_RUNTIME=26.2 SCOREBUG_IOS_DEVICE_TYPE=iPhone-14 \
SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_PROXY_RECORDING=1 \
node scripts/test-native-app.mjs --streaming
```

Use an installed runtime; do not download deleted runtimes or delete unrelated simulators. Existing matched 1080p/4K volleyball fixtures remain available for longer content qualification after this smoke test.
