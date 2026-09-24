# Representative volleyball footage

The user supplied two private recordings in Downloads for local testing. The
originals are read-only test inputs and are not committed or uploaded. Metadata,
SHA-256 fingerprints, derived excerpts, commands, logs and results are saved in
`artifacts/qa/match-footage-n6n1f13m/`.

| Source | Video | Audio | Duration |
| --- | --- | --- | --- |
| `76865e1f-bcca-43de-9fff-4a27b2dd5b92.MP4` | 1920×1080 HEVC Main, approximately 30 fps, SDR | AAC-LC stereo, 44.1 kHz | 3018.145 s |
| `IMG_4729.MOV` | 3840×2160 HEVC Main 10, approximately 60 fps, HLG/BT.2020 HDR | AAC-LC stereo, 48 kHz; additional audio/data tracks | 1828.992 s |

## First content checks, 2026-09-23

`prepare.py` extracts twelve seconds starting at 600 seconds, selects the video
and first AAC track, and prepares 30 fps H.264 High/AAC MPEG-TS at the original
raster size. The 4K input is tone-mapped to SDR BT.709. This preprocessing is
explicit fixture preparation, not a claim of native HDR capture support or a
measurement of the phone encoder. The source frame rate conversion is also
intentional and precedes the 360-frame test boundary. FFmpeg's
[tone mapping documentation](https://ffmpeg.org/ffmpeg-filters.html#tonemap)
describes the linear-light conversion used by the preparation filter.

`benchmark.mts` uses the real proxy `buildFfmpegArgs` implementation, including
its score overlay, timestamp handling, frame cap and encoder settings. It decodes
the resulting file independently and checks dimensions, codecs, frame counts,
monotonic frame times and audio/video start alignment.

| Input | Proxy encoder | Decoded/output frames | Processing rate including startup | Result |
| --- | --- | --- | --- | --- |
| 1080p30 | CPU/libx264 | 360 / 360 | 512.3 frames/s | Pass |
| 1080p30 | VideoToolbox | 360 / 360 | 201.6 frames/s | Pass |
| 4K30 | CPU/libx264 | 360 / 360 | 123.8 frames/s | Pass |
| 4K30 | VideoToolbox | 360 / 360 | 57.6 frames/s | Pass |

All four outputs had maximum frame gaps of about 34 ms and audio/video start
differences under 100 ms. Output targets were 6 Mbps for 1080p and 24 Mbps for
4K. Preview frames show the expected footage and test score overlay. These short
local processing measurements do not establish sustained thermal performance,
network capacity, native archive durability or production upgrade permission.

## Initial file-sender network failures

The first real-time replay sent the 1080p excerpt as MPEG-TS over loopback SRT,
through the actual proxy CPU encoder and overlay, then over RTMP to the existing
independent MP4 recorder. Sender, proxy and recorder exited, but only 355 of 360
frames reached the decoder and output. The completeness assertion failed. The
received frames had regular timing and a 46 ms audio/video start difference.
Original failure evidence is in `network-1080p-software/` and `network.mts`.

A diagnostic using `srt-live-transmit` to keep the socket open until receiver
progress completed also failed. It reported only 343 decoded frames before the
bounded close deadline, then 360 after teardown, and emitted corruption warnings.
Its evidence is in `network-drained-1080p-software/`. That adapter is not accepted
as a fixture or used to qualify the application. Neither attempt ran the planned
4K network case after its first failure.

An upstream [SRT live-close issue](https://github.com/Haivision/srt/issues/2760)
describes buffered receiver delivery stopping at socket closure. This is a
plausible contributor to the first result, not a proven complete diagnosis.
The first receiver's 355 decoded PTS values are contiguous, and its output count
matches that decoder count: the shortage is at the tail, upstream of the overlay
output. The second diagnostic used the `srt-live-transmit file://con` bridge that
`scripts/test-relay-clock.mjs` already avoids because ConsoleSource short-read
padding can corrupt the byte stream. Its final 360 count appears during failure
cleanup after the pre-close assertion; it is not successful live drain evidence.
Decoder buffering and transport shutdown still need separate measurement. Do not lower the 360-frame requirement or reclassify either
failure as a passing end-to-end test.

The next investigation used the validated native/SRT sender, as described below.
At that point, 4K networking remained untested; the explicit native checks appear below. Retain the instrumented simulator clips for independent
frame identity, deadline, archive and adaptive-policy proofs. Real match footage
adds content realism; it does not replace those measurements.


## Native 1080p network and archive checks passed

`network-native-aligned.mts` uses the existing `DualOutputSmoke` sender and
production native publishing/recording packages. Twelve seconds of the 1080p
match run in real time through native H.264/AAC encoding, loopback SRT, the actual
CPU or macOS VideoToolbox proxy and score overlay, RTMP, and the independent
MP4 recorder. Separate runs verified both encoders. These cases use a direct SRT listener
and bypass the MediaMTX publication relay, so they do not qualify relay reader
attachment or its startup audio coverage. A clean segmented archive records in
parallel and is exported by `ArchiveHarness`.

The prepared MOV has exactly 360 uniformly timed frames starting at zero, plus
48 kHz mono PCM. Audio/video timestamp origins are explicitly normalized during
fixture preparation, before the measurement boundary. This tests representative
content and the native media path, not preservation of the original recording's
camera timestamps, stereo layout or HDR metadata. The native harness uses its
existing 1080p profile and scheduled 2 Mbps bitrate change; both proxy encoders target
1080p30 at 6 Mbps. It does not test automatic adaptation.

All 360 frames were submitted, encoded, decoded by the proxy, archived, and
present in the streamed output. The archive rejected no samples, the live queue
dropped/rejected none, and maximum source scheduling lag was 2.50 ms (CPU proxy) and 4.74 ms
(VideoToolbox proxy). Streamed
frame gaps were 33–34 ms; audio/video track starts differed by 2 ms. Both archive
and stream fully decoded without errors, and visual inspection confirmed the
match and expected score overlay. Evidence is in
`network-native-aligned-1080p-software/` and
`network-native-aligned-1080p-videotoolbox/`, including the untouched raw native
events, recorder packet timings, result, full-decode results and preview.

A separate real-audio correlation diagnostic compares one-second windows at
1, 5 and 9 seconds against the normalized PCM fixture. Both clean archives
match with zero measured lag and correlation above 0.999. Both streamed outputs
show a consistent 67.25 ms decoded-audio lag (correlation above 0.965), with no
measured drift across those windows; output audio durations differ by less than
29 ms. These meet the existing 100 ms diagnostic tolerance. The 2 ms track-start
difference alone is therefore not evidence of 2 ms content synchronization.
See `native-network-audio-correlation.json` and `audio-correlation.py`.

Two preceding native fixture attempts remain failed and preserved. A direct TS
to MP4 remux introduced an empty leading edit interval that AVFoundation read
as an extra frame (361 native frames for 360 compressed frames). Disabling edit
lists removed that extra frame but produced a 56.6 ms first-frame interval in
the input itself. The aligned fixture corrects its input timeline; no output
frames or failed results were discarded to obtain a pass.

These establish short 1080p local native content checks with both proxy encoders.
They do not qualify long-match thermals, physical-device camera capture, archive crash
recovery or repeated adaptation. The previous file-sender and console-bridge
failures are unresolved for those adapters. The explicit 4K experiment below
extends resolution coverage without changing these historical results.

## Explicit native 4K checks — September 24

`DualOutputSmoke` now accepts an optional fifth argument, `2160p30`, after the
existing timestamp offset. It selects actual 3840×2160/30 native H.264 publishing
and an independent 4K H.264/AAC archive at 24 Mbps. Default invocations still use
1080p; app startup remains 240p and the phone debug fixture rejects unqualified
4K live/candidate selections. The qualification tool bounds raw queues at 48 MiB
live / 96 MiB archive (8/24 items), excluding in-flight samples and codec internals.

Example after building the tool, using an owned loopback SRT listener and an
unused archive directory:

```sh
tools/media-sdk-probe/.build/debug/DualOutputSmoke \
  "$MATCH_FIXTURE" "$ARCHIVE_DIRECTORY" \
  'srt://127.0.0.1:19000?mode=caller&latency=120&conntimeo=1500&sndtimeo=200&peeridletimeo=2000' \
  0 2160p30
```

The new private `4k-native-aligned-source.mov` has 360 uniform frames and zero
track origins. It comes from the existing tone-mapped 12-second 4K excerpt at
600 seconds into the original. Its 30 fps SDR / mono 48 kHz PCM normalization is
explicit; this does not qualify native HDR/60 fps or original camera timing.
Original Downloads files were not modified or uploaded.

A complete CPU → VideoToolbox sequence passed on source `b998b5f`, with all 1,148
tracked file hashes unchanged during the run. Each case captured, submitted,
encoded, archived, decoded in the proxy and delivered all 360 frames. Both MP4s
are 3840×2160 H.264/AAC and fully decode. There were no live drops/rejections or
archive rejections. Stream gaps were 33–34 ms; track starts differed by 2 ms.
Maximum source scheduling lag was 2.520 ms (CPU) and 2.351 ms (VideoToolbox).
Evidence: `network-native-warm-4k-software/` and
`network-native-warm-4k-videotoolbox/`, run by `network-native-4k-warm.mts`.

The requested startup setting is 24 Mbps. A scheduled write at five seconds
changes live encoding to 8 Mbps: all 210 later frames match the accepted receipt
ID, encoder session and bitrate. The first 150 frames have no verified-write
receipt by design. Neither requested nor accepted bitrate proves achieved bitrate,
and this deterministic experiment does not exercise automatic adaptation.

`native-4k-warm-audio-correlation.json` compares one-second windows at 1/5/9
seconds. Both archives match with zero measured lag and correlation >0.9995;
both streams have stable 67.25 ms lag and correlation >0.9856. Archive/audio length
difference is 9.375 ms; live is 28 ms. Earlier successful CPU and diagnostic
VideoToolbox runs have the same results. Visual previews of those runs show the
expected clean court image and live-only score overlay.

**Intermittent failure remains open.** The first VideoToolbox case following a
CPU case (`network-native-aligned-v2-4k-videotoolbox/`, source `072685e`) stopped
native publishing after roughly three seconds / 84 proxy-decoded frames. Its
independent archive still retained all 360 frames with zero archive rejection.
Final live counters show six dropped and 286 rejected samples. Existing
boolean health could not identify the failed boundary. A new optional diagnostic
records the first observed unhealthy connection/stream/muxer/transport state;
it changes no settings, queue limits or retry behavior. A standalone diagnostic
VideoToolbox run and the repeated CPU → VideoToolbox sequence both passed without
reproducing it. This is not a resolved failure or general reliability qualification.

An earlier CPU run failed only a runner assertion that incorrectly required a
verified startup bitrate receipt; its media and raw evidence remain preserved.
The corrected assertion follows the existing codec contract and checks every
post-write frame against the exact receipt using source timestamps.

These are short direct-loopback SRT → production proxy → RTMP checks. They bypass
MediaMTX and do not qualify impaired networks, relay startup, full matches,
phone hardware/thermals or production 4K adaptive eligibility. See the
[native 4K plan](superpowers/plans/2026-09-24-native-4k-match.md).


## Transport isolation regression, 2026-09-24

Four-phase socket/worker observations plus native submission timing establish that
synchronous video conversion can monopolize the shared stream actor. One failed
case has 49.301 ms of conversion inside a 50.357 ms transport resumption delay,
while the socket interval is 0.014 ms. The reviewed transport fix in `582a339`
moves the sole FIFO consumer to its own worker and preserves bounded queues,
publication ownership, failure handling and probe revocation.

The first new 4K case (`network-native-pump-1-4k-videotoolbox`) fails later at the
64-item audio codec queue. The six-case campaign stops immediately; no remaining
cases run. All 1,153 tracked source hashes are unchanged. Its 619 sends have complete
four-phase brackets, maximum total send time 0.908333 ms, and at most two observed
pending muxed payloads. There are 260 native submission/completion observations,
253 proxy-decoded frames and a maximum synchronous conversion of 64.748792 ms.
Conversion occupies about 98% of the final four seconds, leaving other stream-actor
consumers at risk of starvation. Actual hardware encoder selection is unmeasured.

The independent archive still preserves every one of its 360 frames and 576,000
audio samples, in eight segments with zero archive rejection. Live drops 13 samples
and rejects 69 after failure. Both owned ports are released. This is evidence of
recording independence and improved transport scheduling, not a complete 4K pass.
The next native design isolates one immutable video submission operation while
keeping configuration writes, retirement and accepted-tail ownership explicit.

The same source passes 297 vendor / 170 Streaming / 10 clean SDKProbe / 499 native
model tests and simulator build. Its separate repeated adaptive simulator route
`native-app-gN2v2o` fails before the second probe starts, despite a passing UI
workflow and first minimum reset. That readiness regression is being investigated;
the prior complete adaptive pass on `89926f4` does not qualify the newer source.
