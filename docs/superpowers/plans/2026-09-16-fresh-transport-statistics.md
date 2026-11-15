# Fresh transport statistics for native quality decisions

> Execute inline under the existing autonomous goal, using the debugging,
> test-driven-development and executing-plans workflow.

**Goal:** Test whether actual 250 ms statistics collection reduces initial packet
damage while preserving the independent archive and all live qualification gates.

**Evidence:** `native-app-HAW17U` completed with faster local rollback but a 5 fps
initial receiver window. SDK sampling was about once per second despite a 250 ms
app health loop. The first retransmission-bearing sample arrived after congestion
had grown for over a second. Sampling delay is a concrete contributor; resolving
it is not a claim that the unchanged thresholds will protect media.

**Design:** Add `SRTConnection.samplePerformanceData()` as an explicit demand read.
The socket collects native statistics synchronously on its actor with `clear=0`,
so demand reads cannot reset the existing one-second monitor's interval counters.
The monitor retains its cadence, throughput calculation and `clear=1` behavior.
Cached `performanceData` remains cached. Collection timestamps are taken before
the native call, failures invalidate freshness without committing partial output,
and closed/cancelled/replaced connection work returns nil. The app's existing
250 ms health loop calls the fresh API; no new timer or unowned task is added.
History remains bounded to 64 samples (about 16 seconds, still covering five-second
receiver windows). All decision durations, thresholds, adaptation and media gates
are unchanged. Native sampler injection at the existing socket boundary allows
exact failure/counter and close-race tests; production defaults to libSRT.

Alternatives considered: speeding the shared bandwidth monitor would also require
changing its per-second byte arithmetic and queue trend semantics; lowering
thresholds would confound sampling with a distinct policy experiment. Use the
explicit demand read first.

- [x] Add deterministic SDK tests proving demand reads collect without clearing
      counters, cache reads retain collection time, failures/closed sockets return
      no fresh sample, and close/cancellation cannot publish a delayed snapshot.
      Run with a cached-read scaffold to reproduce missing native collection.
- [x] Implement socket sampling and connection generation guards. Change only
      `SRTPublisher.transportStatistics()` to request fresh statistics. Keep generic
      metrics reads cached and update its drain comment.
- [x] Run focused then full SDK and streaming suites using Xcode 26.2. Regenerate
      the maintained SDK patch from the verified HEAD upstream baseline; run
      `python3 vendor/HaishinKit/verify-scorebug-patch.py`.
- [x] Run the unsigned combined iPhone/Watch Release build and read-only review.
- [x] Repeat exactly the 240-second native `rate4m` pressure fixture. Preserve
      source hashes before launch, sanitized owned receiver diagnostics and stopped
      QA evidence. Verify actual sampling cadence, raw pressure, native receipts,
      the independent archive, and full live media with unchanged gates.
- [x] Record scoped results, clean up owned resources, hash terminal evidence and
      commit. If media still fails, use fresh samples to evaluate thresholds or
      recovery backlog separately. Keep production adaptation disabled.

Validation commands use `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer`:
`swift test --package-path vendor/HaishinKit`,
`swift test --package-path ios/Packages/ScorebugStreaming`, and the existing combined
Release build. Native fixture: `SCOREBUG_TEST_RELAY_PUBLICATION=1
SCOREBUG_TEST_WORKER_PROCESSING=1 SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1
SCOREBUG_TEST_MOTION_FIXTURE=blocks16 SCOREBUG_TEST_STREAM_HOLD_SECONDS=240
SCOREBUG_TEST_NATIVE_QUALITY=1 SCOREBUG_TEST_NATIVE_CONFIRMATION=1
SCOREBUG_TEST_UPLINK_PROFILE=rate4m SCOREBUG_TEST_ADAPTIVE_PROFILES=1
pnpm test:native-streaming`.

## Verified checkpoint

The cached-read scaffold reproduced all missing demand-collection and lifecycle
behaviors. The final seven statistics tests pass, including two in-flight native
read cases (close and cancellation). All 159 SDK tests, all 61 streaming tests,
unsigned combined iPhone/Watch Release build and read-only review pass. The
maintained patch exactly round-trips all 162 original upstream file hashes.

The unchanged native run `native-app-KyNaNh` completes the UI workflow and normally
stops. Its 1000 distinct retained transport observations have a median interval of
254.81 ms, 90th percentile 264.79 ms and maximum 266.88 ms. These are genuine native
collection timestamps, not refreshed cache times. Nine one-second local pressure
windows independently replay, and all four native profile-change receipts bind to
the actual encoder sessions. First higher-trial rollback completes 1.696 seconds
after its acknowledgment, versus 2.532 seconds previously. The initial decrease
still acknowledges at 61.569 seconds, almost unchanged from 61.656 seconds.

The archive independently passes: all 8168 consecutive 1080p/30 frames over
272.267 seconds, all 136 A/V markers, 9.33 ms end coverage difference, no archive
rejected/dropped samples. Native publishing records 7829 consecutive source frames
across five resolution phases. The recorder has 7627 frames spanning 7769 source
positions after the explicit 60-frame acquisition, a 142-frame count deficit
(1.828%), plus 55 non-increasing decoded barcodes. Count deficit is not complete
source-identity loss qualification.

Live coverage now passes with a -47.82 ms end difference under the same 100 ms
budget and existing acquisition allowance. Full qualification still fails the
strict monotonic frame-marker check; the worst five-second receiver window is
15.2 fps, below the required 24 fps. Audio PTS gaps total 65.17 ms, maximum 21.66 ms.
The pressure schedule passes, with 2366 overflow packets. One SRT reader remains
connected, recovers its timing after second-trial damage and closes at normal stop.
These single-run observations show improved rollback and measured media outcomes,
not proof of robust adaptation. Production adaptation stays disabled.

Fresh samples isolate the next question. At bootstrap offsets 60.211/60.463/60.725
seconds, sender buffers were 82/139/202 ms and RTTs 201/270/385 ms. No retransmissions
were present. Retransmissions appear at 60.992 seconds; local pressure evaluates at
61.105 seconds. The unchanged 500 ms gauge thresholds and 1% retransmission rule
therefore act after substantial buildup despite the faster sampling.

Source inspection finds no explicit latency in the native publish grant, and the
pinned MediaMTX/gosrt receiver defaults to 120 ms. This is source evidence, not a
measurement of the negotiated value in this run. Next retain the actual negotiated
sender delivery delay (`msSndTsbPdDelay` or `peerlatency`) and compare pressure timing
to that recovery budget. Then isolate earlier pressure thresholds or a deliberate
recovery latency, keeping only one variable per native experiment. Do not claim
that a default or a configured delay was the measured connection value.

The owned runner/analysis are terminal and joined, simulator/container are absent,
and status collector is stopped. Exact source snapshot, sanitized diagnostics,
independent archive/live analysis and cleanup are retained under the run directory.
Hashes are in `artifacts/qa/fresh-statistics-final-verification.json`. The full
policy verifier is not supplied fabricated passing profile evidence after the real
frame-identity gate fails. Other-device/host tests, longer soaks and reconnectable
destination recording remain open.
