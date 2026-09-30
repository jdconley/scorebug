# Sustained 4K recording and 1080p streaming implementation plan

**Goal:** On the current iPhone 16 Pro, sustain actual 1080p30 upload while recording clean 4K30 with audio, then stop, export, play and relaunch without an app exit.

**Architecture:** Keep independent segmented local recording and the progressive SRT uploader, with the local software proxy producing both overlaid MP4 and mock RTMP recordings. Correct adaptation from attributed evidence, then reduce measured phone workload. Preserve real thermal, congestion, stale-proof and authority-change safeguards.

**Tech stack:** Swift/AVFoundation/VideoToolbox, H.264/AAC, SRT/MPEG-TS, TypeScript/FFmpeg, RTMP and native MP4 export.

**Execution:** Work inline in `codex/local-validation` at `/Users/jd/.codex/worktrees/scorebug-local-validation`; no agents. This is the focused implementation sequence under the [delivery plan](2026-09-13-portable-streaming-and-watch.md). That plan owns delivery milestones; the steps below track their execution. This planning session does not start implementation or capture.

## Target configuration and acceptance

Use the iPhone 16 Pro, Apple clear case, USB charging, a lit moving volleyball scene, home LAN and this Mac's software proxy. Record 3840×2160 at 30 fps with the existing H.264 30 Mbps archive profile and audio; stream through the normal ladder to 1920×1080 at 30 fps and 6 Mbps with audio. Recording quality and streaming ceiling are independent settings. Log actual connection, battery and charging state; verify that media takes the intended LAN route rather than an unintended USB route.

The final acceptance capture includes normal minimum-quality startup, ramp and trial confirmation, followed by **60 continuous minutes of confirmed actual 1080p input**. Record 4K throughout, including startup and a short continuation after streaming stops. The proxy scaling a low-resolution input to a 1080p output does not satisfy this goal.

Acceptance requires all of the following:

- Normal progressive startup and measured admission; no locked profile, fabricated receiver proof or disabled pressure guard.
- Receiver geometry/timestamps prove the full 1080p hold, without a downgrade, outage or publication replacement. A genuine thermal fallback is safe behavior but fails this sustained configuration's qualification.
- Target 30 fresh fps; at least 24 unique fresh frames/s in 99% of rolling five-second healthy windows, with less than 1% fresh-frame loss for stable 30 fps profiles. Keep startup, transitions and outages separately visible. Do not infer freshness from encoded frame counts alone.
- Clean 4K archive, overlaid proxy MP4 and mock RTMP MP4 fully decode; continuous audio and at most 100 ms A/V end offset. Inspect representative motion and waveform/video alignment for perceptual sync. Retain short video gaps and their cause; the existing cadence/loss requirements do not mean zero gaps.
- Phone Stop finishes with a durable completed recording, native export and playback work, and relaunch preserves status. No app exit, watchdog stall or memory growth proportional to archive length.
- Bounded diagnostic history and no sustained serious/critical thermal pressure requiring reduced upload quality. Report capture, encoder, transport and proxy pressure separately.

Case-off and battery-powered comparisons can identify heat contributors; they do not replace acceptance in the requested normal configuration. If measured device limits still prevent the target, report that failed boundary and the limiting workload before proposing a codec or product change.

## Evidence and unresolved questions

The [hour result](../../session-logs/2026-09-30-hour-stream-setup.md) and `artifacts/qa/physical-hour-preparation-20260930/hour-acceptance.json` are the baseline. There are no live jobs.

| Issue | Established evidence | Question to resolve |
| --- | --- | --- |
| Stop/finalization exit | Archive verification retained autoreleased buffers; same-hour Mac recovery used about 13.8 GB before the fix and 35 MB afterward. Fix is installed. | Does the fixed phone complete saved recovery/export and a fresh Stop? Exact OS termination reason was not captured; memory pressure is strongly implicated, not confirmed jetsam. |
| First 1080p reset | Receiver proof invalidated; backend publication/pipeline stayed unchanged. | Which local freshness, packet-validation or authority event caused invalidation? Was proof actually stale, or did local handling lose valid proof? |
| Later 1080p decrease | One proxy omission in a 151-frame window was classified as elevated worker pressure; filter/processing were about 4.35/7.17 ms and transport nominal. | Can timestamp-cap cadence jitter reproduce that omission, and can deliberate selection be distinguished from actual overload? |
| Final low quality | Fresh serious phone temperature forced 720→360→240. | Which capture, archive, live encoder, candidate-probe, UI or charging workload drove heat? Charging and case effects have not been isolated. |

