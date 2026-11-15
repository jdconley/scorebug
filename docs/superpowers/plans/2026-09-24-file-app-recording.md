# Local-file app recording checkpoint

> Execute inline with `superpowers:executing-plans` and test-first verification.
> The user's autonomous-work instruction authorizes routine design decisions.

**Goal:** Run representative local match video through the native app's FilmModel,
archive, export and playback workflow in an owned simulator.

**Design:** Add a DEBUG-only simulator source factory. Without an opt-in it retains
the existing synthetic source and flags. Exact `SCOREBUG_TEST_FILE_CAPTURE=1`
selects `Library/Application Support/Scorebug/QA/input.mov` in the app container.
Empty/malformed opt-in or simultaneous synthetic motion/failure controls throw a
constant configuration error. Missing/bad media fails source preparation; never
fall back to synthetic content. Release/physical App.swift keeps the camera source.
A throwing FilmModel source factory runs only after library setup and its
cancellation check, preserving the existing no-source-on-cancel invariant. If
configuration throws, explicitly cancel the unused sink and retain the failed
recording status. Existing source closures convert to the throwing type without changes.

Use container staging after an explicit app install, then run XCTest without
rebuilding. This keeps private video out of the application bundle and source
control. Losing the staged input when XCTest replaces a container must fail the recording
test. Confirm the
same input hash survives test installation/relaunch. Passing an arbitrary host
path or bundling the movie would avoid staging, but neither verifies the intended
app-owned input lifecycle.

This checkpoint tests recording only. It does not claim adaptive or network
qualification. Existing marker-tone verification cannot qualify natural audio;
use the tested waveform estimator and actual source frame IDs for offline checks.
Producer diagnostics and streaming harness integration remain the next checkpoint.

## Changes and checks

- [x] Add `SimulatorCaptureSource` tests in FilmModelTests: absent flag yields the
      existing source; exact opt-in yields the file source; malformed and conflicting
      options throw. A missing file must fail preparation with no sample callbacks.
- [x] Make FilmModel's source factory throwing, preserve post-library cancellation
      ordering, and cancel an unused sink on failure; test visible failure, exactly
      one cancellation, no source after cancellation and successful subsequent retry.
- [x] Add the factory and wire only the DEBUG simulator branch of App.swift.
- [x] Add `NativeFileRecordingTests` with a dedicated method that opts into the file
      source, records at least six seconds, stops, exports, plays and relaunches.
      It must assert a completed recording; EOF or invalid setup must fail.
- [x] Run focused red/green and full model tests, plus simulator build-for-testing.
- [x] Stage a private 60-second stream-copy excerpt of the already normalized 1080p
      match source (frame IDs start at zero) in one owned iPhone 14 simulator using
      an installed runtime. No input upload, original modification or runtime install.
- [x] Run only the file recording UI method, with a 300-second outer deadline and
      automatic Xcode diagnostics disabled. Preserve logs/results and failed data.
- [x] Verify one completed archive/export: all video IDs exactly 0 through N−1,
      N >= 180, full A/V decode, video gaps <=35ms, continuous 48-kHz mono audio,
      startup/tail audio coverage within 100 ms. Compare natural audio at source 1 s and
      4s (one-second windows): correlation>=0.98, interior/unambiguous peak, absolute
      A/V lag<=100ms, spread<=20ms. Keep matched source/export frame90 images.
- [x] Verify staged input/source hashes and joined process exit; shut down/delete
      only the owned simulator. Update main plan with exact evidence and limitations.

For unit checks use the existing joined wrapper and scoped Xcode 26.2:
`xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests
-destination 'platform=macOS,arch=arm64' -derivedDataPath ios/DerivedData/FileCapture
-collect-test-diagnostics never test`. Use unique evidence names and retain failures.

The actual UI run freezes tracked sources, test code and the staged input before
launch. Do not edit them until the joined run and source hash assessment finish.
EOF and runtime-reader fault injection remain bounded source-adapter follow-ups;
this checkpoint must stop well before the 60-second source ends.

## Design correction during verification

The first full suite (`file-app-full-models`, joined exit 65) caught a regression
in the initial pre-library source construction: cancellation while archive setup
was pending created a source that the existing contract requires not to create.
The revised order retains that invariant and cancels the unused sink if factory
construction throws. The failed run remains preserved. Review also tightened the
UI test to a fresh library, exactly one completed recording with no failed row,
and the same export identity after relaunch.

