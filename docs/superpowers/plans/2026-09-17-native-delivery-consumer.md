# Native incremental delivery consumer implementation plan

> Execute inline under the approved progressive-streaming plan; use failing regressions and independent review before freezing evidence.

**Goal:** Reconstruct authenticated incremental arrival reports on native clients and bind freshness to the current publishing attempt before subsequent source/deadline integration.

**Design:** Add a bounded Codable packet/tuple model and pure history reconstruction matching the TypeScript protocol. A native tracker binds history to game/generation, worker/epoch/attempt and the complete validated publication. Changes require a full base; retired bindings cannot resume within the same local publishing attempt. Missing, invalid or expired evidence cannot remain available as current evidence. Frozen samples preserve their earlier age proof; no new response may rejuvenate them. HTTP opt-in uses URLQueryItem and cache bypass, with validated cursor coordinates. The capture model requests and consumes reports only for its currently owned publisher, and clears current evidence when detached or expired. Scoring clients retain legacy status requests.

**Scope:** This supplies native ingestion and lifecycle ownership. A complete captured-source/configuration window and sender-to-decoder PTS projection are still required before invoking the deadline classifier or enabling automatic recovery.

- [x] Add failing Core packet tests covering actual wire shape, full/delta/overlap/retirement reconstruction, gaps, changed tuples and coverage, scope/clock/terminal failures, malformed data and numeric limits.
- [x] Implement `DecoderDeliveryPacket.swift` and `DecoderDeliveryHistory.swift`; use Int64 transport/ordinal values to support watchOS arm64_32, and bound arrays to 256 before materializing excess entries.
- [x] Add tracker/freshness tests for expected publication, server epoch/attempt changes, retired binding rejection, omission/resynchronization, frozen sample aging, request/residence, and overflow. Implement `WorkerDecoderDelivery.swift` without quality decisions.
- [x] Extend optional worker status metadata and HTTP query support; test legacy requests, exact version/cursor query, authorization header, cache bypass and invalid cursors.
- [x] Integrate the tracker into `CaptureStreamingModel` polling/expiry/detach. Add native model lifecycle regressions; make delayed responses obey existing local ownership checks.
- [x] Replay actual prior FFmpeg/HTTP packets through Swift with explicit fixture publication binding, compare exact reconstructed history and metrics, and retain that binding limitation. Run Core/model suites, simulator and unsigned iPhone/Watch Release builds.
- [x] Independently review and fix findings; update main plan, preserve previous evidence, freeze new source/evidence hashes and commit.


## Verified checkpoint

The native packet/history implementation matches the TypeScript delta protocol,
limits decoded tuples to 256, and keeps PTS/ordinals in Int64 for watchOS. Optional
malformed metadata becomes unknown without breaking ordinary status decoding. HTTP
requests remain unchanged for scoring clients; the capture publisher opts in with a
validated cursor and cache bypass.

The tracker binds complete history to game/generation, worker/epoch/attempt and the
validated publication, including ingress origin. Binding changes require a full
base and retire the prior context within the local publishing attempt. Omission,
expiry and failed evidence clear current availability while retaining reconstruction
state for anti-replay checks. Frozen samples cannot be rejuvenated, even when their
first report lacked an age bound. A self-review regression showed that rejecting a
retired reply must not permanently disable later current reports; this is fixed and
verified with a failing-then-passing test. Retired-context storage is bounded to 64;
exhausting it requires a new local publishing attempt.

CaptureStreamingModel now requests, consumes, expires and clears this evidence under
its existing publisher/recording/tap and asynchronous ownership guards. Its lifecycle
test covers cursor progression, omitted reports, full resynchronization, expiry and
detach while preserving the active publisher through telemetry omission.

The shared replay fixture preserves the exact 161 packets and 478 arrival tuples from
`incremental-delivery-native-r4qx4E`. Both TypeScript and Swift independently rebuild
every retained tuple and coverage boundary. A second Swift replay passes data through
the native HTTP client and freshness tracker using explicit synthetic publication
identity. The real epoch change rejects one partial-base reply; the fixture then
supplies a full resynchronization response constructed from recorded source rows.
160 replies are admitted, one requires resync, and the final bounded tail contains 256
arrivals through ordinal 478. This replay does not establish a physical publication
attachment or a phone-to-worker deadline. An independent fixture/provenance check
rejects five corrupted variants.

All 372 Core, 253 native model, 7 protocol and 1,272 tooling tests pass. ARM64 simulator
build-for-testing and unsigned combined iPhone/Watch Release builds pass. Independent
review found no remaining actionable issues. Source inventories, red/green tests,
replay provenance, joined process exits and previous-evidence integrity are frozen in
`artifacts/qa/native-delivery-final-verification.json`.

## Next integration

Build complete native capture/configuration windows and project each source PTS into
the bound decoder transport coordinates. Couple the classifier's result to the
current applied encoder receipt and delivery sample age. Qualify actual deadline
loss/floor decisions through the native simulator/relay path before connecting
recovery increases. Candidate headroom, reconnect, physical phone/Watch and remote
CPU/GPU/cloud gates remain open.
