# Transport clock calibration implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded
> experiment and independent reviews. One owner executes media tools at a time.

**Goal:** Establish a measured mapping between MPEG-TS video timestamps and the
production worker decoder observations, including nonzero origins, late acquisition
and 33-bit wrap, before introducing production source correlation.

**Architecture:** A finite local fixture compares the current worker command with
an experiment-only `-copyts` variant. Independently decoded PES timestamp bits and
ffprobe frame timestamps provide separate evidence. Preserve production flags,
media artifacts, exact commands and results; no runtime policy or media-path change.

**Tech stack:** Node/tsx, the existing worker argument builder and decoder parser,
FFmpeg/ffprobe, H.264/AAC MPEG-TS, existing visible frame identities.

## Design and alternatives

The existing worker decoder branch is after FFmpeg input timestamp processing.
Its zero-origin Matroska fixture cannot establish a mapping for real MPEG-TS.
The native TS writer also rebases against its common startup origin and serializes
33-bit timestamps. Neither first-decoded-frame alignment nor device wall clocks can
reconstruct a missing origin safely.

The preferred direction is an explicit native source-to-transport anchor plus
preserved worker transport timestamps. First verify the latter using the actual
production filter. An alternative is to export FFmpeg's input normalization offset;
that would need an additional trustworthy per-attempt channel. A private in-band
frame identifier would be more invasive and need codec/decoder interoperability
qualification. This experiment chooses between mechanisms based on measured output.

`-copyts` is an experimental candidate, not an approved runtime change. FFmpeg
[documents](https://ffmpeg.org/ffmpeg.html) that it preserves input timestamps but
also notes synchronization/muxer effects and wrap handling. Test actual wire values
modulo 2^33; do not assume signed demux values share the wire epoch. This modulo
check proves correspondence for this finite fixture, not uniqueness across long
sessions or reconnections.

## Task 1: Finite reproducible experiment

**Create:** `scripts/test-transport-clock.mjs`.
**Reuse:** `scripts/test-worker-timestamps.mjs` (`runInstrumentedWorker`),
`apps/home-daemon/src/pipeline.ts` (`buildFfmpegArgs`), `scripts/media-frame-codes.mjs`.

- [ ] Generate short 640x360/30 H.264/AAC MPEG-TS streams with known video identities,
  no B-frames and one-second keyframes. Cover ordinary transport lead, a nonzero
  origin, and a stream spanning the 33-bit wrap. Preserve input commands/version.
- [ ] Produce a late-acquisition suffix by cutting actual TS packets at the repeated
  PAT preceding a later keyframe, without remuxing or changing timestamp bits.
- [ ] Independently parse video PES PTS from TS packet headers, rejecting malformed
  sync/adaptation/PES/timestamp marker bytes. Bound retained fixture arrays/files.
  Compare ffprobe decoded PTS modulo 2^33 with the wire PTS and retained identities.
- [ ] Run the production worker and an otherwise identical `-copyts` candidate,
  sequentially, using the existing fd3 parser. Record all PTS arrays and compare
  candidate decoder PTS modulo 2^33 to the original wire values for every frame.
  Record current-command differences without relabeling them as source loss.
- [ ] Decode output frame identities and probe output A/V start/end times for both
  commands. Any changed media continuity is a finding, not permission to relax gates.
  Keep all artifacts/results under a unique `artifacts/qa/transport-clock-*` directory.
- [ ] Run with the host FFmpeg first. Require actual process completion, record failure
  details and exact commands, and preserve partial evidence on failure. No services,
  external network, Apple builds or long real-time holds are needed.

Command: `pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-transport-clock.mjs`.
Expected: complete evidence and explicit pass/fail per mapping candidate. An unsupported
candidate is a useful negative result; it must not be reported as qualification.

## Task 2: Review and choose the next production boundary

- [ ] Compare evidence with code: native common-origin calculation, Double-to-90k
  quantization, signed demux wrap handling, and worker input timestamp adjustment.
- [ ] Obtain independent specification then quality review of the fixture and claims.
- [ ] Record exact measured invariants and limits in this plan and link from
  `docs/adaptive-telemetry.md`. Select the next concrete source-anchor integration
  from that evidence. Keep automatic quality changes disabled.

The user's standing authorization covers these local experiments and engineering
choices. This plan does not require another approval checkpoint.
