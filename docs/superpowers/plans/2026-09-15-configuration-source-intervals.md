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

- [ ] Add model stubs and tests in ScorebugMedia for invalid rate/time/session,
  capture metadata rejection, missing/future metadata, ring eviction and closure.
  Extend VideoSourceHistoryTests with actual source metadata; preserve old counts.
- [ ] Implement validated values in `VideoEncodingObservation.swift`, add optional
  encoding to VideoSourceFrame and observe(), and pass it through
  VideoFrameObservationOwner's existing lock. No new tasks or media retention.
- [ ] Add failing PublishingSourceIntervalTests for uniform verified/unverified,
  missing metadata, mixed IDs/sessions, exact exclusive boundary and leading loss.
  Implement `encodingCoverage` from precisely the matched encoded index range.
- [ ] Update SRTPublisher's immutable native configuration callback to call the
  observation owner once with source/configuration metadata. Preserve optional
  external configuration observer and aggregate notification semantics.
- [ ] Extend DualOutputSmoke to exercise the actual production observation owner,
  export bounded encoded history and interval coverage after joined stop, and
  independently compare it with the existing native descriptors and barcode set.
  Add Node regressions before qualifier implementation for missing/relabelled history,
  mismatched interval count/range/coverage and exclusive-boundary behavior.
- [ ] Run Media, Streaming, tooling, both native suites and combined unsigned
  iPhone/Watch Release build sequentially. Obtain bounded independent source review,
  preserve raw events and evidence hashes, document results and commit verified work.

## File map and checks

Create Media `Sources/ScorebugMedia/VideoEncodingObservation.swift` and
`Tests/ScorebugMediaTests/VideoEncodingObservationTests.swift`. Modify Media's
VideoSourceHistory/VideoFrameObservation and their tests; Streaming's
PublishingSourceInterval/SRTPublisher and interval tests; DualOutputSmoke;
`scripts/encoder-configuration-evidence.mjs` and its tests/test-dual-output runner;
configuration boundary and adaptive telemetry documentation.

Example assertions: an interval spanning frames150...299 with a change before150
must be verified; including149 must be mixed; omitting any included metadata must
be unavailable; missing decoded leading frames150...154 cannot remove their native
configuration from classification. Source counts remain150 and decoded count145.

Use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer` for all Swift
commands: `swift test --package-path ios/Packages/ScorebugMedia`,
`swift test --package-path ios/Packages/ScorebugStreaming`, `pnpm test:tools`,
`pnpm test:dual-output`, `pnpm test:native-network`, and
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

The next runtime step uses this classification with verified write receipts and
source/pressure window alignment to acknowledge policy changes. This slice keeps
automatic adaptation disabled and does not replace physical/radio/remote-host gates.
