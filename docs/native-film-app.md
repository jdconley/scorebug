# Native Film, Score, and Recordings app

`ios/Project.yml` builds the native **Scorebug** app. Its Film and Recordings views
use the shared capture owner and segmented archive; its Score tab reuses the native
scorer from the independently tested scoring harness. The obsolete camera scaffold,
raw-buffer passthrough writer, old API client, and settings views were removed.
There is no browser scorer or unimplemented LIVE indicator in this app.

## Recording and recovery

Film creates no source or permission request until Record. Recording needs no match,
network connection, server setup, or streaming key. It owns its capture source across
tab changes, so native scoring on the same phone does not end recording. The current
archive profile is 1080p/30 SDR H.264 with 48 kHz mono AAC. Device capture uses the
rear camera in landscape; Debug Simulator builds clearly label their generated
video/audio source. The independent live publisher is now connected through native
[streaming controls](native-streaming-controls.md); adaptive quality remains pending.

The recording model joins source quiescence and archive finalization before marking
a recording complete. Failures remain visible and retain committed media for recovery.
Leaving the app requests stop; this does not promise background camera operation.
An idle-timer override prevents automatic screen sleep during recording.

Recordings live under Application Support/Scorebug/Recordings in the app container.
Each recording gets an exclusive UUID directory, segment files, and an atomically
replaced completion-status file. Missing/unconfirmed status is recoverable when valid
media exists. Missing or corrupt media remains visible as unavailable. A failed
status commit cannot silently become a completed recording. Original files are never
deleted by recovery or export.

Recovery hashing and export run off the UI thread. Writer health reads also run off
the UI thread because a writer snapshot can wait on a segment's disk commit. At most
one such read is outstanding; identity checks discard stale results after another
recording starts. Library scans do not run during capture, and Record waits for an
already-started scan; users see a checking indicator while scanning.

Export checks the complete MP4 before presenting it. Playback switches the audio
session into playback mode; the player and its time observer are torn down on dismiss.
Sharing is an explicit user action. Export is disabled during recording to protect
recording I/O; the original segments remain available on every export outcome.

## Repeatable validation

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
pnpm test:native-app
SCOREBUG_IOS_RUNTIME=18.5 pnpm test:native-app
SCOREBUG_IOS_RUNTIME=26.2 SCOREBUG_IOS_DEVICE_TYPE=iPhone-15 pnpm test:native-app
```

The runner owns a dedicated Simulator and local scoring API. It tests permission-free
Score entry, offline recording, an actual scored point while recording continues,
explicit stop, relaunch, forced-termination recovery, MP4 export, and an advancing
playback clock. Exported recordings and screenshots are retained in its artifact
directory before the owned Simulator is deleted. Xcode sometimes shuts down its
Simulator after testing, so the runner boots the same device to retrieve its data.

The Simulator source uses one timed pump, immutable NV12/PCM buffers, and a nonzero
clock origin through the same CaptureRecording path as the phone. The exported
frame barcodes must run sequentially from frame zero with no missing/duplicate frames.
Both tracks must fully decode and satisfy the unchanged 100 ms coverage budget.
These short workflow checks do not establish physical-camera timing or sustained load.

## Current evidence

The original recording model/library suite passed 14 tests, including real fixture encoding
and export, interruption/relaunch classification, metadata durability failures,
nonzero source clocks, slow-metrics responsiveness, stale-result rejection, and
scan/start exclusion. The integrated recording and streaming model suite now passes
37 tests, with separate spec and quality reviews. See the current
[native streaming qualification](native-streaming-qualification.md) for its media gate.

The three native app workflow tests pass on iPhone 14 Simulators with iOS 17.5 and
18.5 and an iPhone 15 Simulator with iOS 26.2. Each run exports completed and
interrupted recordings, fully decodes them, and verifies every source frame in
order. Recovery in these short runs retained six seconds of media after termination
once the UI showed at least seven recorded seconds. This is separate from the
more precisely bounded crash-tail measurements in the native archive harness.

The reviewed iOS 17.5 run is `artifacts/qa/native-app-Unk2Iz`, the iOS 18.5 run is
`artifacts/qa/native-app-iJQie8`, and the iOS 26.2 run is `artifacts/qa/native-app-oO5o0y`. Both exported tracks in those runs have at most
28.1 ms of end-coverage difference (AAC padding/fragment boundaries), within the
100 ms gate. Screenshots confirm the Film, Recordings, scoring, and player views.
Unsigned iPhone Release builds pass for both Scorebug and the separate scoring app.
The fixture source is excluded from Release compilation. Logs are retained under
`artifacts/qa/native-app-*.log` and the individual artifact directories.

After streaming integration, the final iOS 17.5 offline regression
(`artifacts/qa/native-app-Qn5rxG`) again passes all three workflows and fully decodes
both completed/recovered exports, with maximum end-coverage difference 28.1 ms.
The 37-model-test rerun and unsigned Scorebug iPhone Release build also pass; see
`native-streaming-film-model-final.log` and `native-streaming-release-iphone.log`.

Xcode currently discovers a connected iPhone 16 Pro and a known, disconnected
Apple Watch Ultra 2. That inventory establishes availability only; this work has
not installed or exercised the new camera app on either device.

## Remaining work

Physical-phone permission flow, camera preview/orientation, audio-route negotiation,
interruptions, storage pressure, thermal behavior, and sustained simultaneous encoding
remain unqualified. Capture-role registration, independent publisher coordination,
and bounded SDK transport queues are integrated. Streaming finalization passes on
iOS 17.5, 18.5, and 26.2. Automatic reconnection and adaptive quality remain planned.
Native Watch scoring and its paired/Wi-Fi/cellular routes remain planned. Shared scoring,
portable local workers, SDK probes, and their existing gates remain in place.
