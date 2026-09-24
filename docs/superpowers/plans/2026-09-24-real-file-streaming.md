# Representative native streaming implementation plan

> Execute inline with `superpowers:executing-plans` and test-first checks. The user
> authorized autonomous progress; retain existing production and qualification gates.

**Goal:** Qualify real volleyball video and natural audio through native app recording,
SRT ingest, the local proxy and recorded RTMP output, then through measured adaptation.

**Architecture:** Extend the maintained native harness with an explicit local-file
route. Stage an independently validated prepared fixture into the owned simulator's
app container after building/installing. Retain synthetic routes and their acceptance
checks. Only the file route uses source-matched natural-audio qualification.

**Tech stack:** Existing Node test runner, ffmpeg/ffprobe, Swift DEBUG file capture,
XCTest, native SRT publisher and local relay/worker pipeline.

## Design decisions

Prefer prepared input staged in the app container: the preceding native experiment
already proves its lifecycle across XCTest's container replacement. Bundling private
media would couple app builds to large private assets; using a host path bypasses
app-owned staging. Do not upload inputs or modify originals.

The observation harness currently assumes a 123.25-second source PTS origin. A
prepared test copy may declare that offset; validate every video PTS against its
barcode and preserve it through capture. Do not silently retime captured media or
relax clock/age/identity checks. The source's real content/audio remains unchanged
apart from the existing documented SDR30 preparation and re-encoding steps.

First qualify the fixed-profile route. Reduced-profile/adaptive options currently
require structured synthetic motion in both host and app code; introduce explicit
file alternatives only after baseline evidence. Never set a synthetic motion flag
on a file source. Production still needs controller/provider integration afterward.

## Tasks

- [x] Add `scripts/natural-audio-qualification.mjs` and its Node tests. Accept 8-kHz
      decoded source/target PCM, source frame IDs and target video PTS, and both audio
      start times on the declared source-relative timeline. Select three separated
      one-second windows anchored to actual video identities, with a 150-ms search
      radius and 32 interpolation guard samples. Reuse `estimateAudioAlignment`.
      Require correlation >=0.98, an interior unambiguous peak, absolute A/V error
      <=100 ms and sampled drift <=20 ms. Include rounding offsets in the result.
      Fail missing support, nonfinite input, nonmonotonic IDs/times, short coverage,
      wrong/unrelated audio, silence, excessive lag and drift. Tests use independent
      deterministic signal generation and known shifts, including nonzero target PTS.
      Command: `node --test scripts/test/natural-audio-qualification.test.mjs`.
- [x] Add `scripts/native-file-recording.mjs` with recording ownership/closed-source
      validation and tests. Require exactly one completed status/folder/export,
      matching folder==status.id and export basename prefix status.id+'-', matching
      diagnostic IDs, finished archive, full coverage/validity, zero archive queue
      rejection/loss, video count==decoded export count, accepted audio callbacks and
      total samples consistent with the source. Retain a possible prepared-but-not-
      delivered sample on cancellation. Test mismatched/stale export substitution.
      Command: `node --test scripts/test/native-file-recording.test.mjs`.
- [x] Add an explicit file-input option and staging module used by
      `scripts/test-native-app.mjs`. Reject conflicting synthetic flags and unsupported
      quality experiments before side effects. Require a local regular input and
      enough duration for the declared workflow. Fully decode/probe it, validate
      H264/SDR/1920x1080/30fps and PCM16 mono48k audio plus all frame IDs/PTS, hash the staged
      input, and verify its hash after XCTest. Build/install before copying fixed
      QA/input.mov; then test-without-building. Re-resolve the container after testing.
- [x] Forward the exact file flag in `ios/AppUITests/NativeStreamingTests.swift` and
      project test environment. Preserve all existing synthetic behavior. Copy the
      closed file-source JSON with archive/observation artifacts even on failure.
- [x] Connect natural-audio and recording ownership validators to the file route.
      Keep full decode, all-frame archive identity, live source span/cadence/loss,
      continued clean recording after stream stop and source/worker age checks.
      Decoded AAC sample counts may include padding; don't equate them with input PCM.
