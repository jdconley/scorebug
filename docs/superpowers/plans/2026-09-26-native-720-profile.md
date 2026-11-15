# Native 720p Live Profile Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement this dependency, with specification and code-quality review before commit.

**Goal:** Give the shared native candidate/live encoder a verified 1280×720, 30 fps, 3 Mbps recipe so the ordinary measured ladder can subsequently advance beyond 360p.

**Architecture:** Add one case to the existing shared `PublishingVideoProfile`. Candidate encoding and guarded live replacement already derive their settings from that recipe. Preserve minimum startup, archive ownership, native admission, timing and resource limits. This dependency is followed by ordinary three-rung integration and real match-media qualification; it does not by itself establish automatic 720p streaming.

**Tech Stack:** Swift, CoreMedia, VideoToolbox/HaishinKit, existing ScorebugMedia/ScorebugStreaming tests and app model tests.

## Current status and remaining vertical work

The ordinary 240/360 recovery route has two consecutive native/transport passes with unchanged settings; both runs also pass three-output waveform/overlay and accepted-phase-window media verification. The earlier unexplained rollback remains preserved. The user approved phone automation; the latest physical retry still stops at Watch preparation before camera capture. A Watch-specific unlock/readiness check is pending.

- [x] Complete the native recipe and component checks below. Reviewed and committed as `43f2229`; root verified all 18 manifest hashes and the five reviewed source blobs.
- [ ] Integrate 720 into the ordinary measured ladder only after these checks and reviews.
- [ ] Add an explicit three-rung native recovery lane and independent evidence expectations: 240 → confirmed 360 → confirmed 720 → constrained minimum → fresh measured climb to confirmed 720. Keep current policy, 750 kbps constraint and 540-second recording limit; additional transitions must fit or fail.
- [ ] Prove actual incoming 1280×720 encoding/decoding and complete three-output media. The stable 1080p proxy canvas alone cannot prove input resolution.
- [ ] Qualify hardware concurrency, sustained operation and wider 1080p/4K requirements separately. Native 1080p is 6 Mbps; 4K is 24 Mbps and exceeds current production probe admission. Camera capture and archive default to 1080p.

## 1. Add the shared recipe under behavioral tests

Files:

- Modify `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/PublishingVideoProfile.swift`.
- Test `ios/Packages/ScorebugStreaming/Tests/ScorebugStreamingTests/PublishingVideoProfileTests.swift`.
- Test `ios/Packages/ScorebugMedia/Tests/ScorebugMediaTests/PublishingVideoProfileChangeTests.swift`.

- [x] Add a raw-value test that fails before implementation, without relying on a compilation failure:

```swift
func testHD720RecipePreservesMinimumStartup() throws {
    let profile = try XCTUnwrap(PublishingVideoProfile(rawValue: "720p30"))
    XCTAssertEqual(profile.width, 1280)
    XCTAssertEqual(profile.height, 720)
    XCTAssertEqual(profile.bitRate, 3_000_000)
    XCTAssertEqual(profile.settings.videoSize.width, 1280)
    XCTAssertEqual(profile.settings.videoSize.height, 720)
    XCTAssertEqual(profile.settings.bitRate, 3_000_000)
    XCTAssertEqual(profile.settings.expectedFrameRate, 30)
    XCTAssertEqual(profile.settings.allowFrameReordering, false)
    XCTAssertEqual(profile.settings.maxKeyFrameIntervalDuration, 2)
    XCTAssertEqual(PublishingVideoProfile.minimumStartup, .low240)
}
```

- [x] Run the focused Streaming test with the installed Xcode toolchain. Retain an executed assertion failure, not a missing-runtime/compiler failure:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugStreaming --filter PublishingVideoProfileTests
```

- [x] Add `case hd720 = "720p30"` between 1080p and 540p. Add `.hd720: 1280`, `.hd720: 720`, and `.hd720: 3_000_000` to the respective width/height/bitrate switches. The shared Streaming settings extension already supplies the codec, frame rate and keyframe behavior.
- [x] Extend receipt validation to exercise the new raw-value profile: accept a receipt with distinct encoder session IDs, increasing PTS, current generation and 1280×720; reject otherwise identical 1920×1080 dimensions. Existing validation must remain authoritative.
- [x] Run focused profile/receipt tests and the Media suite. Keep all existing recipe values and archive settings unchanged.

## 2. Verify actual candidate output and bounded production planning

Files:

- Test `ios/Packages/ScorebugStreaming/Tests/ScorebugStreamingTests/PublishingCandidateEncoderTests.swift`.
- Test `ios/FilmModelTests/NativeOwnedCandidatePublisherTests.swift`.

- [x] Add a real VideoToolbox candidate test using the existing `scope()`/`sample(pts:)` helpers and raw-value 720 profile. Start the candidate, offer three consecutive 30 fps samples, finish/join, then require completed encoding, exactly three accepted/output frames, a nonnil encoder session, a sync first frame, positive compressed bytes and actual 1280×720 format dimensions on every frame. On any error, cancel/join the candidate before rethrowing. This establishes coded geometry, not representative throughput or natural A/V quality.
- [x] Add 720 to the existing distinct production-plan profile matrix. Verify the final probe rate remains `ceil((profile.bitRate + SRTPublisher.audioBitRate) * 1.5)`, the first stage remains half the final, holds remain `[0.8, 0.5]`, all four tested rates are distinct and below the existing 12 Mbps probe cap. Preserve the 8 Mbps video-plus-audio admission boundary and 4K rejection.
- [x] Run real candidate tests, the relevant Streaming profile/transport/receipt suites and the app production-plan tests. Do not replace native output with fabricated dimensions or treat test AAC bytes as playable natural audio.

## 3. Review and preserve evidence

- [x] Build Debug UI and Release iOS device targets with the existing toolchain; no runtime downloads.
- [x] Preserve exact commands, executed test counts, logs and source hashes under `artifacts/qa/native-720-profile-validation/`. If a platform test is unavailable, report that gap instead of counting compilation as an encoding pass.
- [x] Complete independent specification and code-quality reviews; fix supported findings and commit this bounded dependency.
- [x] Update the delivery plan and separate session log.
- [ ] Implement the ordinary three-rung integration. Do not claim automatic 720p support from this recipe-only dependency.

No heavy builds or media analysis run during a live capture. Use the existing isolated checkout; preserve original match media and prior failed artifacts.
