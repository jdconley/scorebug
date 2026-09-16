# Compressed frame evidence implementation plan

> **For agentic workers:** Use superpowers:executing-plans for this evidence-driven continuation of the approved streaming plan.

**Goal:** Identify encoded bursts and random-access recovery boundaries before changing transport or encoder behavior again.

**Architecture:** Extend the existing synchronous pre-mux scalar observer with actual sample byte count and the native sync attachment. Retain one bounded scalar record per already-counted frame in the DEBUG transition fixture. Independently reconcile records with phase counts, source times and callback times. No payload retention, new timers or quality decisions.

**Tech stack:** CoreMedia, Swift 6, existing vendored HaishinKit, Node test runner, FFmpeg receiver analysis.

## Design and scope

The preceding relative-pacing run reduced the peak 100 ms receive bin but worsened the minimum delivered cadence to 14.6 fps. Requested bitrate, dimensions and transport counters do not establish how large individual compressed frames are or where the next random-access point occurs.

Prefer scalar sample metadata over either a new media tap or another unmeasured transport knob. A media tap would duplicate payloads and add I/O to the path under measurement; a knob change would not resolve the missing evidence. Native sync metadata follows CoreMedia's NotSync attachment value (absent means sync, explicit false also means sync). Invalid samples produce unavailable sync evidence. This is not an independent H.264 bitstream parse or proof that a sync frame reached the receiver intact.

Source: https://developer.apple.com/documentation/coremedia/kcmsampleattachmentkey_notsync .

Stay in the existing isolated worktree. Preserve archive, freshness, cadence, identity and queue gates. All behavior settings for the next native run match the last relative-pacing run. Production adaptation remains disabled. The user has authorized autonomous implementation and verification of this plan.

## Tasks

- [x] Add SDK red tests in `vendor/HaishinKit/SRTHaishinKit/Tests/SRT/CompressedVideoFrameTests.swift`: real sample bytes, absent/false/true NotSync, invalid sample gives nil sync, passthrough remains distinguishable. Run `swift test --package-path vendor/HaishinKit --filter CompressedVideoFrameTests` with Xcode 26.2.
- [x] Extend `CompressedVideoFrame.swift` with `byteCount: Int` and `isSync: Bool?`; copy the actual total sample size and inspect the single sample attachment without creating it. Preserve existing validity and delivery. Rebuild the exact maintained patch against the original source hashes and run `verify-scorebug-patch.py`.
- [x] Add app-model red tests for per-frame byte/sync/time retention, explicit false, invalid metadata, post-close rejection and 25,000-record capacity. Extend `NativeProfileTransitionFixture.swift` with bounded scalar records, populated by the actual observer. Emit versions 4 (fixed) and 5 (adaptive). Require byte count > 0 and known sync on accepted fixture records. Existing frame/phase limits still latch invalid evidence.
- [x] Add `scripts/native-compressed-frames.mjs` and tests. Reconcile raw frame counts, strictly increasing fixture IDs, monotonic observation times, phase boundaries/counts and exact maximum source/observation gaps. Require first frame of every phase to be sync. Return per-phase total bytes, sync IDs/sizes and peak 100 ms output bin; do not equate those bins with network capacity. Reject malformed, missing, inconsistent or extra records. Legacy format qualification remains readable, while the native runner explicitly requires current frame evidence.
- [x] Run vendor suite, streaming suite, app-model suite, tooling and unsigned combined Release build sequentially where heavy. Review actual diff and provenance before the native fixture.
- [x] Snapshot runtime source. Run the 240-second rate4m adaptive native fixture with 400 ms publishing recovery, slice decoder and relative pacing, otherwise identical to the preceding checkpoint. Join its owner even if a gate fails.
- [x] Analyze archive and receiver identities independently, retain failed gates, and correlate missing identity ranges with actual native sync frames and frame sizes. Verify resource cleanup and hash terminal artifacts. Update the main plan/results and commit a concrete checkpoint.

## Verification commands

