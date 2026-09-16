# Receiver probe accounting implementation plan

> Execute inline using the applied execution, test-driven-development and verification skills. Existing autonomous authorization covers this implementation and local verification.

**Goal:** Give each actual publishing-path bandwidth probe a verifiable identity and bounded pre-demux receiver accounting.

**Architecture:** Encode the versioned null-packet marker inside the sender's locked offer; observe those packets in the authenticated relay publisher's reader and expose independent snapshots on its private connection API. Preserve all media bytes, sender bounds, decoder behavior and connection lifecycle.

**Tech stack:** Swift 6/SRT, Go 1.26.1/MediaMTX 1.21.0, pinned vendored patches, existing native qualification harness.

- [ ] Add Swift wire-vector and accepted-sequence regressions in `vendor/HaishinKit/SRTHaishinKit/Tests/SRT/SRTBandwidthProbeTests.swift`; fail on anonymous current padding. Implement `SRTProbeMessage.swift` with `encode(id:generation:sequence:bitRate:) -> Data`. Change `offer` to pass this owned message to its send closure; socket submission uses that argument. Update actual-byte assertions and run the full SDK suite.
- [ ] Extract a new writable source tree from the verified pinned MediaMTX archive under `artifacts/qa/receiver-probe-source`; apply the current cumulative patch. Add `internal/servers/srt/probe_reader_test.go` regressions. Implement `probe_reader.go`: one partial packet, one attempt, monotonic counters/times, immutable copies, sticky invalidation. `Read` must return the underlying bytes/error unchanged.
- [ ] Add `APISRTBandwidthProbe` in `internal/defs/api_srt.go` and a connection-owned observer in `internal/servers/srt/conn.go`. Wrap the publisher reader before initialization, expose only for publish state, and clear in deferred teardown. Extend actual publisher lifecycle tests with valid markers before/after media, copying and concurrent teardown checks. Run `go test` and `go test -race` for MPEG-TS/SRT/forward-SRT.
- [ ] Rebuild both cumulative vendor patches from verified upstream sources. Update added-file inventories, patch hashes and README semantics. Verify exact forward/reverse reconstruction; build ARM64 simulator and combined iPhone/Watch Release outputs sequentially.
- [ ] Build a separately tagged relay image, then integrate bounded authenticated snapshot collection and strict native accepted/delivered reconciliation into the existing fixture. Require exact publication/probe scope, live/recording/media gates, and joined cleanup. Preserve any failure rather than weakening gates.
- [ ] Review source ownership, bounds and claims; document verified results and remaining production freshness/candidate-cost integration before committing the checkpoint.

**Commands:** `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path vendor/HaishinKit`; in the fresh patched relay tree, `go test ./internal/protocols/mpegts ./internal/servers/srt ./internal/forward/srt` and the same with `-race`; `python3 vendor/HaishinKit/verify-scorebug-patch.py`. Native runs retain the prior fixed540p, clean1080p, motion-blocks16 and scheduled4Mbps settings. No upgrade is admitted from this primitive alone.
