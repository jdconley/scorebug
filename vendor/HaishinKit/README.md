# Scorebug's HaishinKit source subset

This directory contains the HaishinKit and SRTHaishinKit source modules from
[upstream 2.2.5](https://github.com/HaishinKit/HaishinKit.swift/tree/2.2.5), revision
`dc880cb540b8feeb98f64e8b7dcfaaf320b6b2bd`. The original BSD-3-Clause notice is in
`LICENSE.md`. `upstream-files.json` records the SHA-256 of every copied source/test
file before Scorebug modifications.
`scorebug.patch` is the diff against that revision for the 13 modified upstream
files and three added bounded publishing/bitrate source primitives. Original upstream hashes
remain unchanged. Added regression tests live alongside the SRT tests and in
`ScorebugPatchTests`. The patch was reconstructed from those original hashes,
then applied to a clean reconstructed baseline and compared byte for byte.

The local manifest includes only the modules used by Scorebug. Logboard remains
pinned to 2.6.0 and the original libsrt 1.5.4 binary URL/checksum is unchanged.
The C++ runtime is explicitly linked. Upstream RTMP, RTC, MoQT, examples, doc
plugins, and the large base-module test assets are omitted. SRT protocol tests
are retained except the upstream connection tests that launch unjoined tasks
on fixed ports. Scorebug's real network tests own and clean up their endpoints.

The native app also exposed an SRT URL parser defect: percent-encoded stream IDs
were sent literally and rejected by the relay. Query items now decode exactly
once through URLComponents; an encoded delimiter/passphrase regression covers it.

The local copy corrects the experimentally demonstrated startup media loss in
the TS writer and bounds the compressed publishing queues. Overflow, codec, and
transport failures terminate publishing explicitly. See
[the boundary contract](../../docs/sdk-publishing-bounds.md) for exact limits,
failure observation, task ownership, and qualification scope. The same upstream source on `main` at
`d8e71aa5f27cd2dbab90efcb5fb5909a6f800c3b` still contains the defect. See
[the evidence](../../docs/native-dual-output.md). Keep local changes small and
review them against the original hashes when updating the SDK.

`SRTStream(connection:encoderCompletionObserver:)` optionally accepts a synchronous
`@Sendable (CMTime, CMTime) -> Void` observer. Construction fixes the observer for
the stream and final drain; each compression submission captures only its input
PTS, observer, and output queue. Qualifying native callbacks notify before queue
admission, so later count/byte rejection does not erase encoding completion.
Only successful, non-dropped, ready single-sample compressed video with nonempty
data and numeric, positive-timescale, equal-epoch, rationally equal input/output
PTS qualifies. Diagnostic rejection preserves normal media delivery and failure
behavior. Decompression and compressed SRT passthrough never notify. Observers
must do bounded synchronous work, without per-frame tasks, I/O, or waits.

Verify the maintained patch without a network checkout:

```sh
python3 vendor/HaishinKit/verify-scorebug-patch.py
```

This reverses the patch in a temporary copy, verifies all 162 original SHA-256
hashes, reapplies it, and requires an exact byte-for-byte round trip.

Run focused protocol tests with Swift 6:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  swift test --package-path vendor/HaishinKit
```

The local deployment floor is iOS 17/macOS 13. The inherited libsrt binary still
does not link an Intel simulator executable; this Mac uses the ARM64 slice.

Verified live average-bitrate changes use `SRTStream.setVerifiedVideoBitRate` with
an active publishing-generation token. They require a ready raw-video encoder,
check native writes and readback of bitrate plus effective data-rate limits, and
commit settings only after verification. Uncertain native application fails live
publishing explicitly. A lock-protected invalidation revision preserves notifications
that overlap session creation or property writes. Configuration acknowledgment does
not identify a source-frame transition or prove achieved bitrate/capacity. See the
[implementation plan](../../docs/superpowers/plans/2026-09-15-verified-live-bitrate.md).
