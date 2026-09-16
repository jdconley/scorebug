# Low live profile qualification

> **For agentic workers:** Use superpowers:executing-plans inline; do not enable automatic adaptation as part of this slice.

**Goal:** Measure a real 640×360/30 fps publishing candidate while preserving the independent 1080p archive.

**Architecture:** Extend the immutable publishing profile and existing explicit fixed-profile DEBUG fixture. Preserve all format, native cost, full decode, frame identity, audio, worker and proxy checks. Keep bandwidth probes exclusive to the already qualified fixed540 scenario for now.

**Tech Stack:** Swift/VideoToolbox/XCTest, Node test runner, FFmpeg, local SRT relay and worker.

- [x] Add failing Swift profile/fixture tests for `low360` (640×360, requested 600,000 video bps, H.264/30 fps) and unchanged archive defaults.
- [x] Add failing Node tests for exact `360p30` fixture authorization, geometry, native format, native byte cost and rejection of crossed dimensions/profile labels. Preserve all fixed540 cases and reject probe requests at 360.
- [x] Implement the profile and explicitly gated native fixture selection in `PublishingVideoProfile.swift`, `VideoObservationFixture.swift`, `CaptureStreamingModel.swift`; no production default change. Add 360 to the UI test launcher
  in `ios/AppUITests/NativeStreamingTests.swift`, retaining 540-only bandwidth probes.
- [x] Extend `native-live-profile.mjs`, `native-format-qualification.mjs`, `native-video-cost.mjs`, `native-streaming-options.mjs`, `native-streaming-fixture.mjs` and the runner for the 360 evidence path. Scale diagnostic sampling coordinates consistently, keeping archive dimensions unchanged.
- [x] Run streaming/media/model/tool tests, simulator test build and unsigned combined iPhone/Watch Release build; investigate any failures.
- [x] Freeze source inventory and run the actual fixed360 scheduled 4 Mbps pressure fixture without a probe. Independently reconcile format, cost, archive/live frame identity, audio, full decodes and proxy teardown. Record measured bitrate rather than assuming the 600 kbps setting is achieved.
- [x] Save results, remaining gates and commit. A passed fixed360 run qualifies only that finite simulator scenario; 240, transitions, short-window health and physical-device behavior remain separate gates.

Core test assertions:
```swift
let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "360p30"))
XCTAssertEqual(profile.width, 640)
XCTAssertEqual(profile.height, 360)
XCTAssertEqual(profile.bitRate, 600_000)
```
```js
assert.equal(nativeLiveProfile({ ...args, environment: { ...environment,
  SCOREBUG_TEST_LIVE_PROFILE: '360p30' } }), '360p30');
assert.equal(nativeMediaGeometry('360p30', true).width, 640);
assert.equal(nativeMediaGeometry('360p30', false).width, 1920);
```

Commands: `swift test --package-path ios/Packages/ScorebugStreaming`,
`swift test --package-path ios/Packages/ScorebugMedia`, `pnpm test:tools`, and existing
`ScorebugFilmModelTests`, simulator build-for-testing and unsigned Release commands
with `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`.
Actual run uses `SCOREBUG_TEST_LIVE_PROFILE=360p30`, `SCOREBUG_TEST_UPLINK_PROFILE=rate4m`,
`SCOREBUG_TEST_PUBLISH_PACING=relative`, `SCOREBUG_TEST_PUBLISH_PEER_LATENCY_MS=400`,
`SCOREBUG_TEST_DECODER_THREADING=slice`, publication/processing/direct-recorder flags 1,
`SCOREBUG_TEST_MOTION_FIXTURE=blocks16`, and 180 seconds hold with `pnpm test:native-streaming`.

## Verification progress

79 streaming, 254 media, 230 capture-model, 344 worker and 1,192 tooling tests pass;
worker typechecking, ARM64 simulator build-for-testing and unsigned combined
iPhone/Watch Release builds pass. The first actual run (`native-app-OG2Tdx`)
reproduced the remaining 540-only UI launcher assertion before media startup.
The launcher now admits 360 explicitly while keeping probe admission unchanged.
A new runtime snapshot (`low360-runtime-source-v2.json`) and actual run retain
the failed first attempt as evidence rather than relabeling it.

Actual run `native-app-3Zrmzl` passes: 6,354 consecutive 1080p archive frames,
5,961 consecutive 360p retained live frames, 105 archive/99 live audio markers,
clean full decodes and 29.8 fps minimum reported receiver cadence. The scheduled
4 Mbps phase lasted 60.000179 seconds with 29,263,388 forwarded wire bytes and no
proxy drops; every child terminated and joined. Independent verification passes
and 11 damaged-evidence copies are rejected. A mutation exposed a missing UUID
shape check in the new independent verifier's raw tail records; the verifier was
corrected and the unchanged control and full mutation set rerun successfully.

**Bandwidth limitation:** eight measured native windows contain 7,084,913 H.264
payload bytes; maximum measured cost is 3,546,352 bps despite 600,000 bps requested.
That is approximately the preceding 540p trial's 3.527 Mbps. These different trials
are not a matched-scene rate-control experiment, but they provide no basis to
claim a useful bandwidth saving. 360p is verified as an actual native format under
this finite 4 Mbps simulator scenario, not as a qualified weak-network minimum.
Production startup remains unchanged; no automatic adaptation is enabled.
Investigate effective encoder-rate control and measure lower candidates before
assuming that a smaller resolution reduces network load.

Evidence: `artifacts/qa/low360-final-verification.json`; runtime sources are bound
to the second inventory. The first failed launcher run and verifier mutation
failure are retained separately from the final passing results.
