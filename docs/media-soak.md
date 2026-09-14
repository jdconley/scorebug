# Local sustained worker qualification

Run either encoder against its own temporary API, SRT relay, synthetic publisher,
and local RTMP sink:

```sh
pnpm test:worker software --soak-seconds=600
pnpm test:worker videotoolbox --soak-seconds=600
```

The default command without this option retains the short fault/recovery workflow.
The optional duration accepts 12–1200 seconds. CI uses 12 seconds to exercise the
measurement path; that does not qualify sustained operation. Each run owns and
removes its processes, relay containers, and temporary working files. Playable
clips and `soak-metrics.json` remain under
`artifacts/qa/native-worker-<encoder>-soak-<seconds>/`.

## What is measured

The source is 1280×720 at 30 fps. The worker uses its 720p30 profile, including the
normal overlay, SRT input, H.264 video, and AAC audio. A continuous sink recording
runs for the requested duration plus two seconds to allow for joining before the
first video keyframe. The decoded video itself must cover the requested duration,
within 100 ms of duration quantization. The report retains its actual duration.

Every source frame carries a 16-bit barcode before encoding. Decoding those IDs
counts distinct source frames and exposes duplication. Five-second windows sampled
every second must deliver at least 24 fresh fps in at least 99% of windows, overall
fresh fps must be at least 24, and missing source frames must remain below 1%.
Per-frame presentation-time increments must agree with source ID increments within
2 ms of mux timestamp quantization. The current sync decoder also rejects duplicate
IDs outright; this is a strict healthy-network fixture, not an adaptation test.

The audio source emits a 200 ms pulse every two seconds. Its frequency identifies
the source epoch, rather than simply finding the nearest repeating pulse. The
analysis compares pulse onset with the decoded video PTS of that same source frame.
This detects a whole two-second offset as well as smaller offsets. It checks every
complete marker covered by both tracks, and rejects missing or ambiguous markers.
Only genuinely cut capture-edge pulses may be omitted.

The probe supplies the actual audio sample rate and per-frame timestamps. Decoding
uses that rate; sample counts must match the probe, and audio timestamps must remain
continuous within 2 ms. The two tracks retain their common media timeline. The
local A/V offset budget is 100 ms. It is a test acceptance threshold, not a claim
about perceptual lip-sync standards or end-to-end viewer latency. Reported offsets
remain limited by source, codec, and container timestamp precision.

Decoded track coverage is checked separately from pulse synchronization, so a
truncated audio track cannot pass by matching only its surviving pulses. Audio
must cover the video's beginning and end within 100 ms. Because this collector
joins an already-running stream, it permits up to 2.1 seconds of extra leading
audio while waiting for the next two-second video keyframe. That exception does
not permit missing audio; native recording and direct SDK fixtures retain the
100 ms limit at both ends.

A native API point changes the score halfway through capture. Decoded overlay
pixels near the beginning and end must match their corresponding reference scores.
The worker must report output throughout capture without increasing its encoder
attempt. The existing source-loss, worker-death, API-restart, current-score recovery,
and match-end checks surround this qualification.

The marker generators use documented [FFmpeg source/filter expressions](https://ffmpeg.org/ffmpeg-filters.html),
and measurement uses [ffprobe frame and stream data](https://ffmpeg.org/ffprobe.html).

## Measured result on this Mac

Both 600-second runs passed on the M4 Max development Mac with FFmpeg 8.1.2.
They ran concurrently using separate owned API/relay/sink fixtures. These results
apply to the synthetic 720p30 worker profile, not a device capture profile.

| Measurement                        |        Software |    VideoToolbox |
| ---------------------------------- | --------------: | --------------: |
| Decoded video duration             |       601.500 s |       601.333 s |
| Fresh / decoded frames             | 18,045 / 18,045 | 18,040 / 18,040 |
| Fresh frame rate                   |       30.00 fps |       30.00 fps |
| Missing source frames              |               0 |               0 |
| Healthy five-second windows        |       597 / 597 |       597 / 597 |
| Minimum window frame rate          |          30 fps |          30 fps |
| Matched complete A/V markers       |             301 |             300 |
| Maximum absolute A/V offset        |        0.385 ms |        5.193 ms |
| Source-return recovery before soak |         7.412 s |         7.268 s |

Both runs fully decoded audio/video, changed the burned-in score during continuous
capture, held one encoder attempt throughout capture, and passed the surrounding
fault/recovery and match-end checks. Owned cleanup completed. Logs were checked for
credential-bearing media URLs and fixture tokens; none were present. The sub-frame
offset numbers describe this deterministic fixture, with millisecond timestamp
precision; they do not imply equivalent measurement precision on real camera media.

Detailed evidence is in `artifacts/qa/worker-soak-software-600.log`,
`artifacts/qa/worker-soak-videotoolbox-600.log`, and each encoder's `soak-metrics.json`.
The retained 600-second clips also passed the subsequently added decoded coverage
check: extra leading audio was 527/690 ms and audio ended 26.8/22.8 ms before video
for software/VideoToolbox respectively. The endpoint measurements are retained in
`artifacts/qa/worker-600-decoded-coverage-recheck.json`.

## Negative controls

Pure tests reject duplicated frames, source loss, timestamp jumps, missing complete
edge/interior pulses, ambiguous audio frequencies, and whole-epoch A/V offsets.
A real remux experiment also shifted the audio track of a decoded fixture by
+250 ms, +2 seconds, and −2 seconds. All three files failed the 100 ms A/V budget
through the complete extraction path. Its log is
`artifacts/qa/media-sync-extraction-negative-controls.log`.

## Limits

These are synthetic local-network worker tests. They do not establish reliable
iPhone recording, camera capture, thermal behavior, adaptive quality, watch
networking, 1080p/4K sustained ceilings, cloud GPU support, or destination playback.
Those remain separate gates in the delivery plan. No external broadcast or cloud
deployment is involved.
