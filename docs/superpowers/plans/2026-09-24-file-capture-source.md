# File capture source implementation plan

> Execute inline with `superpowers:executing-plans` and test-first verification.
> The user's autonomous-work instruction covers this bounded implementation.

**Goal:** Feed real local match footage into the native app's existing capture
contract, enabling the subsequent representative adaptive-stream test.

**Architecture:** A DEBUG-only `FileFixtureCameraSource` implements `CaptureSource`.
A single detached task owns sequential decoding and real-time delivery. Separate
video/audio readers use each track’s actual nonempty media range, preventing
AVAssetReader from synthesizing content for leading empty edits. The pump retains
at most the next video/audio samples plus the current delivery.
Prepare/start/stop remain serialized by `CaptureRecording`, as required by the
existing protocol. Stop cancels and joins the pump before cancelling both readers.
No callback survives stop. The task captures the reader and callbacks, not its source
owner. Unused/failed preparation can be stopped safely; each instance is one-use.

**Tech stack:** AVAssetReader, CoreMedia, Swift concurrency, XCTest, existing native
recording/export code. No new package or process is needed inside the app.

The adapter accepts a local regular file with exactly one H.264 SDR video track
matching the supplied 30-fps profile and one 48-kHz mono audio track. It decodes to
NV12 video and signed packed 16-bit PCM. Check actual decoded formats and per-track
timelines; reject malformed, missing or unsupported inputs without synthetic fallback.
Return the earliest numeric source timestamp as the recording origin and preserve
sample timestamps. Reject nonnumeric, reversed or discontinuous source timelines.
Pace against a monotonic clock, preserving every sample without catch-up bursts;
expose counts and maximum nominal source lag separately from adjusted scheduling.
Reader failure reports `.failed`; finite EOF reports `.interrupted`. The eventual
harness stops before EOF. Normal requested stop reports neither.

This checkpoint implements and tests the adapter before selecting it in App.swift.
That keeps staging, archive-pressure instrumentation and natural-audio verification
in the next integration checkpoint. Those remain necessary: a standalone adapter
pass does not qualify the adaptive app route or enable production upgrades.

Files:

- Create `ios/Sources/Scorebug/Capture/FileFixtureCameraSource.swift`.
- Create `ios/FilmModelTests/FileFixtureCameraSourceTests.swift`.
- Existing `ios/Project.yml` directory source lists already include both files.

Tasks:

- [x] Add failing tests using small locally generated H.264/PCM MOVs: no callbacks
      before start, exact video/audio counts and PTS order, nonzero origin, unsupported
      profile/missing track/corrupt file rejection, EOF interruption, one-use lifecycle,
      stop during pacing, callback quiescence, and delayed-callback pacing.
- [x] Implement the reader and source; run focused tests red then green. Use real
      decoded media for lifecycle tests and direct cadence tests for deterministic time
      arithmetic. Keep blocking file/decode work off MainActor.
- [x] Exercise the adapter through `CaptureRecording` and the native archive,
      stopping before EOF, and inspect actual recovered/exported counts.
- [x] Run the full FilmModel suite and simulator build; review source lifecycle,
      bounded ownership, validation, error and cancellation paths. Fix findings.
- [x] Update the main plan with exact evidence and leave app selection/staging,
      representative audio verification, adaptive network and production gates open.

Validation command pattern (scoped Xcode 26.2):

```sh
xcodegen generate --spec ios/Project.yml
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ios/DerivedData/FileCapture \
  -collect-test-diagnostics never \
  -only-testing:ScorebugFilmModelTests/FileFixtureCameraSourceTests test
```

Use the existing joined-process wrapper for each run and preserve red/failing logs.
Real private movies remain outside source control, untouched and local. Synthetic
unit movies are temporary and deleted by their owning tests.

## Adapter checkpoint evidence

The focused source suite passes all ten tests in 8.938 seconds, with joined exit
zero (`artifacts/qa/repeated-live-checkpoint-file-source-realtime-fixture*`). The
native archive integration exports exactly the delivered video frame count with
zero archive queue drops/rejections. Other cases exercise independent track origins,
nonzero common origin, EOF, bad input, cancellation and callback quiescence; a
clock-only test checks cadence adjustment and the separately retained nominal lag.

Preserved red/diagnostic runs establish three corrections: valid decoded H.264
buffers can have an unspecified duration, so actual consecutive PTS plus declared
frame rate establish cadence; leading empty edits require per-track reader ranges;
and the real-time synthetic MOV generator requires real-time writer inputs to avoid
blocking video readiness during the longer fixture. No acceptance deadline or
sample-count expectation was relaxed. A review finding removed an unnecessary
cross-track 1-ms origin restriction and added independently offset track coverage.
The final independent source review found no additional concrete issue.

Boundaries: reader-failure-after-prepare and internal-edit rejection are implemented
but do not yet have deterministic fault-injection integration cases. EOF requires
both readers to report completed; it does not separately compare decoded totals
with track metadata. These are follow-up coverage items, not claims of exercised
failures. This source has not yet read the private normalized footage inside the
app, and is not yet selectable by App.swift.

The first full FilmModel run (`file-source-full-models`, joined exit 65) executed
512 tests with one failure: the existing later-revision candidate-admission test
returned nil. That test ran before the new source suite, which passed all ten
cases again. A focused diagnostic of the unchanged failing test passed in 4.653
seconds (`file-source-existing-admission-diagnostic`, joined exit zero). The exact
cause of the first rejection is not established; its failure log is preserved,
and neither production thresholds nor that test was changed.

The unchanged full-suite follow-up passes all 512 tests in 74.660 seconds
(`file-source-full-models-followup`, joined exit zero). This includes the earlier
failing admission case and all ten file-source tests; the first failure remains
preserved rather than being relabeled a pass.

The arm64 DEBUG simulator app build passes on scoped Xcode 26.2 using a generic
destination (`file-source-simulator`, joined exit zero); no simulator was created
and no runtime was downloaded for this checkpoint. Existing concurrency warnings
in CaptureStreamingModel and the AppIntents metadata notice remain visible in the
build log. App source selection and production adaptation remain unchanged.
