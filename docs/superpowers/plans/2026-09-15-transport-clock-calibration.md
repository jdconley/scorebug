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

- [x] Generate short 640x360/30 H.264/AAC MPEG-TS streams with known video identities,
  no B-frames and one-second keyframes. Cover ordinary transport lead, a nonzero
  origin, and a stream spanning the 33-bit wrap. Preserve input commands/version.
- [x] Produce a late-acquisition suffix by cutting actual TS packets at the repeated
  PAT preceding a later keyframe, without remuxing or changing timestamp bits.
- [x] Independently parse video PES PTS from TS packet headers, rejecting malformed
  sync/adaptation/PES/timestamp marker bytes. Bound retained fixture arrays/files.
  Compare ffprobe decoded PTS modulo 2^33 with the wire PTS and retained identities.
- [x] Run the production worker and an otherwise identical `-copyts` candidate,
  sequentially, using the existing fd3 parser. Record all PTS arrays and compare
  candidate decoder PTS modulo 2^33 to the original wire values for every frame.
  Record current-command differences without relabeling them as source loss.
- [x] Decode output frame identities and probe output A/V start/end times for both
  commands. Any changed media continuity is a finding, not permission to relax gates.
  Keep all artifacts/results under a unique `artifacts/qa/transport-clock-*` directory.
- [x] Run with the host FFmpeg first. Require actual process completion, record failure
  details and exact commands, and preserve partial evidence on failure. No services,
  external network, Apple builds or long real-time holds are needed.

Command: `pnpm --filter @scorebug/home-daemon exec tsx ../../scripts/test-transport-clock.mjs`.
Expected: complete evidence and explicit pass/fail per mapping candidate. An unsupported
candidate is a useful negative result; it must not be reported as qualification.

## Task 2: Review and choose the next production boundary

- [x] Compare evidence with code: native common-origin calculation, Double-to-90k
  quantization, signed demux wrap handling, and worker input timestamp adjustment.
- [x] Obtain independent specification then quality review of the fixture and claims.
- [x] Record exact measured invariants and limits in this plan and link from
  `docs/adaptive-telemetry.md`. Select the next concrete source-anchor integration
  from that evidence. Keep automatic quality changes disabled.

The user's standing authorization covers these local experiments and engineering
choices. This plan does not require another approval checkpoint.

## Native source-clock boundary found during inspection

`TSWriter` chooses its common origin only after each expected track contributes a
payload, taking the minimum startup PTS/DTS. `PESOptionalHeader.setTimestamp` then
computes PTS through `Double(source.seconds + 0.1 - origin.seconds) * 90000`, truncated
to Int64. The DTS path receives the same lead from `TSWriter.emit`. This conversion
is not exact rational CMTime subtraction, so a future portable mapping must either
carry a qualified error bound or share a defined exact quantizer with serialization.
An independently reconstructed ideal rational timestamp is not yet the actual wire
value. Audio also traverses the PCM source-to-host-time conversion before muxing.

Inspection also finds that `TSTimestamp.encode` does not mask the timestamp's high
bits away from the first byte's PES prefix, and its decoder reads byte 3 twice instead
of reading the final byte for the lowest seven bits. Current timestamp unit coverage
uses zero, and startup coverage allows a one-tick difference. These are concrete
regression targets for the next native clock slice; this FFmpeg-generated experiment
cannot validate or repair the native serializer.

The current app capture/encoder snapshots aggregate by local monotonic windows;
the worker aggregates by its own monotonic windows. Even perfect PTS correspondence
will not make counts from unequal source intervals directly comparable. The eventual
loss estimator must count matching source intervals (with explicit acquisition,
restart and profile-transition boundaries), not infer a denominator from just each
window's first/last PTS. Keep the existing wall-time cadence/age evidence separately.


## Experimental findings before integration

The first host run (`transport-clock-GvtP86`) completed characterization but exited 1
because plain `-copyts` failed media qualification. The current worker retained all
120 full-stream / 90 late-join frame identities, while its decoder timestamps differed
from the independently parsed wire values in all six cases. Plain `-copyts` matched
every wire PTS modulo 2^33, but the wrap cases retained only 79 output frames. Probe
frame counts independently confirm the loss; it is not only a barcode-decoder issue.