- [x] Replace the file route's changed-pixel scoreboard assertion with evidence
      against known rendered score state. Moving court footage must not satisfy a
      score-change assertion. Verify the known score via the authoritative control
      state and independently rendered templates for the known 0-0 and 1-0 score
      states. Compare common text and discriminating digit pixels in decoded crops;
      do not count background changes. Keep failure evidence and
      matched frame images; do not label an unverified overlay as passed.
- [x] Run focused/full tooling tests, affected native tests/build, then a fresh frozen
      owned iPhone14/installed26.2 fixed-profile case. No concurrent heavy media jobs.
      Bound process lifetime, join all children and remove only owned simulator and
      services. Preserve every failed attempt with source hashes and diagnostics.
- [x] Independently review actual code/evidence and update the main plan for the
      verified fixed-profile checkpoint.
- [ ] Extend real input through measured candidate/adaptive options and real network
      impairment without bypassing admission/health gates.

The first two pure validators can be verified against the already retained native
case before the maintained runner integration. Passing them is not a streaming run.

## Validator checkpoint

Both maintained validators are implemented. Forty-eight focused Node tests pass,
with behavioral red/green evidence for the validators and the final-window support
regression. Tests include independently generated fractional PCM origins and drift
whose individual waveform matches remain strong, isolating the drift rejection.
Counter strings are length-bounded before BigInt parsing. An independent read-only
review finds no actionable issues; its fractional-origin coverage note is addressed.

The final source versions are exercised against retained native case
`file-app-kjg87h0n`, with fresh results in
`artifacts/qa/file-stream-validators-GDQPlB/`. Recording folder, completed status,
export filename and both diagnostic IDs agree; all 221 exported video frames match
the closed source count. Three natural-audio windows anchored at source frames
30/107/184 pass with correlations 0.999342/0.999704/0.998940. Maximum absolute
sampled offset is 0.000334 ms and drift spread is 0.000667 ms, explained by the
reported ffprobe/PCM rounding. This is sampled alignment, not a whole-audio fidelity
or viewer-latency measurement. All seven frozen validator/test/runner hashes match,
and both bounded decoder commands return zero and join. Original media is unchanged.

This qualifies the new validators against an existing app recording. The maintained
streaming runner has not used file input yet. Staging, declared source PTS mapping,
score-state image qualification and the new native streaming run remain open.

The full tooling suite passes all **3,531 tests** (`file-stream-validator-tools`,
joined exit 0, 17.876 seconds). Focused final tests (`file-stream-validators-final`)
pass all 48 in 13.693 seconds. Fresh retained-media validation
(`file-stream-validator-real-final`) exits zero and joins. Formatting and diff checks
pass. No Swift app/runtime behavior changes in this checkpoint, so the previous
native builds remain the relevant app evidence; no fresh native streaming claim.

## Fixed-profile staging integration

The file baseline requires an absolute `SCOREBUG_TEST_FILE_INPUT`, direct RTMP
recording, publication and worker-processing evidence; synthetic motion and other
quality experiment flags are rejected even when empty. The app-only capture flag
is derived by the runner. A prepared input must cover the requested hold plus a
90-second UI margin, keep exact 123.25+frameID/30 PTS, and pass full decode, SDR30
format, every-frame barcode/PTS and continuous PCM checks. Staging creates files
exclusively and checks SHA-256 before/after copy and after XCTest container replacement.

`artifacts/qa/prepared-native-file-degjWM/` contains a local 120-second stream-copy
excerpt from the previously normalized match source with explicit output timestamp
offset 123.25. All 3,600 frame identities and exact rational PTS pass; audio starts
at the same origin and ends 9.646 ms after video. Full decode and all five source
hashes pass. Prepared input SHA-256 is
`883e95872fee555c6bc5b244908b43ee88ed5c459a31b19969ceba06ea232767`.
The source adapter does not rewrite timestamps. Original private videos are untouched.

New score templates use the worker's declared font and geometry. The fixed baseline
requires at least 90% agreement on strong pixels distinguishing the two digit states
and at least 90% agreement on common glyphs; an alternative score must agree on no
more than 10% of distinguishing pixels. Tests reject bright/dark backgrounds, changed
background only, wrong score, missing text and damaged glyphs. This is specific
rendered-score evidence, not OCR or a general low-resolution quality threshold.

