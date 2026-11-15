# File-source diagnostic integration

> Execute inline with test-first checks and independent review. The user has
> authorized autonomous progress through the existing delivery plan.

**Goal:** Keep real-file producer timing, sample counts and archive failure evidence
when the native app records or streams representative match footage.

**Design:** Reuse ArchivePressureDiagnostics for bounded video preparation and
callback spans. One source pump still owns both readers. A checked peek identifies
the next sample without advancing it; begin a video producer span immediately before
nextSample prepares that delivery (validation plus next-frame lookahead decode).
Finish generation before pacing sleep, and bracket only that video's callback.
A stop while pacing can leave a prepared-but-undelivered active span; retain it
truthfully. Audio preparation is measured in separate aggregate source-read metrics,
not mislabeled as part of a video callback. No new media queue, per-sample task,
format change, timestamp rewrite or health-policy input is introduced.

The file source retains bounded scalar statistics: delivered video/audio counts,
read count/total/maximum duration, maximum lag from the original wall/source anchor,
first/last video delivery times relative to the pump anchor, and a closed flag set
only after stop joins the pump. Never reset lag when the pacing phase shifts.
Encode integer counters as decimal strings. The recording-scoped JSON contains no
source path or raw error. File statistics and archive diagnostics are exported only
after joined capture stop; diagnostics I/O failure must not change archive outcome
or allow overlapping restart. Mac model tests inject writers; simulator DEBUG
builds write fixed filenames under the existing Application Support QA directory.

Reuse the existing archive producer attachment contract: only one diagnostics owner,
only before prepare. FilmModel attaches the same owner to either source kind, session
and native writer. Keep existing synthetic-source behavior and exports unchanged.

## Tasks

- [x] Add source tests for attachment restrictions, real decoded callback spans,
      unchanged sample identities, lag/read counters and closed-after-stop behavior.
      Use the existing tiny MOV generator. Verify red before implementing hooks.
- [x] Implement checked nonmutating reader peek, source hooks and bounded statistics.
      Preserve current decode-then-pace ordering and PCM splitting.
- [x] Add recording-scoped JSON encoding and FilmModel joined export tests: same
      recording ID, captured post-stop counts, thrown writer harmless, and restart
      blocked until an injected writer finishes. Review the optional-writer branch.
      The nil writer branch and a second real-file recording are code-reviewed;
      they are not separately exercised by the new joined-writer test.
- [x] Wire FilmModel attachment and DEBUG simulator export; add the observation flag
      to the dedicated file-recording UI case. Run focused/full model tests and build.
- [x] Run a fresh owned simulator case with the same 60-second staged real source.
      Preserve the previous recording media contract: exact consecutive frame IDs,
      full A/V decode, <=100-ms audio coverage, natural-audio correlation and visuals.
      Additionally require matching diagnostic recording IDs, full component coverage,
      successful closed archive state, zero archive queue loss/rejection and exact
      equality between delivered-source video count and exported frame count.
      Report source lag, read preparation costs and observed video delivery cadence separately;
      they do not establish viewer latency or production adaptation.
- [x] Review actual code and evidence, update the main plan and commit the checkpoint.

Files: FileFixtureCameraSource.swift and FileFixtureCameraSourceTests.swift;
FilmModel.swift; new FileFixtureDiagnostics.swift; ArchivePressureFixtureTests.swift;
NativeFileRecordingTests.swift. Existing directory-based Project.yml sources include
new files. The one-off staging/media runner remains a staging experiment; promote it
into maintained streaming tooling after these source boundaries are verified.

## Verified native checkpoint

`artifacts/qa/file-app-kjg87h0n/` passes the short iPhone 14/iOS 26.2 app case.
One UI test takes 35.015 seconds; UI and media wrappers exit zero and join. All
1,191 frozen source/input/runner hashes match. Staged bytes survive the XCTest
container change, and the owned simulator is deleted. No runtime restoration.

The export contains **221 consecutive video frames, IDs 0–220**, fully decoded at
1080p30. Audio is continuous, ending 8.000 ms before video (within 100 ms).
Natural-audio windows at source 1 and 4 seconds correlate at 0.999342/0.999668,
with zero sampled A/V lag/drift. Matching frame-90 images were visually inspected.

Both JSON exports identify the completed recording. Archive producer/session/
persistence coverage and timing validity are complete, with no failure, queue
rejection or loss. All 221 source video deliveries and 261 audio callbacks were
accepted; source video count exactly equals exported frame count. The source has
one prepared sample canceled during pacing, correctly excluded from delivered
counts. Its closed statistics report 483 nextSample attempts, 15.677 ms total and
0.217 ms maximum preparation cost, 2.293 ms maximum nominal source lag and 29.992 fps
average video delivery cadence. These read costs include audio slicing/lookahead
and exclude initial reader preparation; they are not raw decoder-call statistics.
Cadence is a source measurement, not viewer latency or adaptive qualification.

Source hooks and joined JSON export have preserved behavioral red/green evidence.
The focused set passes 24 tests. Read-only independent reviews find no actionable
issues in the source hooks or final export integration. The DEBUG simulator test
build passes. A follow-up full suite (`file-diagnostic-full-models-confirm`) passes
all 519 tests in 76.814 seconds, with no changes after the failed suite. The unsigned iPhone/embedded-Watch Release build also passes
(`file-diagnostic-release-device`, joined exit 0).

One first full-suite run (`file-diagnostic-full-models`) fails 1 of 519 tests:
`testMeasuredProviderBindsLaterRevisionAndV3CampaignWithoutReusingInitialRevision`
receives nil candidate admission. It executes before the file-source tests; all
new tests pass. The unchanged focused reproduction passes. The existing test uses
wall-clock scheduling against strict freshness/interval gates; that is a possible
source of sensitivity, but the exact rejected gate is unknown. Preserve the failed
run and do not call the timing issue fixed or relax admission thresholds.

Evidence: `post-run-assessment.json`, `diagnostic-assessment.json`,
`archive-diagnostics.json`, `file-source.json`, `archive-verified.json`,
`audio-correlation.json`, `visual-assessment.json`, `source-verification.json`,
`commands.json`, `cleanup.json` and `workflow.xcresult` inside the case directory.

Next: promote staging and natural-audio verification into the maintained streaming
harness, declare/verify any prepared fixture timestamp offset, and qualify real
footage through the measured adaptive path. Synthetic workload assumptions must
be replaced explicitly for this route without bypassing admission/health gates.

The maintained harness also assumes structured motion in its host options and native
UI gates, a 123.25-second fixture PTS origin in observation qualifiers, generated
audio markers, and a static source beneath the scoreboard crop. The explicit real
file route must resolve each assumption: preserve strict option validation, verify
prepared timestamp mapping, use source-aligned natural-audio correlation, and prove
the rendered score against a known score state. Background motion alone cannot
satisfy the old changed-pixel scoreboard assertion. Keep fixed-profile qualification
as the first maintained real-file streaming gate before measured adaptation.

Final evidence review confirms the current folder, status, export filename and both
JSON recording IDs agree. The one-off verifier checks one folder/export but does
not yet assert folder/status/export filename ownership. Add those explicit assertions
when promoting the runner, with a mismatched-export regression case; manual inspection
supports this checkpoint but is not a replacement for that maintained harness gate.
