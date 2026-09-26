# Native recovery and audio presentation timeline — September 25

## Scope and starting state

Continue the complete native recording/scoring/progressive-streaming vertical in `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`. Start at `fac0cc3`, after reviewed receiver conservation/interval helpers and the failed 2000/1000 ms comparison. This session is progress: fresh native evidence changes the diagnosis; the overall goal remains active.

The prior turn was interrupted. Original process27038 was no longer available; inspection found no live native runner and a retained wrapper exit record showing intentional diagnostic exit1. The completed artifact was analyzed, not rerun. The interrupted candidate implementer had written no files; a fresh agent resumed its bounded task.

## 3000 ms decoder / 1000 ms SRT experiment

Artifact: `artifacts/qa/native-app-uE9hUY`; source `fac0cc3`. Same prepared390-second volleyball input and `capacity750k-retry` restriction90s→restoration150s,270-second hold. Explicit `broadcast-reliability3000-v1`; independent report/stall/candidate freshness constraints unchanged. No production defaults changed.

- UI workflow1/0 in354.453seconds; diagnostic collectionerrors empty, coherent timing metadata. Wrapper `repeated-live-checkpoint-owned-diagnostic-reliability3000-peer1000-20260925-exit.json` confirms joinedexit1. Owned simulator shutdown/deletion completed.
- Native sequence240p→360p→240p→360p. Applications afterbootstrap28.016s,91.200s and193.185s.552original lifecycle events, two acknowledged and two failed attempts.
- Full decode/frame analysis78263 joined0. Archive9271sequentialframes0–9270; each live8827frames229–9055, zero missing/reordered IDs and~30fps. Archive continues215frames after the live outputs. All three A/V files fully decode.
- Timing/native/compressed/profile/capacity-clock leaf checks pass. Whole media leaf fails the existing cadence-report coverage gate. All353delivery rows are retained:351evaluated rows ontime;2null-result rows explicitly rejected for stale evidence. No late/missing/uncertain frames in the evaluated rows; no health credit assigned to rejected rows. These overlapping rows are not unique-frame counts.
- Original timing diagnostic assumed every row had a result and threw on the two legitimate rejected rows. Artifact-only `diagnose-owned-timing-profile-v2-20260925.mjs` keeps rejected rows/index/reason separately and excludes them from timing/frame credit; it does not change qualification code. Arrival upper median1810.1ms, maximum2242.6ms; source evaluation age median2312.3ms.
- `cadence-freshness-diagnosis.json`:2825/2826settled reports meet250ms budget (99.9646%). One312msrequest produced a322.5ms sample age and573.97ms gap between usable reports, exceeding the500ms gate. Preserve this failed result; do not relabel it based on decoded video continuity.
- Reviewed complete receiver interval replay passes8covered/4unbracketed intervals across10stages,8,255,268lower-bound bytes. It grants no candidate, policy or recovery authority.
- The mock recorder retained a `client-socket` failure at close and null summary recording path, although the actual MP4 exists and fully decodes. Recorder evidence reports terminationrequested andcode255. The worker encoder exits0. Exact socket-error cause/close ordering is not established; preserve the failed session summary.

## Audio gap versus synchronization

Original A/V helper41229 joinedexit1. Archive64waveformprobes pass. Both live outputs have one~21ms audio timestamp gap near145.169seconds and fail the original raw-PCM lag-spread check; score/phase checks in that helper are not reached.

The raw-PCM extraction concatenates decoded samples while losing gaps in their presentation timestamps. A missing audio packet therefore shifts all subsequent samples in that analysis buffer. This can resemble permanent A/V drift even when the file's timestamps retain alignment.

A separate diagnostic (`diagnose-audio-presentation-timeline-20260925.mjs`,49249 joined0) uses FFmpeg's documented timestamp matching to represent the gap with explicit silence in an analysis-only PCM file. Filter: `asetpts=PTS-STARTPTS,aresample=8000:async=1:min_hard_comp=0.005:first_pts=0`. [FFmpeg aresample documentation](https://ffmpeg.org/ffmpeg-filters.html#aresample-1); localFFmpeg8.1.2filter help was checked. Original MP4s, original PCM and failures are unchanged.

