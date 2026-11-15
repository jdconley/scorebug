# Proxy final-overlay recording

Authorized scope: retain RTMP publishing by default and add `OUTPUT_MODE=record` or
`OUTPUT_MODE=rtmp+record`. Recording modes require `OUTPUT_RECORDING_DIR`; RTMP
modes require an RTMP(S) `OUTPUT_URL`. The recording is the encoded final proxy
overlay at the selected proxy profile, separate from the phone's clean archive.

Each supervisor pipeline attempt allocates a fresh private directory containing
`overlay.mp4`. Retries keep earlier attempts and cannot reuse their files. A
record-only output uses fragmented MP4; dual output uses the FFmpeg tee muxer
with explicit maps and global headers so both outputs share one encode. Leave
tee failure handling at abort: neither failed recording nor failed RTMP may be
silently reported as success. Preserve the existing filter and A/V clock policy,
and never log RTMP credentials. MP4 fragments improve interrupted recovery but
cannot guarantee recovery of the final incomplete fragment.

Implementation sequence:

1. Add failing config, output-argument, and per-attempt allocation tests.
2. Add mode validation, private allocation, and output argument construction;
   wire allocation into each synchronous supervisor start callback.
3. Run the home-daemon suite, build/typecheck, and a bounded real FFmpeg proof
   for record-only/dual output, unusual filenames, and output failures.

Reference: https://ffmpeg.org/ffmpeg-formats.html#tee (single encode, explicit
maps/global headers, escaping, and default abort-on-failure behavior).

Qualification found that `empty_moov` removed a 0.6-second audio lead. Use
`frag_keyframe+delay_moov+default_base_moof` so edit lists preserve the common
A/V timeline. The header becomes recoverable after the first complete fragment,
not immediately on start. Unit tests are FFmpeg-independent; the explicit media
test requires `SCOREBUG_RECORDING_FFMPEG`, `SCOREBUG_RECORDING_FFPROBE`, and
`SCOREBUG_RECORDING_FONT`. It checks both output modes, retained completed
fragments without the last fragment/trailer, A/V lead, exact frame counts, escaped
filenames, successful decoding, and failure propagation from either tee slave.