All commands run from `/Users/jd/.codex/worktrees/scorebug-local-validation`, Apple commands with `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.

```sh
swift test --package-path vendor/HaishinKit
python3 vendor/HaishinKit/verify-scorebug-patch.py
swift test --package-path ios/Packages/ScorebugStreaming --scratch-path ios/.build/streaming
xcodebuild -project ios/Scorebug.xcodeproj -scheme ScorebugFilmModelTests -derivedDataPath ios/DerivedData/FilmModel -destination platform=macOS test
pnpm test:tools
xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -derivedDataPath ios/DerivedData/Release -destination generic/platform=iOS build CODE_SIGNING_ALLOWED=NO
```

Native environment: `SCOREBUG_TEST_PUBLISH_PACING=relative SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS=400 SCOREBUG_TEST_DECODER_THREADING=slice SCOREBUG_TEST_RELAY_PUBLICATION=1 SCOREBUG_TEST_WORKER_PROCESSING=1 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 SCOREBUG_TEST_MOTION_FIXTURE=blocks16 SCOREBUG_TEST_STREAM_HOLD_SECONDS=240 SCOREBUG_TEST_NATIVE_QUALITY=1 SCOREBUG_TEST_NATIVE_CONFIRMATION=1 SCOREBUG_TEST_UPLINK_PROFILE=rate4m SCOREBUG_TEST_ADAPTIVE_PROFILES=1 pnpm test:native-streaming`.

Only about 20 GiB is available. Reuse existing build directories; keep media experiments sequential. No external destination, license acceptance or deployment is authorized by this measurement.

## Pre-run verification

Causal red logs demonstrate the absent SDK fields, absent app collector arguments and missing independent qualifier. The intentional raw record addition invalidated the old summary-only 12 KB bound; the app and runner now share an 8 MiB serialized cap, with the existing 25,000-record count cap unchanged. A capacity regression verifies that the full scalar dataset stays below that cap.

160 vendor tests, 61 streaming tests, 211 app-model tests and 1014 tooling tests pass (1446 total), as does the unsigned combined iPhone/Watch Release build. The SDK patch verifies all 162 original upstream hashes and its exact reverse/forward round trip. Read-only review found no blockers. Runtime source is snapshotted against 5dee163 before the native experiment. Source and tests change only observation/qualification, not publishing behavior or archive ownership.

The diagnostic sync field is native CoreMedia metadata, not an independently parsed H.264 IDR. Recovery conclusions must distinguish the next native sync point from proof that an intact keyframe was delivered. Largest 100 ms compressed-output bins use phase-relative observer time and are not network bandwidth estimates or sliding-window bounds.

## Native outcome and next experiment

`native-app-98ZoEn` uses exactly the preceding relative-pacing fixture settings; the source change adds measurement only. The native UI workflow succeeds. The full runner fails live A/V end coverage at −108.1 ms, exceeding the unchanged 100 ms budget; supplemental analysis also preserves identity and cadence failures.

- The independent archive retains **8176 consecutive 1080p/30 frames** over 272.533 seconds, all **136/136** audio markers, a 20 ms end difference, and zero rejected/dropped archive queue samples.
- All **7799** native compressed records reconcile with five phases, source boundaries and observation gaps. All **84** local pressure windows replay; four real profile receipts bind to their admitted operations and finish within the two-second completion budget. Native change completion takes 446–463 ms. Actual sender delay is 400 ms on all 1000 retained samples; accepted source-evidence age is median 1.591, maximum 1.802 seconds.
- Live has 7573 decoded pictures across 7739 source positions, **171 absent unique identities**, five repeated observations, four non-increasing barcodes and six identity/cadence anomalies. Worst receiver cadence is **12 fps**. Positive audio timestamp gaps total 128.9 ms. The worker logs no decode-error/concealment messages, while the relay logs two lost/recovered H.264 timing episodes: absence of decoder messages is not picture-integrity proof.
- Both 2613-bin proxy timelines reconcile with no omissions. Forward overflow is 821 packets, peak received bin 139264 wire bytes, maximum forwarded residence 530.91 ms; reverse overflow remains zero. Four successful relay snapshots have the same connections. The later fifth attempt sees zero connections after close and is retained as a failed observation, not a zero-valued connection sample.

### Measured encoded output

The five phases' average video payload rates are **6.039, 3.531, 7.822, 3.529 and 6.013 Mbps**. The short upward trial therefore exceeds the 4 Mbps link before transport/audio overhead; smoothing batches alone cannot make that trial sustainable. Requested low-profile bitrate remains distinct from measured output.

Individual frames are at most **47462 bytes**. All first frames of new encoder phases have native sync metadata, with sizes about 42–47 KB. Large output bursts instead contain multiple frames: phase-relative 100 ms bins reach 248253 bytes/10 frames in the first 1080p phase, about 191 KB/13 frames in the low phases, and 227451 bytes/8 frames in the short trial. Bin alignment matters: using one global first-output anchor, the terminal drain reaches 326045 bytes/13 frames, and low-phase drains reach about 206 KB/14 frames.

The final ten frames of each phase arrive in **26–80 ms**, despite spanning 300 ms of source time. Relative to the first native output clock plus source delta, phase tails lead ordinary cadence by **301–395 ms**; the first frames of later phases are within 2.3–4.4 ms of that clock. This is consistent with the existing off-actor encoder drain releasing pending frames in batches, not an oversized individual replacement keyframe. It does not prove exact packet-to-frame causality.

Missing receiver ranges 1982–2033 and 3534–3643 resume at native sync points **2034** and **3644**. The longer range includes native sync frames **3557** and **3584** that have no observed receiver identity. Sync metadata and decoded barcodes do not independently prove the H.264 contents of a frame or intact image pixels, but they locate recovery against measured native random-access evidence.

### Decision

Next qualify **an opt-in source-cadence pacer before muxing**: preserve every compressed frame and its timestamp, retain the initial output-time/source-time mapping across geometry changes, and prevent an encoder drain from sending later frames ahead of that cadence. It needs bounded queue/current-item ownership, cancellation/generation checks, audio independence, joined finish, unchanged deadlines and actual post-pacing measurements. Avoid an added fixed latency or another enlarged transport queue. Do not claim production readiness from a replay.

A conservative offline replay of the 7799 measured records preserves every frame/byte and uses `max(actual output time, first output time + source delta)` for eligibility. Maximum deferral is 394.6 ms, maximum simultaneously pending storage is 12 frames/284586 bytes (counting arrivals before releases at ties), and the largest global 100 ms bin falls from 326045 to 170984 bytes. The remaining largest bin is in the unsustainable upward trial. This is a hypothesis test on recorded timestamps, not an implemented pacer or a proof of network delivery, end-to-end latency or changed closed-loop adaptation.

Upward capacity qualification remains a separate required correction; the link must support the measured cost of the candidate profile, not just its requested bitrate. No default, production adaptation, freshness bound, cadence gate or independent archive behavior changes in this checkpoint. Physical devices, Watch network routes, long soaks and other hosts remain open.

Evidence is under `artifacts/qa/compressed-frame-*` and the native directory. Test/build/native/analysis owners are terminal and joined. Finalization verifies exact container/simulator removal, stopped collection, unchanged runtime snapshot and byte-identical stopped/final quality evidence before hashing all terminal artifacts.