The corrected full model suite passes all 516 tests (`file-app-full-models-fixed`,
joined exit 0), including the existing cancellation test and new explicit unused-sink
cancellation/retry test. Independent read-only review of the actual updated files
finds no further actionable issues. The source-selection behavior has a preserved
red/green pair; the initial throwing-factory red fails compilation on the missing
throwing signature, and the refined cleanup/cancellation red fails behaviorally.

## First native run: UI passes, media acceptance fails

`file-app-m8gl78j9` passes its one UI method in 33.929 s; wrapper exits 0 and joins.
All 1,189 frozen hashes match, staged bytes survive XCTest's container-ID change,
and the owned simulator is deleted. The independent media check remains failed:
248 consecutive video frames end at 8.266667 s, but audio extends to 8.425333 s, a
158.667 ms tail beyond the unchanged 100 ms limit. Source 60 s media passes validation.

A direct AVAssetReader diagnostic confirms decoded PCM buffers as large as 8,192
samples (170.667 ms). Pacing a whole buffer at its starting timestamp sends future
audio too far ahead of video. The correction splits decoded interleaved PCM into
at most 1,600 samples (one 30-fps period) before pacing, preserving every sample value
and timestamp. New regression assertions reproduce the 8,192-sample excess and
stop-boundary lead; they also compare all 19,200 synthetic PCM values and contiguous
audio timestamps. No archive/stream policy or media acceptance budget is relaxed.

All ten extended source tests pass after the PCM split (`file-app-pcm-pacing-fixed`,
joined exit 0, 8.916 s). The first green attempt had a Swift argument-label compile
error, preserved separately; no behavioral acceptance was changed. Independent
review confirms bounded remainder ownership, sample/count continuity and joined
stop behavior. A new full suite and fresh native run follow; the first native case
is not qualified by these unit results.

The PCM correction passes all 516 model tests in 74.442 s (`file-app-pcm-full-models`,
joined exit 0). The initial simulator test build passed; the fixed source is rebuilt
before a separately owned native run. The native harness is currently the retained
one-off `artifacts/qa/file-app-run.py` staging experiment; its offline verifier is
`artifacts/qa/file-app-media.mjs`, using the existing tested continuity and fractional
waveform estimators. Promote the verified staging lifecycle into the maintained
streaming harness when connecting the representative adaptive route.

## Fixed native case passes

`artifacts/qa/file-app-s08q8lyb/` passes the declared short recording case. The
one native UI method takes 33.748 seconds. The UI wrapper and independent media
wrapper both exit zero and are joined. The same staged input hash as the failed
case survives installation/relaunch, although XCTest changes the container directory
identifier; runners must resolve the container again after XCTest. All 1,189 frozen
source/input/runner hashes match and the owned simulator is absent.

The completed export fully decodes with **251 consecutive frames, IDs 0–250**,
8.366666 seconds of video and maximum frame gap 33.334 ms. Every decoded audio
frame passes continuity checks; audio ends **16.000 ms** after video, below the
unchanged 100-ms allowance. Natural-audio windows at source 1 and 4 seconds have
correlation 0.999342 and 0.999668, with zero measured A/V offset and zero sampled
drift. Decoded PCM duration exceeds video by 16.084 ms. Independently verified
frame-90 PNGs show matching serve action and a clean archive without an added score
overlay; the prepared input's test identity strip remains in both.

Evidence: `post-run-assessment.json`, `archive-verified.json`,
`audio-correlation.json`, `visual-assessment.json`, `source-verification.json`,
`staging-after.json`, `commands.json`, `cleanup.json` and `workflow.xcresult` within
that directory. The first UI-passing/media-failing case remains failed, with its
`failure-assessment.json` preserved. This is sampled content plus all-frame/media
continuity evidence, not camera, thermal, long app recording, viewer latency or
adaptive streaming qualification.

Final code verification: all 516 model tests pass after the PCM fix; the rebuilt
DEBUG app/UI target and the unsigned iPhone/embedded-Watch Release build pass.
Independent review approves the source selection, lifecycle correction, UI identity
checks and PCM slicing. No runtime was downloaded, device OS changed or private
video uploaded. Next add truthful file-source pressure/lag diagnostics and promote
container staging/natural-audio verification into the maintained streaming harness,
then run representative measured adaptation and real network impairment.