A second run (`transport-clock-1WPFjD`) found that adding output
`-avoid_negative_ts make_zero` alone still retained only 79 wrap frames. In the third
run (`transport-clock-LSIsgv`), preserving the existing explicit select/cap filter and
changing the experimental encoder sync mode to `-fps_mode passthrough`, together
with `-copyts` and output normalization, retained all 120/90 frames and exact modulo
wire correspondence across all six cases. This localizes the failure to the path
using VFR with negative demux timestamps before output normalization; it does not
claim an upstream FFmpeg defect. The first wrap source PTS is 8,589,808,592 on the
wire and -126,000 after demux, so signed numeric equality would be an incorrect gate.

The final qualifier must name the passing candidate explicitly and exit 0 only when
all its mapping and media gates pass. Known-unsuitable comparison candidates remain
reported failures, not hidden exclusions. Final host and Linux CPU evidence follows below. No production worker flags have changed.


## Final host and portable CPU evidence

The final host qualifier exits 0 in `transport-clock-JcoWoY` with FFmpeg 8.1.2.
The unchanged fixture also exits 0 inside the existing CPU image
`scorebug/home-daemon:local-validation` (image digest
`sha256:e20b63422cd618190356c5876c153227b244cced909911dd1a9fec920255b4b2`), using
FFmpeg 5.1.9, in `transport-clock-CptfGj`. All 20 worker processes on each platform
have actual terminal code 0 and no signal. There is one qualified candidate:
`copyts-passthrough-make-zero`. The current command and two simpler candidates remain
explicit negative mapping or media evidence.

On both platforms the chosen candidate retains 120/90, 120/90 and 120/90 frames
for ordinary/nonzero-origin/wrap full and late inputs respectively, with exact
wire-PTS correspondence modulo 2^33. Maximum marker offset is 0.396 ms; maximum
absolute decoded-audio/video EOF offset is 34.271 ms. Both are within the unchanged
40 ms marker and 100 ms tail gates. Original timestamp, packet and source-frame
arrays are retained for every case. Early diagnostic runs had an incorrect source
sample-rate fallback and/or misleading marker lookup after frame removal; the final
runs correct these diagnostics. Failed media candidates remain failed.

The CPU command uses the image's Linux tsx runtime with the workspace mounted
read-only at `/qualification` and only `artifacts/qa` writable. It runs with
`--network none`, `/usr/bin/ffmpeg`, `/usr/bin/ffprobe` and the image's DejaVu font.
The exact invocation is retained in `artifacts/qa/transport-clock-cpu-command.json`;
console evidence is `transport-clock-cpu.log`. No image rebuild or host deployment
is implied.

Thirty pure parser tests pass, including malformed TS/adaptation/PSI/PES/timestamp
headers. All 430 tooling tests pass (`transport-clock-tools.log`). The existing
five-case worker timestamp qualifier passes after the optional helper diagnostics
change; helper nonzero-exit/spawn-error checks retain partial PTS, stderr and actual
terminal outcomes. The host artifact's `verification.json` records those checks.

The next production slice should first correct and test native timestamp bit
serialization, define exact source-to-90k quantization, and expose an immutable
publishing-attempt clock anchor. Separately integrate the qualified worker flags
with its explicit frame-rate cap, retaining regression coverage for 25/30/60 fps,
missing frames, acquisition gaps and real native SRT input. A source-interval loss
estimator and profile-transition boundaries still follow; the current wall-time
aggregates cannot become exact source-loss counts merely by attaching an anchor.


Independent specification and quality reviews approve the finite fixture and evidence.
Review checks include actual TS timestamp bytes, byte-identical late suffixes, saved
input hashes, raw retained identities/PCM, all worker terminal records and candidate
argument differences. `artifacts/qa/transport-clock-final-verification.json` records
source hashes and the host, CPU, tooling and formatting results. These are reviewed
experiment results; production integration and hardware qualification remain open.
