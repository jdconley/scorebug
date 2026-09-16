# Aligned transport and measured window duration implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline with behavioral
> red/green tests and bounded independent review. Parent runs all verification sequentially.

**Goal:** Make actual capture interval durations usable by the policy and provide
transport gauge evidence over those exact uptime boundaries without inventing counters.

**Architecture:** Extend the existing 64-sample validated transport history snapshot
with a pure interval query. Means use preceding sampled gauges within bracketing
collections. Counter deltas remain explicitly attached to the enclosing collections.
Permit 1...5.25-second policy inputs, preserving measured elapsed time and every fps,
loss, freshness, recovery and rolling-five-second output gate.

**Tech stack:** Core/Media Swift tests, native SRT dual-output fixture and independent
Node reconstruction from actual timestamped native collections.

## Decisions

Measured 150-frame source spans can exceed five seconds by milliseconds. Clamping
time would inflate measured fps; rejecting all such windows prevents recovery. The
input-duration ceiling is explicitly 5.25 seconds, using the existing fixture's
250 ms producer-lag budget as a bounded ingestion allowance, not a quality guarantee.
The lower bound stays one second. All rates and 30-second recovery/10-second trial
confirmation still use actual timestamps. At the upper bound, 150/5.25 is only
28.57 fps and cannot qualify strong recovery. Counts below 24 actual fps still
request reduction. This does not relax the separate rolling-five-second media gate.

Transport `interval(from:to:)` is historical and needs a retained sample at/before
start and at/after end. No extrapolation. Existing gaps >2 seconds reset history;
quarantine rejects queries. Closure retains historical samples but fresh accessors
still reject closed state. Ring eviction makes uncovered intervals unknown.

Expose requested start/end, enclosing collection start/end, sample count, weighted
buffer bytes/ms and RTT, enclosing gauge maxima, and exact enclosing sent/retransmit/
drop deltas. Never proportionally interpolate wide counters or label them exact
requested-interval deltas. Normalize weights/gauges to avoid overflow for finite
extreme RTT. No capacity or policy nominal/elevated classification is added here.
The future app adapter must independently bind attempt/generation/configuration,
acknowledgment, freshness and pressure thresholds.

## Tasks

- [x] Core regressions: measured 5.000622/5.001985-second healthy windows accepted;
  5.25 allowed, >5.25 rejected; actual-rate floor still reduces; 150-frame 5.25-second
  windows never accumulate strong recovery; jittered contiguous windows accumulate
  actual elapsed recovery and post-ack confirmation. Then expose documented duration
  bound and implement the validation change.
- [x] Media API stubs and behavioral tests for fractional/nonuniform bounds,
  left-held gauges, exact wide enclosing deltas, edge sample maxima, missing/bracketing
  coverage, gaps, eviction, duplicate readings, quarantine, immutable/closed history,
  and finite extreme RTT. Implement in PublishingTransportWindow.swift and expose
  retained ordered samples/query through PublishingTransportStatisticsSnapshot.
- [x] Native fixture: retain the monitor's validated tracker via a small synchronized
  scalar owner, close after joined monitor stop, export retained samples and per-source
  probe interval results. Source probe boundaries remain explicitly finite-fixture
  endpoints. Independently reconstruct query results from native collections in Node;
  add malformed-evidence tests before implementation. Preserve existing native gates.
- [x] Run full Core/Media/Streaming/tooling tests, both native suites, arm64_32 watchOS
  10 Core compile and combined unsigned iPhone/Watch Release. Obtain bounded source
  review, preserve evidence/hashes, update docs and commit verified changes.

Files: QualityController.swift and QualityTrialTests.swift in ScorebugCore;
PublishingTransportWindow.swift, PublishingTransportStatistics.swift and
PublishingTransportWindowTests.swift in ScorebugMedia; DualOutputSmoke.swift;
scripts/transport-interval-evidence.mjs, scripts/test/transport-interval-evidence.test.mjs,
scripts/test-dual-output.mjs; adaptive policy/telemetry and parent plan docs.

Commands use DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer:
`swift test --package-path ios/Packages/ScorebugCore`; analogous Media/Streaming;
`pnpm test:tools`; `pnpm test:dual-output`; `pnpm test:native-network`;
`swift build --package-path ios/Packages/ScorebugCore --scratch-path artifacts/qa/aligned-transport-watch-build --triple arm64_32-apple-watchos10.0 --sdk /Applications/Xcode-26.2.0.app/Contents/Developer/Platforms/WatchOS.platform/Developer/SDKs/WatchOS26.2.sdk`;
`xcodebuild -project ios/Scorebug.xcodeproj -scheme Scorebug -configuration Release -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build`.

Automatic quality control stays disabled pending remaining thermal/worker alignment,
receiver freshness/revision mapping and actual automatic media trials. Neither an
input timing allowance nor observed transport gauges qualify end-to-end behavior.

## Verified checkpoint

Core passes 274 tests, Media 229 (163 XCTest + 66 Swift Testing), Streaming 54,
and tooling 781. The arm64_32 watchOS 10 Core build and combined unsigned
Apple Watch/iPhone Release build pass. Independent source review approved the
change; its requested long-history query and gap/eviction oracle regressions pass.
The initial behavioral failures and intermediate compiler failure remain in evidence.

Native default `dual-output-jdR05o` and impaired-network `dual-output-dkaKxC` pass
all existing gates. All eight clean archives retain all 420 frames with qualified
A/V; normal, offset-clock, transparent and recoverable live outputs retain all 420.
Each of the five successful publishers retains 13 actual transport samples and
returns two bracketed historical source queries; the unbracketed startup query
remains unknown. Independent saved-evidence replay reproduces all five results.
Peak RSS is below 97 MiB against the unchanged 512 MiB budget. The overload stream
is deliberately unqualified: best-effort decoding finds 384 frames but invalid
source identities, so fresh-frame rate and loss remain null.

Logs, raw collections, media, review and replay results are retained under
`artifacts/qa/aligned-transport-*` and the two native run directories; the final
verification manifest records source and evidence SHA-256 hashes. These are local
fixture results, not physical phone/Watch or remote-host qualification. Thermal/
worker alignment, receiver freshness/configuration mapping and automatic trials
remain open. No automatic quality loop is enabled by this checkpoint.
