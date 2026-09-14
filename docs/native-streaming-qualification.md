# Native streaming qualification

The native Film tab connects capture to the shared match, publishes through a local
SRT relay and worker, and keeps the clean local recording independent. The native
Score tab can score while capture runs. Automatic reconnection, adaptive profiles,
Watch UI/networking, and physical camera qualification remain subsequent work.

## Reproduce locally

```sh
export DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer
pnpm test:native-streaming
SCOREBUG_IOS_RUNTIME=18.5 pnpm test:native-streaming
SCOREBUG_IOS_RUNTIME=26.2 SCOREBUG_IOS_DEVICE_TYPE=iPhone-15 pnpm test:native-streaming
pnpm test:dual-output
```

The native harness owns a fresh Simulator, loopback control API, temporary MediaMTX
1.21.0 ingest and sink containers, and a VideoToolbox worker. It uses no ambient
output destination. The native UI joins capture, records, starts publishing, takes
over scoring and awards a point, stops streaming while recording continues, then
stops and exports the recording. Cleanup attempts all owned resources independently.

Both exported archive and worker sink MP4s are fully decoded. Source frame identities
detect duplicates, gaps and reorderings; frequency-coded audio markers independently
measure synchronization. The worker's saved score and changed overlay pixels verify
score propagation. Live source IDs must belong to the archive, and the archive must
extend at least 60 source frames beyond the live output after streaming stops.

Archive head/tail coverage and live tail coverage have a 100 ms budget. A worker
joining an existing two-second GOP may acquire audio before its first decodable
video keyframe, so acquisition audio lead has a separate 2.1-second bound. Steady
synchronization remains limited to 100 ms; fresh video must reach 24 fps with no more
than one percent missing source frames. The tests do not manufacture repeated frames
or trim output to conceal missing media.

## Passing production evidence

| Simulator           | Evidence directory  | Archive frames | Live frames | Live max A/V offset | Live tail offset |
| ------------------- | ------------------- | -------------: | ----------: | ------------------: | ---------------: |
| iPhone 14, iOS 17.5 | `native-app-mVkjDn` |          1,240 |         829 |            65.25 ms |         91.33 ms |
| iPhone 14, iOS 18.5 | `native-app-D1SAAI` |          1,307 |         895 |            65.92 ms |         21.33 ms |
| iPhone 15, iOS 26.2 | `native-app-RQWwPo` |          1,420 |         979 |            65.92 ms |          3.70 ms |

Evidence is under `artifacts/qa/`, including `results.json`, decoded media, UI test
results, and screenshots. All three runs pass the complete workflow and media gates:
30 fresh live fps, zero missing frames within the acquired live range, consecutive
archive frames from zero, and a visibly updated score overlay.

The final five-case Mac run, `dual-output-6FUFL0`, passes offline recording, normal
streaming, a nonzero source clock, a stalled receiver, and an unavailable receiver.
All archives retain 420 frames and 672,000 PCM samples with zero archive rejections.
Both normal live outputs retain frames 0–419 at 30 fresh fps and zero loss; measured
bitrate falls from approximately 6.1 to 2.0 Mbps while archive settings stay fixed.
Peak RSS is 97.5 MiB and maximum source scheduling lag is 11.2 ms. This run uses
production shutdown with no extra probe sleep after input ends.

An earlier stress run, `dual-output-vhcdqH`, retained the complete archive but failed
the unchanged 250 ms source-scheduling gate at 271.8 ms. Other build work was active;
that correlation does not prove the cause. The isolated rerun passed. Keep timing
qualification separate from concurrent compilers/media jobs and do not infer
arbitrary host-load tolerance from this short fixture.

## Fixes exercised by these runs

- Native grant URLs percent-encode stream IDs. SDK query parsing now decodes once;
  the old literal encoding caused MediaMTX rejection.
- Startup bursts overflowed the former socket queue. Direct awaited socket sends
  now apply bounded backpressure, with no second queued copy or sender task.
- Implicit FFmpeg synchronization duplicated initial video. Explicit VFR output
  and a timestamp-based frame cap preserve source cadence and acquisition gaps.
- SDK shutdown discarded pending encoded video. Graceful finish drains retained raw
  video, completes native encoding while compressed consumers run, and drains muxed
  output through libSRT acceptance before transport close.
- Native command/teardown races now use durable receipts and stop ownership,
  per-attempt identities, and teardown gates. Setup saves before joining; capture
  failures report interrupted recordings independently of streaming health.

Codec completion alone still failed the native tail gate. Temporary source and
relay diagnostics in `native-app-v5TDdM` showed that the encoder reached the last
admitted video PTS, while the relay and worker ended earlier. A 500 ms diagnostic
hold passed in `native-app-sFyoN6`. Those temporary instrumentation and relay-recording
changes were removed before the production runs above.

The production `SRTStopPolicy` uses a three-second total budget, fresh sender-buffer
observations, negotiated peer latency, and a configurable 500 ms downstream allowance.
Failure, unavailable statistics, cancellation, or deadline expiry still close and
join cleanup. Empty sender occupancy can also reflect overdue packet drops; elapsed
allowance is not an acknowledgment of remote application consumption. Other hosts
must qualify their allowance or use a future application acknowledgment. Native
VideoToolbox calls have no hard preemption deadline; the policy bounds intentional
waiting and keeps it off capture/archive queues. See [publishing lifecycle](native-publishing-session.md)
and [SDK bounds](sdk-publishing-bounds.md).

## Regression and portability scope

Core, Media, SDK, Streaming, and Film model suites pass 68, 89, 69, 13, and 37 tests.
Server, worker, tooling, and protocol suites pass 180, 81, 60, and 1 tests; TypeScript
checking passes. Separate spec and quality reviews approve the implementation.
The maintained vendor patch reverses/reapplies exactly and verifies 162 upstream
file hashes. Shared Core also compiles for arm64_32 watchOS 10.

The final offline regression (`native-app-Qn5rxG`, iOS 17.5) passes all three
workflows, including forced-termination recovery and two completely decoded exports
with consecutive frames from zero. Its maximum A/V end-coverage difference is
28.1 ms. The final Film model rerun passes all 37 tests, and the unsigned iPhone
Release build succeeds (`native-streaming-film-model-final.log` and
`native-streaming-release-iphone.log`). Device compilation does not qualify camera
or network behavior on hardware.

Five timestamp fixtures pass with host software encoding, host VideoToolbox, and
the existing FFmpeg 5.1.9 CPU container: 30 fps remains 30, 60 fps caps at 30,
25 fps remains 25, a missing-video interval remains a gap, and a long acquisition
lead preserves unique frames and the common A/V timeline. See [worker evidence](worker-timestamp-finalization.md).

Capture and live profiles remain fixed at 1080p30. These short local results do not
qualify higher resolutions, sustained thermal behavior, cellular handoff, Watch
operation, or workers on other machines. ARM64 Simulator linking is supported on
this Mac; the pinned SDK's Intel Simulator slice still lacks required SRT symbols.
