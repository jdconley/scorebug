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
- [ ] Add an explicit file-input option and staging module used by
      `scripts/test-native-app.mjs`. Reject conflicting synthetic flags and unsupported
      quality experiments before side effects. Require a local regular input and
      enough duration for the declared workflow. Fully decode/probe it, validate
      H264/SDR/1920x1080/30fps and mono48k audio plus all frame IDs/PTS, hash the staged
      input, and verify its hash after XCTest. Build/install before copying fixed
      QA/input.mov; then test-without-building. Re-resolve the container after testing.
- [ ] Forward the exact file flag in `ios/AppUITests/NativeStreamingTests.swift` and
      project test environment. Preserve all existing synthetic behavior. Copy the
      closed file-source JSON with archive/observation artifacts even on failure.
- [ ] Connect natural-audio and recording ownership validators to the file route.
      Keep full decode, all-frame archive identity, live source span/cadence/loss,
      continued clean recording after stream stop and source/worker age checks.
      Decoded AAC sample counts may include padding; don't equate them with input PCM.
- [ ] Replace the file route's changed-pixel scoreboard assertion with evidence
      against known rendered score state. Moving court footage must not satisfy a
      score-change assertion. Verify the known score via the authoritative control
      state and independent source-aligned score crops. Keep failure evidence and
      matched frame images; do not label an unverified overlay as passed.
- [ ] Run focused/full tooling tests, affected native tests/build, then a fresh frozen
      owned iPhone14/installed26.2 fixed-profile case. No concurrent heavy media jobs.
      Bound process lifetime, join all children and remove only owned simulator and
      services. Preserve every failed attempt with source hashes and diagnostics.
- [ ] Independently review actual code/evidence, update main plan and commit verified
      work. Then extend real input through measured candidate/adaptive options and
      real network impairment without bypassing admission/health gates.

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