The clean hour recording is preserved under ID `33D2FF99-7918-42EA-8D41-9A5C076B2011`, also copied to `artifacts/qa/physical-hour-preparation-20260930/phone-original-recording`. Mac native recovery passed; physical stop/export remains open. Actual 1080p lasted about 14m20s total. Successful encoded cadence does not qualify sustained 1080p or fresh motion.

## 1. Close the stop/recovery crash first

**Files:** `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/{ArchiveSegmentStore,ArchiveExporter,RecordingSession}.swift`; `ios/Sources/Scorebug/Capture/{RecordingLibrary,FilmModel}.swift`; `ios/FilmModelTests/{RecordingLibraryTests,FilmModelTests}.swift`; `ios/AppUITests/PhysicalStreamingTests.swift`.

- [x] Bound archive verification/copy buffers per chunk, preserve checksum/path/corruption guarantees, and reproduce duration-independent memory on the saved hour. Implemented in `978d27d`; 20 focused archive-store tests pass. Do not redo that fix or synthetic stress run unchanged.
- [ ] Add a narrowly selected physical saved-recording recovery/export workflow. It must accept this interrupted/recoverable recording without manufacturing `completedAt`; the existing completed-only export diagnostic cannot be reused unchanged. Preflight the exporter's free-space requirement, export to a new destination and preserve original segments.
- [ ] Run the workflow on the installed fixed phone; capture memory over recovery/assembly/export, lifecycle phase markers and any OS termination report. Verify complete 4K/audio decode, playback and relaunch. A saved export pass closes recovery only.
- [ ] Make one short new 4K/audio recording and stop it normally. Assert completed status is written only after successful durable finalization, export succeeds, and the app stays responsive/alive through relaunch.
- [ ] If either operation fails, reproduce its exact phase with the saved recording before another capture. Fix retained buffers, actor/main-thread blocking or finalization races only where evidence identifies them. Add the affected lifecycle regression: concurrent/repeated Stop, failure during finalization, or interrupted export, as applicable. Set a device memory budget from measured baseline/headroom; the isolated store's 32 MiB regression allowance is not a whole-app budget.
- [ ] Review the affected diff, run its focused regression once, and commit the crash/lifecycle checkpoint. Do not declare the crash fixed on device until both saved recovery and fresh Stop pass.

## 2. Make every quality decrease attributable

**Files:** `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerDecoderDelivery.swift`; `ios/Sources/Scorebug/Capture/{CaptureStreamingModel,PublishingQualitySession,PublishingQualityDriver,PublishingAppliedTransitionAudit,QualityEvidenceDictionary}.swift`; their existing Core/FilmModel tests.

- [ ] Add bounded structured receiver-proof outcomes: expired receipt, unavailable status, rejected packet/order/age, scope/publication/worker change and explicit revocation. Include monotonic age, polling latency, identifiers and the last valid window. Distinguish an HTTP/poll failure from an invalid proof packet.
- [ ] Join every transition to captured/encoded/received/submitted/omitted counts, PTS window, worker timing/queue limits, transport backlog/loss, thermal age and candidate campaign ownership. Correlate source capture sequence/PTS with unique received frame timestamps in bounded windows; retain representative motion samples to detect freezes that encoded counts miss. Preserve unknown evidence as unknown.
- [ ] Checkpoint transitions and phase markers during capture, using bounded background persistence, so an app exit cannot erase the cause journal. Do not restore high-frequency `@Published` redraws or perform file hashing on the UI actor. Exclude credentials.
- [ ] Add focused tests for each rejection reason, bounded retention, expiry and crash-surviving transition persistence; replay the existing hour journal as a baseline without relabeling its results.

## 3. Correct proxy cadence/pressure attribution

**Files:** `apps/home-daemon/src/{pipeline,worker-processing,worker-processing-windows}.ts`; corresponding `apps/home-daemon/test/*.test.ts`; `ios/Sources/Scorebug/Capture/PublishingQualityTelemetry.swift` and `ios/FilmModelTests/PublishingQualityTelemetryTests.swift`.

