# Minimum live startup and first-frame evidence

Implement the approved low-start contract without delaying local recording or
adding a preflight bandwidth probe. Normal app publishing starts at 240p30;
explicit diagnostic fixtures keep their selected profiles. The generic library
profile default remains unchanged for existing qualification tools.

Add constant-size startup evidence joining the first native encoder completion
and first pre-mux H.264 sample by exact source PTS. Require the requested dimensions,
positive payload, sync metadata, matching output/source PTS and ordered monotonic
submission/completion/dequeue clocks. Record encoder session and publishing generation.
An invalid first sample never heals by observing a later convenient frame. No media
is retained. Close preserves historical evidence but prevents active admission.

Expose optional startup evidence through MediaPublisher/PublishingSession. The
progressive quality bootstrap must match its verified bitrate receipt to this actual
first-frame profile, generation and encoder; pending evidence must not establish
applied state. Existing legacy fixtures retain their explicit behavior. A failed
native binding retires publishing while the independently owned archive continues.

- [x] Write/run failing streaming tests for first-frame joins, mismatch, ordering,
      bounded ownership, closure and independent new publishing attempts.
- [x] Implement startup receipt/observer and wire native callbacks and session reads.
- [x] Write/run failing native bootstrap/default-selection tests; implement normal
      minimum-profile selection and progressive first-frame admission.
- [x] Verify Media/Streaming/Core and native model tests, simulator and unsigned
      iPhone/Watch builds. Record qualification limits and source/evidence hashes.
- [x] Commit the implementation and update the main plan.

Primary files: new ScorebugMedia/PublishingVideoStartup.swift and
ScorebugStreaming/PublishingVideoStartupOwner.swift; SRTPublisher.swift,
SRTMediaPublisher.swift, PublishingSession.swift, PublishingQualitySession.swift,
PublishingQualityDriver.swift, CaptureStreamingModel.swift and their package/model
tests. Use Xcode 26.2 with explicit DEVELOPER_DIR. Run heavy checks sequentially.
This receipt proves local first-frame encoding, not remote delivery or achieved bitrate.

## Implemented ownership and admission

Normal app connections now select `PublishingVideoProfile.minimumStartup` (240p30)
through the existing configure-before-start path. Each publishing/reconnect attempt
constructs a fresh adapter and first-frame observer. Explicit historical fixtures
still select their requested profile; generic library defaults remain unchanged.
The local archive is untouched and no network probe or initial quality ramp is added.

The observer retains at most one encoder callback, one compressed callback and one
immutable joined receipt. It requires exact rational source/output PTS, valid H.264
payload and sync metadata, requested dimensions, positive generation, and ordered
native clocks. Invalid first evidence remains invalid; later frames cannot repair
startup. Closing prevents new callbacks from changing evidence. Historical receipts
remain available for export, while PublishingSession exposes them only while running.

Progressive bootstrap requires that actual first-frame receipt before dispatching a
bitrate write, then matches the write's encoder identity, generation and submitted
source boundary. It also rejects a receipt that changes during the operation. The
quality driver permits at most two seconds of pending evidence after encoder-ready
admission; even a proof arriving exactly at the deadline cannot dispatch a late write.
Failure retires live publishing through existing joined stop ownership. Legacy fixture
bootstrap stays unchanged while automatic production adaptation remains gated.

Fresh fixed-profile native runs additionally export the first raw encoding and
compressed callback rows and the production adapter's startup receipt. The verifier
requires exact first source-frame identity, encoder identity, dimensions, generation,
H.264/sync/payload validity and all three clocks to reconcile. Historical format-only
replays keep their original contract. The observer's receipt is local encoding
proof; it does not establish achieved bitrate or remote first-frame delivery latency.

## Verification outcome

256 Media tests (190 XCTest + 66 Swift Testing), 87 Streaming tests, 342 Core tests,
238 native model tests and 1,206 tooling tests pass. The ARM64 simulator
build-for-testing and unsigned combined iPhone/Watch Release build pass. Missing API,
observer behavior, session forwarding, native bootstrap/default selection, late
proof admission and fixture reconciliation all had observed failing checks before
implementation. The late-proof regression ensures no native write can start at or
after the already-established two-second proof deadline.

Actual iPhone 14/iOS 17.5 simulator run `native-app-UwfiUF` passes the 90-second
structured-motion fixed240 SRT -> local proxy -> RTMP recording workflow. The very
first compressed frame is a valid 426x240 H.264 sync sample at source frame 159.
Its startup receipt exactly matches the independently exported raw native encoding
and compressed callback rows: encoder identity, generation, source/output PTS,
dimensions and submission/completion/dequeue times. All 3,381 compressed frames
cover source frames 159...3539 consecutively. The first pre-mux frame arrives
0.500781 seconds after publishing observation begins; 0.444605 seconds are within
the first encoder submission/completion interval. This is local encoding latency,
not a measurement of user tap to viewer playback or a statistical latency promise.

The saved live output has 3,348 consecutive frames 192...3539, after 33 measured
acquisition frames. The independent clean 1080p archive has 3,723 consecutive frames
0...3722. Both files fully decode with empty error logs; all 55 expected live and
61 archive audio markers are matched. Source-timeline cadence is approximately
30 fps, without claiming every arrival met a wall-clock deadline. The recorder,
worker encoder and worker exit with code zero. The test-owned simulator and relay
are cleaned up by the joined parent.

The independent first-frame/continuity verifier also rejects 14 damaged copies of
the actual startup evidence. Source inventory (755 paths), logs, actual run artifacts,
parent exits and source/evidence hashes are frozen in
`artifacts/qa/minimum-startup-final-verification.json`.

Limits: this real fixture explicitly selects the same minimum profile, while normal
app selection is covered by deterministic selection checks and both builds. It does
not qualify physical phone/radio behavior, automatic ramp/reset media transitions,
remote GPU workers, or device-specific minimum capability fallback. Automatic quality
activation still needs source-timed short delivery/watchdog admission, reaction-time
qualification and candidate-cost/headroom admission. Reconnect uses a fresh minimum
publisher by construction; a real forced-disconnect/reconnect run remains outstanding.
