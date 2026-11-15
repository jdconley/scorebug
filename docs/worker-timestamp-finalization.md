# Worker timestamp and EOF qualification

The worker uses VFR output and the input encoder timebase. A timestamp bucket
selection filter caps high frame rates without synthesizing frames, raising a
25 fps source to 30 fps, or closing a source video gap. Audio and video retain
their common timeline, including audio acquired before the first video keyframe.

Run `pnpm test:worker-timestamps software` (or `videotoolbox`) explicitly. The
default unit suite does not require FFmpeg. `pnpm test:worker software` also runs
this qualification before the full local network fixture. Each source includes
frame identities and two audio markers. The checks require exact retained frame
identities, source cadence within 2 ms, marker alignment within 40 ms, and final
A/V coverage within 100 ms. A missing-video fixture preserves a 400 ms gap.

On 2026-09-14, the existing CPU image `scorebug/home-daemon:local-validation`
(Debian bookworm FFmpeg 5.1.9) passed all five cases using its actual FFmpeg and
ffprobe executables through local Docker wrappers:

| Input                                 |            Retained frames | First video PTS | Final audio minus video |
| ------------------------------------- | -------------------------: | --------------: | ----------------------: |
| 30 fps, 600 ms video acquisition lead |                  90 unique |         0.623 s |                22.21 ms |
| 60 fps capped at 30                   | 90 unique, even source IDs |         0.623 s |                22.21 ms |
| 25 fps                                |                  75 unique |         0.623 s |                22.54 ms |
| 30 fps with 12 missing frames         |                  78 unique |         0.623 s |                22.21 ms |
| 30 fps, 1.8 s video acquisition lead  |                  90 unique |         1.823 s |                 6.44 ms |

Audio begins at zero in every case. Maximum marker offset was 0.271 ms. The
small common shift relative to the source includes AAC encoder priming.

## Unbalanced input EOF remains a separate investigation

`pnpm test:worker-timestamps software --tail-experiment` adds an input with
400 ms of audio after the last video frame. This is an intentionally failing
diagnostic of the current worker, excluded from the normal qualifier. It keeps
the same 100 ms assertion and does not trim or retime the source. On host FFmpeg
8.1.2 the unmodified pipeline reports audio end 4.04029 s versus video end
3.62333 s, a 416.96 ms excess tail.

An additional finite-file experiment used 3 seconds of video beginning at
600 ms, with audio ending at 6 seconds. FFmpeg 8.1.2 with `-shortest` retained all
90 video frames and ended audio 1.11 ms before video. FFmpeg 5.1.9 with the same
option retained 2.391 seconds of excess audio. With real-time input interrupted
by SIGTERM, 5.1.9 still retained approximately 603 ms of excess audio. Those
SIGTERM measurements are bounded file experiments, not proof of live network
shutdown behavior.

The deployed FFmpeg 5.1.9 supports `-fps_mode` and encoder timebase `-1` but does
not expose `-shortest_buf_duration`. No shortest flags or FFmpeg upgrade are part
of this production change. Upstream graceful encoder and transport shutdown
needs separate validation against the actual native stream before choosing an
EOF fix. The live qualification must continue to enforce its coverage limit.

The relevant FFmpeg semantics are documented in the
[output synchronization and shortest options](https://ffmpeg.org/ffmpeg.html)
and [select filter expressions](https://ffmpeg.org/ffmpeg-filters.html#select_002c-aselect).
