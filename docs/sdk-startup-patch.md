# Native SDK startup correction

The compatibility experiment exposed variable loss of the first AAC packets and
independent audio/video timestamp rebasing in upstream HaishinKit 2.2.5. Comparing
decoded PCM proved that the lost audio was at startup. The same TS writer was
present on upstream `main` at `d8e71aa5f27cd2dbab90efcb5fb5909a6f800c3b`.
See the [original measurements](native-dual-output.md).

Scorebug now keeps a [local source subset](../vendor/HaishinKit/README.md), retaining
the upstream license, revision, and original file hashes. It includes the base
and SRT modules needed by the probe, with the same checksummed libsrt binary and
an exact Logboard version. The initial startup correction changed three SDK files;
the subsequent [publishing queue changes](sdk-publishing-bounds.md) extend this patch:

- `TSWriter` copies compressed startup payloads until every expected track has
  supplied actual media. Startup is limited to 256 packets, 8 MiB of owned PES
  data, and a two-second media timestamp span. A violated limit or invalid input
  latches an error and discards queued startup data. Both tracks then share the
  earliest PTS/DTS origin, with the same transport lead applied to PTS and DTS.
- `SRTStream.publish` establishes its asynchronous stream subscriptions before
  returning. Its `muxerError` property exposes a failed startup to the caller;
  the probe treats that as publishing failure while recording continues separately.
- `VideoCodec` represents the absence of a previous frame explicitly. A first
  frame at timestamp zero is accepted, including after restart. Subsequent frame
  ordering, duplicate rejection, and frame-rate limiting are retained.

The PCM adapter also preserves both host time and PCM sample time. Sample time
uses the PCM format's sample rate, independently of the source CMTime timescale.
Tests cover a 123.25-second timestamp expressed at 1 kHz and zero-origin input.
Invalid or unrepresentable source times are rejected before unsigned conversion.

## Validation

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
swift test --package-path vendor/HaishinKit
swift test --package-path tools/media-sdk-probe
pnpm test:dual-output
```

The vendor suite has 35 tests, including copied-payload retention, audio-first and
video-first arrival, distinct first-track timestamps, decoded PTS/DTS spacing,
startup limits, reset, malformed input, and native VideoToolbox startup/restart.
The probe has three PCM clock-conversion tests.

The real-media runner checks offline recording, normal SRT with zero-origin input,
normal SRT with a 123.25-second origin at a nanosecond timescale, a stalled receiver,
and an absent receiver. The normal fixture must retain its first video sample.
Archive exports must start promptly and have the fixture's duration, excluding
the source clock origin. Existing source identities, decoded audio coverage,
synchronization, cadence, queue bounds, and measured bitrate-change gates remain.

The five-case run `artifacts/qa/dual-output-nHltS0/results.json` passes. Both normal
streams retain all 420 frames at 30 fps with no fresh-frame loss; maximum measured
A/V offset is 65.38 ms. All five clean archives retain 420 frames and complete audio.
Peak process RSS is below 95 MiB. These short Mac results retain the original 100 ms
audio coverage and synchronization gates. The 35 vendor tests and three PCM tests
pass, as do full ARM64 Simulator and unsigned iPhone executable links with iOS 17
deployment using Xcode 26.2.

## Remaining boundaries

The startup span is a media-time limit. A wall-clock watchdog for a capture source
that stops producing entirely belongs in the production publishing coordinator.
The SDK's later transport queues now have [separate limits and failure handling](sdk-publishing-bounds.md);
sustained congestion/reconnect qualification remains. Neither patch establishes a bound for every SDK allocation. No destination,
phone camera, or watch runtime is qualified by these source-level fixes.
