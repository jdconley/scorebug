# Transport pressure windows implementation plan

> **For agentic workers:** Execute inline with test-driven steps and bounded independent
> review. Parent owns native/media/build execution in the validation worktree.

**Goal:** Carry bounded, fresh, attempt-scoped transport interval measurements through
publishing-session diagnostics, then verify the actual native output under impairment.

**Architecture:** Extend the existing statistics tracker with a fixed 64-sample ring.
Accepted actual collections produce rolling windows with real collection endpoints;
no interpolation of cumulative counters or extension beyond the last collection.
The session already owns this tracker. Existing media behavior remains fixed.

**Tech stack:** Swift value types/XCTest; native Mac SRT fixture; independent Node
integer and integration oracle; existing normal/archive media gates.

## Design and decisions

Using only the latest gauge misses pressure between polls. Treating SRT bandwidth or
send throughput as usable capacity contradicts the actual 3 Mbps overload trace.
Instead, preserve a small history and summarize what was observed. This closes the
transport-window prerequisite; it does not invent capacity or align transport
windows to worker source windows prematurely.

The latest window uses the oldest retained sample no more than five seconds before
the latest sample, and requires at least one second of duration. Every adjacent
collection gap must be at most two seconds. Longer gaps clear the ring and establish
a new baseline; nil/cached reads never manufacture samples or extend coverage.
A maximum of 64 samples bounds memory/work even with unusually frequent collections.
If eviction leaves less than one second of coverage, no window is available.

Window fields: publishingGeneration, start/end uptime, sampleCount, exact UInt64 sent
and retransmitted byte deltas, Int32 sender-drop delta, time-weighted observed mean
buffered bytes/buffer milliseconds/RTT, and maxima for those three gauges. Means use
the preceding sample held until the next actual collection. This is explicitly an
estimate from sampled gauges, not proof of unobserved instantaneous pressure. Maxima
include both endpoints. Normalize each interval weight by total duration and each gauge by its maximum before
multiplication so finite extreme RTT values do not overflow integral intermediates.
The final mean is clamped within the observed extrema only for floating-point roundoff.
No bandwidth, spare capacity, healthy state, or profile revision is inferred.

The existing tracker validates generation, clocks and counters before insertion.
A contradiction permanently quarantines the tracker and clears window availability;
last consistent scalar history remains for diagnostics. Closing retains historical
window values but freshWindow(at:maximumAge:) returns nil. Its freshness uses the
window end and the existing scalar freshness guard. New trackers start empty.

Public interface:
```swift
public struct PublishingTransportWindow: Equatable, Sendable {
    public let publishingGeneration: UInt64
    public let start: Double
    public let end: Double
    public let sampleCount: Int
    public let sentBytes: UInt64
    public let retransmittedBytes: UInt64
    public let droppedPackets: Int32
    public let meanBufferedBytes: Double
    public let meanBufferMilliseconds: Double
    public let meanRTTMilliseconds: Double
    public let maximumBufferedBytes: Int32
    public let maximumBufferMilliseconds: Int32
    public let maximumRTTMilliseconds: Double
}
// Added to PublishingTransportStatisticsSnapshot:
// public let window: PublishingTransportWindow?
// public func freshWindow(at uptime: Double, maximumAge: Double = 2)
//     -> PublishingTransportWindow?
```

## Task 1: Bounded pure windows

Files: new `ios/Packages/ScorebugMedia/Sources/ScorebugMedia/PublishingTransportWindow.swift`,
existing `PublishingTransportStatistics.swift`, new
`ios/Packages/ScorebugMedia/Tests/ScorebugMediaTests/PublishingTransportWindowTests.swift`.

- [x] Write tests and compile a nil-returning window stub; capture behavioral red.
  Nonuniform sample times 10, 11, 13 with gauges 100, 400, 0 must yield mean 300,
  not the arithmetic sample mean. Exact large counters must subtract before Double
  conversion. Cover duration boundaries, two-second gap, ring eviction, cached/nil
  reads, fresh/future/stale/closed, contradictions, and finite extreme RTTs.
