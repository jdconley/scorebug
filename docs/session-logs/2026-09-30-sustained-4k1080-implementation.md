# September 30: sustained 4K/1080p remediation implementation

## Scope and checkout

Executing the [focused plan](../superpowers/plans/2026-09-30-sustained-4k-recording-1080-streaming.md), authorized by “ok get this done.” Worktree `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starting commit `39a8dee`. No agents, pushes, external broadcasts or deletion of retained media.

Artifacts: `artifacts/qa/sustained-4k1080-20260930`. Phone `00008140-001474110C13001C`, connected/unlocked; LAN192.168.1.130. Mac36GiB free initially; avoid unnecessary duplicate hour media copies. Existing preserved recording/export evidence remains intact.

## Physical archive checkpoint

- Added explicitly opted-in saved recovery/export/playback/relaunch and short new4K/audio Stop tests to `PhysicalStreamingTests.swift`.
- Incremental signed build-for-testing passed (`archive-build.log`). Screenshot-only xctestrun; no camera/SRT/lab used by saved recovery.
- `archive.xcresult`: saved recording `33D2FF99-7918-42EA-8D41-9A5C076B2011` recovered/exported through production native full-decode validation, playback advanced, relaunch retained recoverable status; test passed873.661s. App did not exit. This confirms saved phone recovery/export, not fresh Stop or sustained streaming.
- Same runner's short fresh test failed20.943s before camera start: 4K control unavailable in the retained landscape UI. Navigation evidence includes landscape402×874 dimensions. Add portrait settling and require selected4K/audio before capture; rerun only this test after the next batch build. No original recording modified.
- Read-only export-directory inventory showed13,672,251,222-byte assembly and13,671,955,428-byte remux before decode completion. Initial inventory used wrong bundle ID and failed harmlessly; correct bundle is `live.scorebug.app`.
- Attempted15s Time Profiler attach after export finished; failed because the old process had exited during the test's deliberate relaunch. No profiling/resource qualification claimed.

## Proxy cadence reproduction and fix

- Added real FFmpeg tests for30fps with±30tick timestamp jitter,60→30cap, duplicates/gaps and long-outage credit bounding.
- Old clock-bucket selector failed the30fps test, removing alternating frames (`cadence-red.log`); other3controls passed.
- Replaced anchored floor selection with a two-credit token bucket: one spare frame for acquisition jitter, bounded sustained rate, no accumulated outage credits, no duplicate/regressing selected PTS and unchanged source A/V timestamps. No pressure guard bypass.
- `SCOREBUG_FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg pnpm --filter @scorebug/home-daemon exec vitest run test/pipeline-cadence.test.ts test/pipeline.test.ts test/worker-processing.test.ts test/worker-processing-windows.test.ts`:54checks pass (`cadence-green.log`). This proves a reproducible selector defect, not exact attribution of the prior hour's single omission or a hardware sustained pass.
- Checked official FFmpeg expression evaluation documentation for per-expression `st`/`ld` state. Proxy resource/omission classification remains under review.

## Receiver-proof and crash-surviving diagnostics

- Added distinct tracker unavailability outcomes. Two focused tests first failed5assertions with nil causes (`proof-reasons-red.log`). Implemented cause preservation through maintenance and clearing on valid acceptance, without relaxing packet/context/age guards.
- `swift test --package-path ios/Packages/ScorebugCore --filter WorkerDecoderDeliveryTests`:14tests pass (`proof-reasons-green.log`).
- Transition checkpoint test correctly failed because an initial close-based snapshot marked incomplete evidence closed (`checkpoint-red.log`). Revision-ordered background persistence and revocation-cause propagation are now implemented; see final results below.

## Final proxy accounting and compatibility

The90k timestamp predictor runs from pipeline start, even when bounded frame history trims older entries. Intentional omissions are emitted only for a complete known interval whose actual encoder submissions corroborate the predicted selection. Selected-but-missing frames remain unexpected; contradictory or legacy evidence stays unknown.

Keep `source-processing-v1`; negotiate the new optional count separately using `workerFrameCapOmissions: tokenbucket-90k-v1`. A new worker strips only this field for an old server, preserving v1 timing/count evidence. New server/old worker reports remain accepted. Swift optional encoding preserves old fixture bytes. Native pressure ignores only the corroborated intentional count, while capture/delivery loss, excessive filter/processing time, pending output and unknown evidence retain their guards.

- Real FFmpeg/predictor/processing batch:57tests pass (`pressure-green-2.log`). Predictor decisions match jitter, burst, duplicate, gap, negative and large-offset PTS cases.
- Core processing contract:6tests pass (`pressure-core-green.log`).
- Native telemetry:46tests pass after reconstructing151decoded/150submitted/one intentional omission with4.35/7.17ms timing, plus unknown/contradictory/overload controls (`hour-window-classification.log`). This is the aggregate numeric scenario, not a replay of the original unretained PTS.
- Final capability negotiation:81reporter checks pass (`cap-negotiation-final.log`);78API checks pass (`cap-api-final.log`). Protocol build and both affected package typechecks exit0.

## Diagnostics and physical harness

Named receiver rejection and first-revocation causes reach transition audit records. Successful transitions also produce bounded atomic revision-ordered background checkpoints, separate from immutable closed reports. Core reason tests14pass; affected audit/session classes159pass (`diagnostics-green-2.log`). Original physical invalidation is still unresolved; named causes are implemented, not a claimed root-cause fix. Rejected-proof age/poll/packet details and complete candidate lifetime correlation remain open.

Camera diagnostics retain only scalar delivered counts/drop reasons and system pressure. Physical DEBUG resource rows sample CPU, task physical footprint, thermal, battery and charging every10seconds, bounded512rows, with forced preparation/Stop/finalization checkpoints. Pure capture-counter regression passes (`capture-counters-green.log`). Native export writes an exact-recording/unique-filename/byte/count sidecar only after production full decode succeeds; missing diagnostics do not change export behavior.

Harness lanes now include saved-export, short archive-stop and combined1080 with600/1800/3600-second holds. Hold starts after fresh confirmed1080 and a settled trial. Fixed30-second observation targets avoid accumulating UI-read overhead. Failed qualification latches the first cause, stops the stream and safely finalizes/exports recording before backend shutdown. Collection copies bounded scalar JSON and only the exact final native MP4 after a Mac disk preflight, preserving phone segments. Combined gates join native hold, actual pre-scale source geometry, closed transitions/resources and all three saved media files.

`encoded1080HoldQualified` covers machine evidence only; final `sustained1080Qualified` stays false until representative fresh motion, visible scores, perceptual sync and requested case/USB/LAN setup are reviewed. No hardware execution of the new combined collection has occurred.

Review found and fixed missing attempt/ACK validation, detached hold milestones, intermediate CPU/capture-counter regression, valid diagnostic sampling jitter being rejected, archive-stop collection failures not failing the runner, and diagnostic detail being discarded on a failed hold. Controls first failed (`qualification-review-red.log`, `qualification-timing-red.log`); final affected Node batch67passes (`qualification-final.log`). Saved-media timing/loss/audio controls3pass (`media-review-final.log`). The checker rejects original symlink paths, does not overwrite results, and correlates native full decode with packets rather than redundantly decoding the hour4K export on Mac.

Incremental signed build-for-testing passes after the final hold scheduling change (`review-phone-build.log`). TeamB222J9J7B8. Build prepared, not installed/run after the authentication failure.

## Simulator integration and independent saved-media checks

One affected ordinary native1080 workflow passed, runner joined0: `artifacts/qa/ordinary-native-nncHUb`, backend `device-lab-8BHxgy`. Used the600-second prepared1080 moving source, software proxy and normal240→360→720→1080/6Mbps adaptation. Native scoring, streaming Stop, independent archive continuation, recording Stop and export passed. Actual receiver1080 span1065frames/35.5seconds; one source pipeline, no receiver reset. Three expected closed transition records and open checkpoint preserved.

Command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer SCOREBUG_FFMPEG_PATH=/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source <absolute prepared-ordinary-recovery-dZeq4S/input.mov> --encoder software --lane quality1080`. Run captured base39a8dee plus dirty current binaries. Final separate capability-negotiation change followed this integration run and passed its focused API/reporter tests; no redundant vertical rerun.