-69grid/phase-anchor waveform probes per live output pass in presentation time. Lag spread0.599ms direct and0.0078ms overlay; head/tail score glyphs0→1 independently pass both outputs.
- Direct analysis adds169samples at8kHz; the original~21ms gap remains explicit in `audio-presentation-diagnostic/results.json`. Silence cannot restore the lost audio. Diagnostic flags explicitly deny continuity/full qualification.
- The evidence supports stable post-gap alignment, not zero audio loss. Next work must distinguish packet loss/concealment and timeline-aware synchronization instead of weakening the original20ms check or claiming the stream is entirely qualified.

## Owned candidate measurement join

A separate implementation task joins each original owned attempt to raw candidate encoding/resource/A/V measurements and actual native/decoded baseline frames. Failed/short attempts remain represented. Original quality controls supply revision/configuration receipts because native phases do not independently carry those fields; the fixed capture-scope revision is not a baseline revision.

Implementation, tests and independent reviews are recorded below. Candidate admission witnesses, policy chronology and production real-camera integration remain separate work.

- Sampled the four native phases visually at sourceframes619,1957,4434,7510: volleyball content and overlay are visible; `owned-recording-diagnostic/four-phase-preview.png` retains the contact sheet. This is sampled inspection, not perceptual-quality qualification.
- `e34926f` implements the candidate join; implementer226focused tests and root37new tests pass. Root replay also passes both LvDNAy and uE9hUY (each4originalowners/2completedcandidates). Specification review verified byte-exact fixtures; retirement-index followup `39a3122` passed re-review. Quality review found that a measurement could claim to start after native startup completed. `ce91204` adds the missing upper bound and a regression covering both joined candidates, and names the narrow baseline flag `baselineFrameConsistencyQualified` while retaining `mediaQualified:false`. Implementer227focused tests and final quality38/38pass; quality re-review approved with no remaining findings. Both independent reviews are closed for this slice.


## Recorder shutdown investigation

The reconnecting recorder currently saves only `client-socket` or `upstream-socket`, discarding error code and socket event ordering. A client error destroys the upstream and eventually stops the child; this explains the observed termination request but does not identify why the client errored. Three comparison runs ended naturally with recorder exit0; uE9hUY ended255 after termination. Do not infer that a decodable MP4 proves clean shutdown.

Fresh baseline command: `FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg FFPROBE_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffprobe node scripts/test-reconnecting-rtmp-recorder.mjs --input artifacts/qa/prepared-native-owned-recovery-hHjv1n/input.mov`. Process98017 joinedexit0; artifact `reconnecting-rtmp-MgJTzt`. Two separate representative-footage publishers each produce90frames and134144audio samples, both fully decode and close naturally. Source hashes unchanged. This short test does not reproduce the long-run error.

Next bounded implementation adds sanitized socket lifecycle/error-code observations while preserving existing failure/cleanup behavior. No shutdown fix is justified yet. No physical test was restarted.


- `157c48f` adds bounded sanitized recorder lifecycle diagnostics:32events per session, explicit overflow, monotonic time, fixed labels, allowlisted networking errno, socket close hadError, and recorder finish/stop outcomes. Existing failure decisions, limits, byte accounting and cleanup remain intact. Implementer117focused tests pass; independent specification119related and quality18recorder tests pass. Both reviews approve. This is instrumentation only.
- Fresh artifact-only VideoToolbox/48kHzAAC/RTMP+MP4tee experiment `test-recorder-vt-tee-close-20260925.mjs` completed41978exit0 at157c48f; artifact `reconnecting-vt-tee-13aGVC`. Two12-second representative-footage sessions each retain360frames and577536audio samples at the mock destination; both independently saved tee MP4s also fully decode with360frames. Original source hashes unchanged.
- Both sessions record orderly client end→upstream finish/end→client finish→both close(hadErrorfalse)→recorder finish resolved;8events each, no overflow, no forced stops. Neither short baseline reproduces the long native failure. Results and all media remain in their distinct artifacts; this does not qualify full native adaptation.
- Next controlled run repeats the existing3000ms/1000ms native simulator scenario with the new diagnostics; no timing or failure thresholds change. This is one bounded attempt to capture the intermittent shutdown and audio-gap behavior, not a reason to retest all prior combinations.
