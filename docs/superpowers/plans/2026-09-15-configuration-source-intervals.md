# Configuration-associated source intervals implementation plan

> **For agentic workers:** Use executing-plans inline with tests before behavior and
> bounded independent review. Parent owns all native/Swift/media execution.

**Goal:** Carry verified native submission identity through the app's existing source
history and classify matched receiver intervals by their actual configurations.

**Architecture:** Add platform-neutral scalar encoder evidence to ScorebugMedia's
existing bounded source ring. SRTPublisher records aggregate completion and source
metadata through one owner call. PublishingSourceInterval classifies the included
encoded frames on (previous endpoint, current endpoint], without relabeling old
callbacks or treating the exclusive anchor as an included frame.

**Tech stack:** Swift/CoreMedia, existing VideoToolbox callback, bounded ring history,
real dual-output fixture, independent Node evidence checks.

## Design and alternatives

Reusing the existing ring retains one source identity and bounded storage. A second
configuration ring would need another cross-history join and eviction policy.
Inferring membership from receipt or callback arrival alone cannot safely classify
queued old completions. Therefore retain the actual immutable native metadata with
each encoded source frame, not a mutable current configuration.

Add failable validated `VideoEncodingConfiguration` (UUID, encoder session UUID,
positive Int32-compatible bitrate) and `VideoEncodingObservation` (session UUID,
optional configuration, finite nonnegative submission/completion uptime in order).
Mismatched session/configuration fails construction. Capture entries cannot acquire
encoding metadata; an observation completed after owner admission is unavailable.
Invalid/missing metadata does not erase otherwise valid capture/encoding counts.
Existing observe calls remain compatible and provide no encoding metadata.

Coverage is explicit: `unavailable` if any included encoded frame has no metadata;
`unverified` if all share one native session and no verified configuration;
`mixed` for multiple sessions/configurations or verified/unverified mixtures;
`verified(configuration)` only when every included encoded frame agrees exactly.
The exclusive prior endpoint may have an old configuration without contaminating
the new interval. Interior/leading loss remains in the interval denominator and
configuration classification. A closed history remains historical evidence.
No classification proves rate convergence, receiver freshness or current health.

## Tasks

- [x] Add model stubs and tests in ScorebugMedia for invalid rate/time/session,
      capture metadata rejection, missing/future metadata, ring eviction and closure.
      Extend VideoSourceHistoryTests with actual source metadata; preserve old counts.
- [x] Implement validated values in `VideoEncodingObservation.swift`, add optional
      encoding to VideoSourceFrame and observe(), and pass it through
      VideoFrameObservationOwner's existing lock. No new tasks or media retention.
- [x] Add failing PublishingSourceIntervalTests for uniform verified/unverified,
      missing metadata, mixed IDs/sessions, exact exclusive boundary and leading loss.
      Implement `encodingCoverage` from precisely the matched encoded index range.
- [x] Update SRTPublisher's immutable native configuration callback to call the
      observation owner once with source/configuration metadata. Preserve optional
      external configuration observer and aggregate notification semantics.
- [x] Extend DualOutputSmoke to exercise the actual production observation owner,
      export bounded encoded history and interval coverage after joined stop, and
      independently compare it with the existing native descriptors and barcode set.
      Add Node regressions before qualifier implementation for missing/relabelled history,
      mismatched interval count/range/coverage and exclusive-boundary behavior.
- [x] Run Media, Streaming, tooling, both native suites and combined unsigned
      iPhone/Watch Release build sequentially. Obtain bounded independent source review,
      preserve raw events and evidence hashes, document results and commit verified work.

## File map and checks

Create Media `Sources/ScorebugMedia/VideoEncodingObservation.swift` and
`Tests/ScorebugMediaTests/VideoEncodingObservationTests.swift`. Modify Media's
VideoSourceHistory/VideoFrameObservation and their tests; Streaming's
PublishingSourceInterval/SRTPublisher and interval tests; DualOutputSmoke;
`scripts/encoder-configuration-evidence.mjs` and its tests/test-dual-output runner;
configuration boundary and adaptive telemetry documentation.

Example assertions: an interval spanning frames 150–299 with a change before frame 150
must be verified; including frame 149 must be mixed; omitting any included metadata must
be unavailable; missing decoded leading frames 150–154 cannot remove their native
configuration from classification. Source counts remain 150 and decoded count 145.

Use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer` for all Swift
commands: `swift test --package-path ios/Packages/ScorebugMedia`,
`swift test --package-path ios/Packages/ScorebugStreaming`, `pnpm test:tools`,
`pnpm test:dual-output`, `pnpm test:native-network`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

The next runtime step uses this classification with verified write receipts and
source/pressure window alignment to acknowledge policy changes. This slice keeps
automatic adaptation disabled and does not replace physical/radio/remote-host gates.

## Verified checkpoint

All 198 Media tests (143 XCTest plus 55 Swift Testing), 51 Streaming tests and 755
tooling tests pass, including five new Media cases, seven interval cases and 23
independent history-oracle cases. Combined unsigned iPhone/Watch Release build
passes. Independent source review approved production and fixture code; suggested
mixed/missing metadata, interior receiver loss, duplicate notification and reversed
admission-time coverage is included.

Default suite `artifacts/qa/dual-output-Bzn0sg` and network suite
`artifacts/qa/dual-output-uerkep` both pass. All eight archives retain 420 frames.
All five successful publishers retain 420 native descriptors, 420 history entries
and 420 aggregate callbacks. Each probe set independently verifies unverified,
verified and mixed coverage around the actual write boundary. Normal/recoverable
live media retain 420 frames. Overload has 394 best-effort decoded frames with invalid
identities and fails strict live decode; no fresh-frame/loss claim is made. Peak
measured process RSS is below 96 MiB. Saved evidence replays independently for both
suites. Complete events are retained separately from bounded diagnostic log tails.

A stale Streaming SwiftPM dependency source list initially omitted the new Media
file. That failed build is retained separately; only owned package caches were
cleaned, including the two native tools after inspecting their stale source lists.
No media gates or lifecycle behavior were relaxed.

Hashes are recorded in `artifacts/qa/configuration-interval-final-verification.json`.
The native interval probes explicitly use declared finite-fixture receiver endpoints;
they do not substitute for production worker reports. Runtime verified startup and
application acknowledgment, pressure-window alignment, actual automatic trial and
rollback behavior, resolution transitions and physical/radio/remote-host validation
remain open in the parent plan.