Full independent decode/timing checks and prepared-source identity extraction passed for archive7795consecutive IDs0–7794 and both live outputs7493IDs189–7681. No source-ID errors, minimum rolling30fps, audio gap<1µs, A/V ends16ms/32.886ms/44.662ms. Result: `ordinary-native-nncHUb/media-source-validation/result.json`.

The initial assessment used an incorrect320px barcode crop and failed extraction; preserved unchanged at `media-validation/result.json`. Correct extraction uses the fixture's full-width stripe (`crop=iw:2:0:16,scale=16:1:flags=neighbor,format=gray`), reusing complete decode results. This is simulator/source identity evidence, not hardware thermal/endurance or final perceptual/overlay review. Owned backend and simulators joined; unrelated manual simulators preserved.

## Remaining physical work and current readiness

Fresh Stop did not begin on the latest attempt: `fresh-stop.xcresult` failed before test initialization with **Authentication canceled. Canceled by user.** No recording/stream/backend active. Read-only QA inventory succeeded (14scalar files,47,141bytes); resource/native-export sidecars from the new build have not yet run on hardware. Fresh readiness check `review-lock-state.json`: phone requires passcode. Asked user to unlock/approve automation and report readiness. No answer yet; no silent retry or repeat14-minute saved recovery.

Next: short fresh4K/audio Stop/export/playback/relaunch, then one instrumented600-second combined trace to locate remaining proof reset and thermal workload. Measure only comparisons needed to identify the limiting cost, fix its owner, pass30-minute target configuration checkpoint, then one final60-minute confirmed actual1080 hold with4K/audio throughout. Do not relax real authority/freshness/thermal safeguards. Do not claim fresh Stop, original exit cause or sustained target closed.

No agents, pushes, external broadcasts, unrelated cleanup or raw-hour recopy. Plan remains current goals/status/TODO; experiments and failures stay here.

## Local commits

- `1d190db`: proxy frame-cap jitter correction and negotiated omission attribution, with cross-language contract and native pressure controls.
- Remaining reviewed native diagnostics, qualification harness and current documentation are committed together as the next local checkpoint. No push.