- [ ] Build a short deterministic FFmpeg reproduction around the existing timestamp selector: ordinary 30 fps with phase/jitter near bucket boundaries, genuinely faster input, duplicate timestamps and actual omitted/delayed output. Preserve source PTS. Establish whether selection accounts for the observed single omission before changing pressure logic.
- [ ] If the selector wrongly removes ordinary 30 fps frames, correct that boundary behavior and demonstrate that above-target input still has a finite cap. Do not duplicate frames or rewrite timestamps to make cadence look healthy.
- [ ] If deliberate cap removal remains necessary, report verifiable selected-versus-unexpected omission accounting. Change the cross-language contract only when existing counters cannot distinguish them. Then update `packages/protocol/src/worker-processing.ts`, `apps/control-plane/src/worker-processing.ts`, `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerProcessingReport.swift` and their affected tests together. Legacy/unattributed omissions must not silently become healthy.
- [ ] Replay the healthy 151-frame/one-omission window and true-overload controls. Avoid treating a proven cap removal as immediate resource overload, while retaining actual delivery/cadence loss, queue growth, excessive processing time and incomplete-evidence guards. A classified omission remains visible in media loss accounting against the target cadence.
- [ ] Run the affected worker and native telemetry tests once, inspect the short reproduction's saved frames, review and commit. No hardware soak to validate this deterministic fix.

## 4. Diagnose and correct receiver-proof resets

**Files:** `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerDecoderDelivery.swift`; `ios/Sources/Scorebug/Capture/{CaptureStreamingModel,PublishingDeliveryAuthority,PublishingQualitySession}.swift`; `ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/WorkerDecoderDeliveryTests.swift`; `ios/FilmModelTests/{CaptureStreamingModelTests,PublishingQualitySessionTests}.swift`.

- [ ] Replay same-publication delivery across normal full/delta refresh, delayed poll, genuine expiry, rejected packet, reconnect and actual worker/publication replacement. Use the new reason data to reproduce the original invalidation or obtain one short instrumented physical trace if the saved evidence cannot identify it.
- [ ] Correct the proven refresh/validation/lifecycle defect at its owner. If proof genuinely expired, fix the cause of missing fresh evidence; never extend freshness or retain a revoked authority just to hold 1080p. Same publication alone is not sufficient proof of continuity.
- [ ] Assert that normal same-context refresh and acknowledged quality trials preserve valid authority, while real replacement, stale evidence and queued work under revoked authority still reject/reset. Existing post-acknowledgment guard tests must continue to pass.
- [ ] Run the affected Core/model tests once, review and commit. Claim this issue closed only with a reproduced cause and corrected behavior, not merely a journal with no new reset.

## 5. Measure and reduce phone thermal load

**Files:** `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/{IOSCameraCaptureSource,SegmentedArchiveWriter,PublishingThermalObservation}.swift`; `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/{SRTPublisher,PublishingCandidateEncoder,PublishingCandidateMeasurement,PublishingCandidateCampaignOwner,PublishingVideoCost}.swift`; `ios/Sources/Scorebug/Capture/{NativeOwnedCandidatePublisher,NativeCandidateAttempt,PublishingQualitySession}.swift`.

- [ ] Add low-overhead capture-drop reason counts, camera system pressure, active archive/live/candidate encoder lifetimes, sample retention, encoder duration/backlog and probe duty. Record thermal, process memory/CPU, battery/charging and available energy/GPU measurements on a common timeline. Distinguish requested, verified and unknown hardware acceleration. Public VideoToolbox verification requires availability guards on iOS 17.4+; do not use private archive-writer keys.
- [ ] Profile short matched runs from comparable cool baselines: 4K archive only; 1080p upload only; combined without candidate campaigns in a diagnostic lane; combined with production adaptation. Use about 8–10 minutes each to compare workload, not to claim thermal stability. Run only comparisons needed to isolate the measured bottleneck. Document ambient conditions and scene motion.
- [ ] Optimize the dominant measured cost, then repeat only its matched comparison. Candidates include redundant candidate encoding after ceiling confirmation, campaign resources surviving settlement/cancellation, retained pixel buffers, unnecessary copies/scaling, encoder settings or preview/UI work. The camera already uses NV12 with HDR/stabilization disabled; fair-temperature and UI-polling fixes already exist.
- [ ] If capture/dual encoding remains the limit after avoidable costs are removed, measure an alternative archive encoder/capture path against current H.264 before selecting it. HEVC is an experiment, not an assumed power improvement. Preserve recording quality, audio, recovery, export and supported OS/device behavior; document any compatibility tradeoff before making it the default.
- [ ] Keep serious/critical fallback and all delivery guards enabled in production. Prove hot-device fallback still works with the existing focused policy tests; no broad fault sweep. Review and commit the measured improvement with before/after workload evidence.

## 6. Add a repeatable combined qualification lane

**Files:** `scripts/test-physical-recovery.mjs`; `scripts/test/{physical-recovery,physical-startup-evidence}.test.mjs`; `ios/AppUITests/PhysicalStreamingTests.swift`; `scripts/{ordinary-geometry-evidence,media-sync,media-tools}.mjs`; `docs/device-testing.md`. Reuse the full-decode/gap accounting in `artifacts/qa/physical-hour-preparation-20260930/verify-hour-media.py`; promote reusable checks into tracked runner code rather than relying on that artifact path for future runs.