All 3,581 tooling tests pass before the first native attempt
(`native-file-integration-tools`, joined exit 0). Staging and score classification
have preserved behavioral red/green runs. The new UI path/build and complete native
pipeline remain unverified until the frozen run below.

## Verified native real-file streaming checkpoint

The maintained fixed-profile route now passes on an owned iPhone 14/iOS 26.2
simulator with local VideoToolbox processing, SRT ingest and recorded RTMP output.
`artifacts/qa/native-app-rHRTnp/` retains the full evidence; source freeze
`file-stream-freeze-pfiodpxy` covers 1,199 files, all unchanged through the run and
independent review. The native UI test passes in 82.523 seconds, and build/test,
media validation and the outer wrapper exit zero and join.

The clean archive contains **1,483 consecutive frames (0–1,482)** at 1080p30.
The saved stream contains **1,053 consecutive frames (223–1,275)** at about 30 fps,
with no lost identities inside that span. Recording continues for 207 frames
(6.9 seconds) after the last streamed frame. Full decode and every-frame audio
continuity checks pass. All recording/status/export/diagnostic identities agree;
archive queue rejection/loss is zero and the source is closed after joined stop.
Maximum nominal file-source delivery lag is 5.409 ms. This excludes initial file
preparation and does not measure camera performance or viewer latency.

Three original-audio comparisons per output pass with correlation above 0.9985.
Maximum sampled interior live A/V lag is **65.387 ms**, with a 0.667-ms spread;
archive sampled lag is effectively zero. Archive audio ends 26.667 ms before video,
and live audio ends 31.576 ms after video. These are sampled alignment results,
not whole-audio fidelity measurements. Input PCM and padded decoded AAC sample
counts are deliberately kept distinct.

Both decoded score states agree on all 264 discriminating template pixels and all
common glyph pixels. Independent inspection of source/archive/live frame 746 finds
matching action, clean archive video and the correct live score. The before/after
crops visibly show 0-0 then 1-0. The three preview barcodes independently decode to 746. See `visual-assessment.json` and `post-run-assessment.json` in the case folder.

**Startup remains unqualified:** the captured/encoded range begins at frame 163;
the direct recorder omits 60 acquisition frames (163–222). Live audio begins
1.069 seconds before the first decoded video, inside the existing 2.1-second GOP
acquisition allowance. The 65.387-ms interior measurement does not establish
100-ms startup coverage, instant startup or whole-pipeline losslessness. This is
a fixed 1080p local baseline, not automatic adaptation, real network impairment,
physical camera/thermal testing, remote installation or maximum sustainable quality.

The first attempt, `native-app-bgtSRd`, failed before native workflow startup because
the historical `scorebug/ingest:recovery-v1` image was absent. Its failure and frozen
hashes are preserved. The exact historical Docker context from revision `c16827c`
was restored and built separately; no current campaign image was retagged. The fresh
image reports `v1.21.0-scorebug-recovery-v1`; its ID and build provenance are retained
in `restore-recovery-image-mesj1snq` and the passing case. The build is not claimed
bit-identical to the former image.

Independent code review found two preflight gaps: PCM drift needed the native
reader's 2-microsecond bound, and three decoder/transport experiment flags needed
explicit rejection. Both have behavioral failing/passing regression evidence.
The final tooling suite passes **3,585 tests** (`native-file-integration-tools-final`,
joined exit 0); focused staging qualification passes 44 tests and score glyph
qualification passes 10. Independent final evidence review finds no actionable
issue and confirms the startup limitation above. No production Swift runtime
behavior changed. Owned simulator, relay container, API listener and artifact-scoped
processes are absent after the run. Existing runtimes were reused and originals
remain untouched.

Next introduce explicit supported file-source alternatives for reduced-profile and
measured candidate admission, with correctly rendered lower-resolution score
checks. Preserve strict rejection of mixed/unsupported experiments. Then qualify
adaptive phases and network impairment on representative footage before production
controller/provider integration. Physical phone/Watch and other hosts remain later
gates in the main plan.
