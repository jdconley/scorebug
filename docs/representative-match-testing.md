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

Next use the already validated native/SRT sender and receiver telemetry to
separate transport-tail loss from decoder flush, then repeat both resolutions
through SRT and RTMP. Retain the instrumented simulator clips for independent
frame identity, deadline, archive and adaptive-policy proofs. Real match footage
adds content realism; it does not replace those measurements.


## Native 1080p network and archive check passed

`network-native-aligned.mts` uses the existing `DualOutputSmoke` sender and
production native publishing/recording packages. Twelve seconds of the 1080p
match run in real time through native H.264/AAC encoding, loopback SRT, the actual
CPU proxy and score overlay, RTMP, and the independent MP4 recorder. A clean
segmented archive records in parallel and is exported by `ArchiveHarness`.

The prepared MOV has exactly 360 uniformly timed frames starting at zero, plus
48 kHz mono PCM. Audio/video timestamp origins are explicitly normalized during
fixture preparation, before the measurement boundary. This tests representative
content and the native media path, not preservation of the original recording's
camera timestamps, stereo layout or HDR metadata. The native harness uses its
existing 1080p profile and scheduled 2 Mbps bitrate change; the CPU proxy targets
1080p30 at 6 Mbps. It does not test automatic adaptation.

All 360 frames were submitted, encoded, decoded by the proxy, archived, and
present in the streamed output. The archive rejected no samples, the live queue
dropped/rejected none, and maximum source scheduling lag was 2.50 ms. Streamed
frame gaps were 33–34 ms; audio/video track starts differed by 2 ms. Both archive
and stream fully decoded without errors, and visual inspection confirmed the
match and expected score overlay. Evidence is in
`network-native-aligned-1080p-software/`, including the untouched raw native
events, recorder packet timings, result, full-decode results and preview.

Two preceding native fixture attempts remain failed and preserved. A direct TS
to MP4 remux introduced an empty leading edit interval that AVFoundation read
as an extra frame (361 native frames for 360 compressed frames). Disabling edit
lists removed that extra frame but produced a 56.6 ms first-frame interval in
the input itself. The aligned fixture corrects its input timeline; no output
frames or failed results were discarded to obtain a pass.

This establishes one short 1080p local native content check. It does not qualify
4K networking, long-match thermals, physical-device camera capture, archive crash
recovery or repeated adaptation. The previous file-sender and console-bridge
failures are unresolved for those adapters. A 4K network test must explicitly
configure a supported 4K sender/archive path; the existing native smoke harness
uses a fixed 1080p archive and must not silently label that output 4K.