- [ ] Add explicit saved-export and combined-duration modes to the current harness. Its existing lanes do not expose an hour mode. Validate independent archive quality/upload ceiling, destination paths, finite startup/finalization deadlines and an owned stop/cleanup sequence; do not publish unsupported command flags as working instructions.
- [ ] Start the sustained-hold timer only after fresh receiver evidence confirms actual 1080p and the production trial has settled. Persist geometry spans, quality transitions, memory/thermal phases and score changes. Distinguish startup timeout, downgrade, stale proof, app exit, export failure and media-validation failure in the final result.
- [ ] Record both overlaid outputs and the clean archive; use moving footage and a few native phone score changes. Reuse accepted Watch scoring/companion evidence unless scoring contracts change. Avoid a continuous test screen recorder that adds an unrelated encoder workload.
- [ ] Preserve artifacts and close/join app workflow, worker, receiver and lab even on timeout. Automatic downgrade/crash should end the attempted qualification, finalize what is safe and report the first failing gate rather than run out an uninformative hour.
- [ ] Run the two affected Node runner test files once. Reuse installed builds for unchanged code; batch signed phone builds. If a shared telemetry contract changed, run one affected full simulator vertical before hardware qualification; otherwise reuse the accepted vertical.

## 7. Staged physical acceptance and handoff

- [ ] After steps 1–6, run one **30-minute combined checkpoint** in the target charging/case configuration. This crosses the prior roughly 24-minute thermal onset. Require confirmed 1080p, stable capture/encoder headroom, no serious-pressure fallback and successful stop/export. A failure returns to its attributed owner; no blind timer/queue sweeps or repeated hour tests.
- [ ] When that checkpoint passes, run the final **60-minute confirmed-1080p hold** after normal ramp, with 4K/audio recording throughout. Pause setup for phone/TV positioning and the first-session automation prompt before capture. Report startup and total recording duration separately from the hold.
- [ ] Validate all three full media files, actual input geometry/fresh cadence, transition journal, thermal/resource trajectory, native stop/export/playback and relaunch. Retain a machine-readable result that lists each gate independently; do not convert a runner exit or 1080p output dimensions into acceptance.
- [ ] Update the delivery plan and acceptance matrix with the exact qualified configuration and remaining boundaries. Put commands, profiles, evidence and failed hypotheses in this session's log; keep the plan limited to goals/status/tracking. Review the final diff and commit; no push or external broadcast.

## Focused checks and execution rules

Use [fast iteration](../../fast-iteration.md). Select the affected command per batch; these are not a mandatory suite to run after every edit:

```sh
swift test --package-path ios/Packages/ScorebugCore --filter WorkerDecoderDeliveryTests
pnpm --filter @scorebug/home-daemon exec vitest run test/pipeline.test.ts test/worker-processing.test.ts test/worker-processing-windows.test.ts
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer xcodebuild test -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -destination 'platform=macOS' -derivedDataPath ios/DerivedData/FilmModel -only-testing:ScorebugFilmModelTests/PublishingQualityTelemetryTests -only-testing:ScorebugFilmModelTests/PublishingQualitySessionTests CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-
node --test scripts/test/physical-recovery.test.mjs scripts/test/physical-startup-evidence.test.mjs
```

Select `RecordingLibraryTests` or `CaptureStreamingModelTests` instead of the listed FilmModel classes when changing their lifecycle behavior. Run archive-store regressions again only if archive-store code changes. Build protocol output only after contract changes or if missing; typecheck affected packages after type changes. Recheck LAN/device availability before physical execution; sign with Conley Chaos LLC `B222J9J7B8`. Preserve recordings, originals and unrelated simulators. No new Watch acceptance, remote proxy experiment, purchases or external broadcasts in this workstream.

## Research constraints

[Apple TN2445](https://developer.apple.com/library/archive/technotes/tn2445/_index.html) distinguishes late-frame, out-of-buffer and discontinuity drop reasons; collect these before treating all camera drops as network loss. [VideoToolbox's hardware encoder query](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_usinghardwareacceleratedvideoencoder) can verify the selected encoder where the public API is available. Retain the existing [platform adaptation research](../../research/2026-09-25-live-platform-adaptation.md): viewer ABR timings are not uploader control rules, and unpublished platform thresholds are not evidence. No faster ramp, larger queue or thermal bypass is justified by this hour's results.
