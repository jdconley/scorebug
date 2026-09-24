# Two-minute representative native replay

## Contract declared before running

Run one 120-second 1080p case, then one 120-second 4K case, serially through the
native file-driven publisher and independent segmented archive, direct loopback
SRT listener, production CPU proxy/score overlay, RTMP and independent recorder.
Stop the campaign on its first failure and preserve all evidence. Do not qualify
automatic adaptation, relay attachment, HDR/60 fps, cameras, physical radios,
remote hosts or a full match from these cases.

Prepare new private excerpts from seconds 600–720 of each original. Normalize to
30 fps SDR BT.709, H.264 and 48 kHz mono PCM in MOV, as in the short native cases.
Tone-map the 4K HLG source. Add a 16-bit frame identity in a 32-pixel-high top strip
to these derived files only. Independently decode and check all 3,600 source IDs
before using either file. Originals stay read-only and no footage leaves the Mac.

Keep all production queue sizes and timeouts unchanged. Keep the existing native
probe's 512-frame and 4,096-transport-event diagnostic limits too. Their explicit
overflow/omission flags describe partial diagnostic coverage; do not relabel them
as complete or use prefix evidence to qualify the rest of the run. Instead verify
every output frame independently from the prepared source identity. This is a
separate long-run contract, not a relaxation of the short diagnostic campaign.

Each pass requires:

- Normal joined sender/proxy/recorder completion, bounded harness cleanup and no
  leftover owned listeners. No artificial delay before native publisher stop.
- Native archive count and submitted-video count of 3,600, zero archive rejection
  and zero live queue loss/rejection. Independent full A/V decoding of both MP4s.
- Exactly 3,600 decoded frames in archive and live, each ID 0…3,599 once in order,
  expected raster/codecs, strictly increasing timestamps and gaps at most 35 ms.
- At most 100 ms missing A/V coverage, including stream startup/tail. Correlate
  real audio at 10, 60 and 110 seconds against the prepared source: at least 0.98
  normalized correlation, absolute lag at most 100 ms and lag spread at most 20 ms.
  Check every decoded audio frame's timestamp and sample count, allowing at most
  2 ms boundary rounding, so total duration cannot hide internal gaps/overlaps.
  The three correlation windows are sampled content evidence, not verification
  of every audio sample's content.
- Inspect source, archive and live images: clean archive and proxy score overlay.
- Retain exact commands, source/executable hashes, failures and diagnostics with
  their actual scope. The existing scheduled bitrate change remains scheduled,
  with its receipt checked; no whole-run per-frame bitrate attribution is claimed.
  Report source scheduling lag and sender elapsed time separately. Recorded PTS
  and complete content do not establish live wall-clock delivery deadlines.

## First campaign: failed audio gate, video and timeline evidence retained

Both private source excerpts independently verify 3,600 IDs and 5,760,000 audio
samples. `scripts/continuous-fixture-media.mjs` now checks all decoded identities,
timestamps, declared duration and audio continuity, using the validated output
sample rate (48 kHz archive, 44.1 kHz proxy). Each audio frame is checked against
both its predecessor and the cumulative sample timeline, preventing small rounding
errors from accumulating and later canceling. Eighteen focused tests and all
3,452 tooling tests pass; independent review approves the final checker/runner.

The first case, `artifacts/qa/match-footage-n6n1f13m/long-replay/1080p-cpu`, **fails
the declared audio correlation gate**. Do not mark the campaign passed. No 4K
network case ran after that failure.

- Sender/proxy exit normally in 120.879/121.035 seconds; independent recorder exits
  zero naturally. Both MP4s fully decode and contain all 3,600 IDs 0–3,599 in order.
- Archive video gaps are at most 33.334 ms; live gaps at most 34 ms. Both cover
  120 seconds. Native archive retains 5,760,000 samples; archive rejection and
  live queue drops/rejections are zero. Maximum source scheduling lag is 2.710 ms.
- Audio frame timelines are continuous. Decoded AAC padding is retained; end
  coverage differs by 20 ms archive / 21.612 ms live, within the unchanged 100 ms
  gate. Every live audio frame's cumulative timeline error is at most 0.114 ms.
- The archive's three correlations exceed 0.9994 with zero measured lag. Live
  correlations are 0.9603, 0.9544 and 0.9333, below the declared 0.98 threshold;
  measured lag is consistently 65.25 ms.
- Source frame 1,800 was inspected in source/archive/live: the archive is clean,
  and the live output has the configured score overlay. The scheduled 2 Mbps live
  bitrate is a diagnostic recipe, not adaptive or highest-quality qualification.
  That inspected scene shows warm-up activity; confirm an in-game rally excerpt
  separately before claiming match-play content coverage.
- Both owned ports release. All 1,171 repository and seven runner/input/executable
  hashes remain unchanged (`artifacts/qa/long-match-source.json`, case
  `assessment.json`). Prefix limits remain 512 encoder/submission rows and 4,096
  transport events with explicit overflow; source histories omit 3,088 old frames.

## Separate fractional-alignment diagnostic

`audio-subframe-diagnostic.py` evaluates the same retained output with a 65-tap
Hann-windowed sinc interpolator, refining the coarse 8 kHz lag by up to one sample
in 1/32-sample steps. Five signed analytic-delay controls recover the known delay
within 1/64 sample and exceed 0.999 correlation; unrelated signals remain
uncorrelated. All three real windows select the same −0.25-sample correction
(31.25 microseconds), reaching 0.9986–0.9988 correlation and 65.21875 ms A/V lag.
Actual decoded PTS of each matching source video frame determine that lag.

Independent review agrees that this strongly supports coarse alignment resolution
as the cause of the low sampled correlations. It is **separate diagnostic evidence**;
the original failed campaign and thresholds remain unchanged. No fresh passing
two-minute campaign or two-minute 4K result is claimed.

Next implement a reusable fractional-delay estimator with tests for signed and
integer-plus-fractional delays, silence, nonfinite inputs, window boundaries and
unrelated signals. Review it, then run a fresh declared 1080p case before advancing
to 4K. Inspect and select an in-game rally excerpt for additional content coverage.
These two-minute checks do not establish game-length thermal reliability,
physical capture, automatic adaptation or viewer delivery deadlines.
