# Receiver probe accounting implementation plan

> Execute inline using the applied execution, test-driven-development and verification skills. Existing autonomous authorization covers this implementation and local verification.

**Goal:** Give each actual publishing-path bandwidth probe a verifiable identity and bounded pre-demux receiver accounting.

**Architecture:** Encode the versioned null-packet marker inside the sender's locked offer; observe those packets in the authenticated relay publisher's reader and expose independent snapshots on its private connection API. Preserve all media bytes, sender bounds, decoder behavior and connection lifecycle.

**Tech stack:** Swift 6/SRT, Go 1.26.1/MediaMTX 1.21.0, pinned vendored patches, existing native qualification harness.

- [x] Add Swift wire-vector and accepted-sequence regressions in `vendor/HaishinKit/SRTHaishinKit/Tests/SRT/SRTBandwidthProbeTests.swift`; fail on anonymous current padding. Implement `SRTProbeMessage.swift` with `encode(id:generation:sequence:bitRate:) -> Data`. Change `offer` to pass this owned message to its send closure; socket submission uses that argument. Update actual-byte assertions and run the full SDK suite.
- [x] Extract a new writable source tree from the verified pinned MediaMTX archive under `artifacts/qa/receiver-probe-source`; apply the current cumulative patch. Add `internal/servers/srt/probe_reader_test.go` regressions. Implement `probe_reader.go`: one partial packet, one attempt, monotonic counters/times, immutable copies, sticky invalidation. `Read` must return the underlying bytes/error unchanged.
- [x] Add `APISRTBandwidthProbe` in `internal/defs/api_srt.go` and a connection-owned observer in `internal/servers/srt/conn.go`. Wrap the publisher reader before initialization, expose only for publish state, and clear in deferred teardown. Extend actual publisher lifecycle tests with valid markers before/after media, copying and concurrent teardown checks. Run `go test` and `go test -race` for MPEG-TS/SRT/forward-SRT.
- [x] Rebuild both cumulative vendor patches from verified upstream sources. Update added-file inventories, patch hashes and README semantics. Verify exact forward/reverse reconstruction; build ARM64 simulator and combined iPhone/Watch Release outputs sequentially.
- [x] Build a separately tagged relay image, then integrate bounded authenticated snapshot collection and strict native accepted/delivered reconciliation into the existing fixture. Require exact publication/probe scope, live/recording/media gates, and joined cleanup. Preserve any failure rather than weakening gates.
- [x] Review source ownership, bounds and claims; document verified results and remaining production freshness/candidate-cost integration before committing the checkpoint.

**Commands:** `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path vendor/HaishinKit`; in the fresh patched relay tree, `go test ./internal/protocols/mpegts ./internal/servers/srt ./internal/forward/srt` and the same with `-race`; `python3 vendor/HaishinKit/verify-scorebug-patch.py`. Native runs retain the prior fixed540p, clean1080p, motion-blocks16 and scheduled4Mbps settings. No upgrade is admitted from this primitive alone.

## Verification

The original socket test fails on anonymous payload bytes. The marked sender passes all 199 SDK tests, including an independently specified byte vector, accepted-sequence progression and the complete actual socket message. The streaming adapter passes all 70 tests.

The pre-demux reader passes fragmentation, byte/error preservation, identity/order/malformed-input, fixed-budget, clock and concurrent-copy tests. Actual publisher lifecycle tests fail before observer integration and pass afterward; MPEG-TS, SRT and forward-SRT suites also pass the Go race detector. Upstream verification checks 162 SDK originals and an exact relay patch round trip over 25 source files. The separately tagged `scorebug/ingest:receiver-probe-v1` image builds successfully.

The native harness now captures bounded receiver snapshots only after verifying the signed publishing attempt and authenticating the private API. Offline qualification matches native/relay/probe scopes, complete accepted/delivered counts and request/response clock bounds. Review exposed three impossible receiver transitions; regressions reproduced them and the verifier now rejects disappearing partial packets and deliveries timestamped before the prior observation. All 1,139 tooling tests pass. ARM64 simulator test build and unsigned combined iPhone/Watch Release build pass. Native pressure qualification passes as `native-app-IK5Ns7` against the exact image and 682-file runtime/harness inventory in `artifacts/qa/receiver-probe-runtime-source.json`. Counts/times still measure pre-demux reads, not exact network arrival or usable capacity.

## Actual receiver-attributed pressure result

`native-app-IK5Ns7` passes on iOS 17.5 with the captured relay image and runtime/harness sources. The native sender renews 397 times and accepts 3,693 messages / 4,859,988 payload bytes over 40.491258 seconds, then withdraws with `transportPressure`. Its accounted average is 0.992309 Mbps against the requested 1 Mbps; media continues another 141.155 seconds. The exact pressure threshold is not established by the reason-only snapshot.

All **3,693 messages / 4,859,988 bytes arrive at the relay before demux**, with no pending packet or invalid proof. The 360 authenticated snapshots match the native publishing attempt, relay connection, probe UUID, generation and rate. The first-to-last completed-read interval is 40.479567 seconds; excluding the first message from that interval yields 0.960222 Mbps delivered payload / 0.992327 Mbps accounted load. A single clock offset fits every measured request/response envelope within a 0.501064 ms intersection. These are bounded local clock observations, not a guarantee of constant clock offset on arbitrary remote hosts or exact network-arrival timestamps.

The independent clean recording preserves all 6,387 consecutive 1080p30 frames and 106 expected audio markers (+5.333 ms A/V end offset). Fixed540p live preserves all 6,010 consecutive retained identities (192–6201), all 100 audio markers and +39.494 ms end offset. Its 40 startup acquisition frames remain separate. Every reported receiver window meets 30 fps; both full MP4 decode logs are empty.

The applied 4 Mbps phase lasts 60,000.357 ms and forwards 29,155,936 wire bytes within its ceiling. Recovery traffic continues at least 60 seconds afterward. The proxy drops nothing and reconciles all directional timeline counters, with 96.720 ms maximum forward residence. The native parent exits zero; worker/recorder/collector/proxy owners terminate and join. Archive state is finished without a first failure.

`verify-receiver-probe-native.py` independently reconstructs saved media identities and receiver counters/timing from the raw observations, checks the image/runtime hashes and confirms the reported receiver summary. The unchanged control passes and 13 mutated copies fail, including receiver count, scope, clock, partial-message and causal-timestamp damage. Final source/evidence hashes are in `artifacts/qa/receiver-probe-final-verification.json`.

**Next:** carry fresh authenticated receiver intervals through production status and native policy, compare delivered additional load with measured candidate encoder/transport cost, and support bounded repeat/stage identities before quality-upgrade admission. This primitive retains one attempt per connection under the current sender contract; it does not yet implement repeated capacity probing. Adaptation remains disabled. Physical phone capture/thermal/storage, Watch route handoffs, other worker hosts and sustained soaks remain open.