- [x] Implement fixed-ring insertion only after scalar validation, reset on gaps,
  and bounded scanning for actual endpoints. Use exact counter subtraction and
  normalized left-hold weights. Run focused tests then the complete Media suite:
  ```sh
  DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path ios/Packages/ScorebugMedia
  ```

## Task 2: Session and native evidence

Files: existing `PublishingTransportStatisticsSessionTests.swift`,
`tools/media-sdk-probe/Sources/DualOutputSmoke/DualOutputSmoke.swift`,
`scripts/transport-statistics-evidence.mjs`, its tests, `scripts/test-dual-output.mjs`.

- [x] Extend the session test with an advancing sample; verify its window survives
  historical stop while fresh access closes. Existing late-getter test must pass.
- [x] In the native fixture's existing monitor, own one statistics tracker. Observe
  each actual sample and export the optional window alongside raw samples; serialize
  exact integer deltas as decimal strings. No new timer or capture work.
- [x] Write failing independent Node checks for exact endpoints, deltas, nonuniform
  weighted means, maxima, missing/unexpected windows, cached/gap handling and corrupted
  output. Reconstruct expected windows from raw collections, with explicit 64-sample
  and 1–5 second bounds. Exported window values cannot be their own oracle.
- [x] Run the oracle for transparent/recoverable and deliberate-overload paths; overload
  media remains separately unqualified. Preserve all existing media gates. Run
  `pnpm test:tools` and `pnpm test:native-network` with selected Xcode. Rebuild dependent
  Swift probe if SwiftPM's cached source discovery misses the new Media file.

## Task 3: Review and checkpoint

- [x] Run existing Streaming tests and the combined unsigned iPhone/Watch Release
  build to check public snapshot compatibility. Run original native scenarios if
  runner or fixture changes alter their shared path.
- [x] Independent bounded review; address reproduced issues, then document exact
  evidence and limitations, hash final source/evidence and commit verified changes.
- [x] Update `docs/adaptive-telemetry.md` and a transport-window runbook. Keep capacity,
  thermal/worker pressure, policy/source alignment, profile transitions and physical
  radio/Watch qualification explicitly open. Do not enable quality adaptation here.

## Verified checkpoint

Behavioral red: eight Swift tests failed against a compiled nil-window stub; the
Node oracle failed on missing/corrupt window acceptance before implementation.
Final suites pass Media 193 (138 XCTest + 55 Swift Testing), Streaming 44, and tooling
706 (27 transport evidence tests). Combined unsigned iPhone/Watch Release succeeds.
The initial Streaming build used a cached source list without the new Media file;
owned package clean/rebuild resolved discovery. The failed build log is retained.

Independent review approved exact arithmetic, actual endpoints, finite extreme
means, bounded ring behavior and session lifetime. Suggested completed-cache, nil
lease-expiry and moving-horizon oracle regressions were added and pass.

Final impaired evidence: `artifacts/qa/dual-output-voEU8h`, with 12 verified windows
per scenario. All archives retain 420 frames; transparent/recoverable live retain
420 each. Overload fails strict live decode and preserves complete recording.
Peak observed mean buffer duration is 1.997/19.503/143.054 ms across those paths;
these are fixture measurements, not pressure thresholds or capacity estimates.

Original scenario regression: `artifacts/qa/dual-output-p6zHTH`, all five pass.
Every archive retains 420 frames; both normal streams retain 420 and emit 12 verified
windows each. Frame, cadence, A/V, clock, bitrate, queue and cleanup gates remain.
Final source/evidence hashes:
`artifacts/qa/transport-window-final-verification.json`.

Remaining goal work includes usable video capacity with explicit overhead,
thermal/worker pressure, source/policy time alignment and applied-profile boundaries,
resolution/canvas transitions, sustained impairment/thermal testing, physical native
phone/watch radio workflows and other-host GPU/cloud qualification.
