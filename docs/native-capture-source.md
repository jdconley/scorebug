# Native capture source and recording ownership

`ScorebugMedia.CaptureRecording` connects an injectable source to the existing
bounded `RecordingSession`. It owns both for one recording, without a match,
server, scoring credential, or publisher. It creates no additional sample queue
and no task per captured sample.

The source prepares with retained sample/failure callbacks and returns a shared
source-clock origin. The recorder starts its archive at that origin before enabling
source delivery. On normal stop, the source detaches and quiesces its callbacks
before the recorder drains accepted samples and finalizes the archive. Concurrent
stop callers join the same operation. Cancelling a waiter does not abandon capture;
explicit cancellation or owner release fails the recording and schedules teardown.
Stopping during startup cancels that incomplete recording.

Source drops, interruptions, startup failures, teardown failures, and archive queue
overflow remain failures. They cannot be overwritten by a successful finish.
Committed segments remain available for the existing recovery/export path. A source
must report teardown errors before quiescing its callbacks. The orchestration cannot
impose a hard deadline on an arbitrary source implementation's blocking system call.

## iPhone adapter

`IOSCameraCaptureSource` creates no permission prompt or hardware activity in its
initializer. Explicit preparation requests camera and microphone access, configures
rear-camera 1920 × 1080 SDR NV12 capture at 30 fps, and activates microphone capture.
This fixed profile is the initial recording baseline; adaptive live quality remains
separate work. Missing devices, incompatible formats, and rejected inputs/outputs
fail preparation.

Session configuration, start, and stop run on a dedicated control queue. A retained
delegate receives audio/video on one serial sample queue and forwards them directly
to the bounded recorder. The source warms capture with sample delivery disabled,
then reads the session's `synchronizationClock` for the recording origin. Apple
specifies that both output tracks use this clock's timebase; pre-origin warmup
samples are excluded. See [Apple's clock contract](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock).

Capture drops, runtime errors, session/audio interruptions, and audio route changes
are reported explicitly. Late-video discard keeps the capture callback queue from
accumulating frames; its drop callback fails the recording's completeness claim.
See [Apple's frame-drop guidance](https://developer.apple.com/library/archive/technotes/tn2445/_index.html).
Stopping disables sample delivery, detaches observers/delegates, stops the session,
joins the sample queue, deactivates audio, and releases callbacks. Preview attachment
has an explicit session property and needs no reflection.

## Validation and next integration

Eleven deterministic lifecycle tests cover startup ordering, explicit origin,
callback quiescence before archive finish, partial preparation, capture failures,
stop/cancel races, concurrent stop waiters, owner release, overflow, and teardown
failure. The complete shared media suite passes 71 tests (60 XCTest plus 11 Swift
Testing tests).

The [dual-output fixture](native-dual-output.md) now feeds samples through this same
capture-source contract and `CaptureRecording` owner, with real encoding and local
SRT. The iPhone source is compile/link checked on ARM64 Simulator and generic iPhone;
these destinations do not exercise physical camera hardware.

The five-case run `artifacts/qa/dual-output-XbyEt5/results.json` passed through the
new capture owner. Every archive retained all 420 frames and complete audio; both
normal streams retained source frames 0–419. Peak RSS stayed below 95 MiB. Logs are
retained in `capture-source-dual-output-fresh.log`, `capture-source-media-tests.log`,
`capture-source-ios-device-build.log`, and `capture-source-ios-simulator-final-build.log`
under `artifacts/qa`. The first fixture build used a stale SwiftPM source list and
failed to discover the new shared files; cleaning the probe's own build cache
resolved discovery before this fresh successful run.

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
swift test --package-path ios/Packages/ScorebugMedia
pnpm test:dual-output
```

The [native app](native-film-app.md) now adopts this adapter and exposes Film, Score,
and Recordings with recovery, playback, and export. Its Simulator workflow uses an
injected timed video/audio source. Device permissions, camera/audio interruptions,
storage pressure, sustained recording, and thermal behavior must then be tested on
an actual phone. This slice does not enable production publishing or Watch scoring.
