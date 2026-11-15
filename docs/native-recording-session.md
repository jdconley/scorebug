# Shared recording session

`ScorebugMedia.RecordingSession` provides one recording lifecycle for native
capture sources. It has no match, control-plane, or publishing dependency.

The source creates an immutable `CapturedMediaSample` for each ready audio/video
buffer and offers it synchronously. The wrapper retains the underlying media;
producers and consumers must not mutate or invalidate those buffers afterward.
Queued payloads are limited to 24 items and 24 MiB by default. One sample can also
be in flight, and encoder allocations and shared parent buffers are outside this
payload estimate. These limits are not a whole-process memory guarantee.

One consumer owns archive startup, appends, and finalization through the
`RecordingArchiveSink` interface. `SegmentedArchiveSink` connects it to the actual
segmented writer. Temporary backpressure retries the same sample in order for up
to two seconds; overflow or a permanent failure closes admission and latches an
error. Capture adapters must also report dropped samples or interruptions.

Both tracks use an explicit source timestamp origin. Startup completes before the
source begins offering samples. Stopping closes admission, drains accepted media,
and returns the recovered archive only after successful finalization. Concurrent
stop calls join that same operation. A session is used for one recording.

Cancelling a task that is waiting for start or stop does not abandon the recording.
Explicit session cancellation fails it and discards queued samples while retaining
committed archive segments. The owner must remain alive through finalization;
releasing it initiates cancellation so an idle consumer cannot retain the session
indefinitely. Capture failure and overflow initiate teardown without invoking the
writer on the capture callback's thread.

The dual-output fixture uses this same recording session in offline, healthy SRT,
stalled-receiver, and unavailable-receiver scenarios. See the
[real media checks](native-dual-output.md). Deterministic session tests cover
backpressure, queue bounds, concurrent stop, startup/failure races, and cancellation.

The shared media package passes 71 tests, including 18 recording-session regressions,
11 capture-owner lifecycle tests, and native NV12/PCM encoding. Repeated SRT validation also uncovered an upstream
startup audio-loss defect; it does not affect the clean archive. The streaming
fixture correctly rejected runs that exceeded its coverage budget. The
[local SDK correction](sdk-startup-patch.md) now passes all five real-media cases,
including recording with a nonzero source clock.

The [capture owner and iPhone source](native-capture-source.md) now connect this
session to an injectable source, with explicit camera startup, callback quiescence,
and capture/audio interruption reporting. The [native app](native-film-app.md) now
adopts the adapter and presents recordings, recovery, playback, and export. Physical
device performance and interruption behavior remain in milestone 3.
