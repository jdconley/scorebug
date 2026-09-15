# Native-to-relay timestamp correspondence

A worker clock tag describes the MPEG-TS **entering that worker**. It does not
establish identity with the publisher's original wire clock across a demuxing relay.
Runtime quality adaptation remains disabled until this boundary and matching source
interval counts have an explicit, scoped contract.

## Source contract

The installed qualification image is MediaMTX 1.21.0, locally resolved to image ID
`sha256:19fddade8d6110a3d718ac0045681fbeba344ae563a066205fe5929a87f7582f`.
Its [pinned dependencies](https://github.com/bluenviron/mediamtx/blob/v1.21.0/go.mod)
include mediacommon 2.9.4. SRT ingest invokes
[`ToStream`](https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/protocols/mpegts/to_stream.go),
which shares one timestamp decoder across supported media callbacks. That
[decoder](https://github.com/bluenviron/mediacommon/blob/v2.9.4/pkg/formats/mpegts/time_decoder.go)
returns zero for the first callback timestamp, then accumulates signed differences
modulo 2^33. In an uninterrupted epoch with ordinary consecutive deltas this is
unwrapped incoming PTS minus the first accepted callback PTS. Audio can establish
the origin; it need not be the first video picture, first keyframe, lowest timestamp,
or first PES header physically encountered. The origin is private state.

The [SRT egress writer](https://github.com/bluenviron/mediamtx/blob/v1.21.0/internal/protocols/mpegts/from_stream.go)
waits for random access and writes that normalized video PTS; joining a reader does
not select a new origin in this code. Ordinary stream processing changes NTP, not
PTS; the separate always-available mode has additional PTS offset behavior. No
original-PTS preservation setting or public API origin mapping was found in the
pinned SRT path. This source analysis explains a mechanism, not the exact first
callback selected in every production run.

## Raw boundary qualification

Run from the validation worktree on the Mac:

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer pnpm test:relay-clock
```

Requirements are the existing native toolchain/FFmpeg, libsrt `srt-live-transmit`,
and the locally installed pinned MediaMTX image. The command uses only owned
loopback listeners, encrypted SRT publish/read connections and a uniquely named
container. It generates an eight-second 1080p30 source with 240 numbered pictures
and audio, then uses the production native publisher and independent local archive.

The raw capture receives native MPEG-TS and tees its exact bytes into a packet-aligned
UDP bridge before the relay. The relay output is captured directly from SRT without
an FFmpeg remux. Before/after captures stay within the existing finite parser bounds:
32 MiB, 300 video PES units, one H264 picture per PES, checked PSI/PES framing and
video continuity. Unsupported layouts fail. Full A/V decode independently rejects
broken pictures that transport syntax alone cannot identify.

Matching uses unique decoded source barcodes and SHA-256 of the **compressed VCL
picture bytes**, preserving slice order and length boundaries. It deliberately
excludes Annex B start codes, trailing framing zeros and non-VCL NAL types 6–9
(SEI/SPS/PPS/AUD), which this relay can reframe or regenerate. This is not a hash of
the whole access unit, proof that all metadata survived, or decoded-pixel equality.
Every acquired picture must match, with a contiguous source suffix through the
native final picture. Acquisition gaps remain explicit. Parsed 33-bit PES PTS must
match independent decoder PTS modulo 2^33 at every picture. The unmodified production
worker also processes each scenario’s primary relay capture: fd3 decoder timestamps must match those
raw output timestamps and the output must retain all acquired barcode identities.

The late-reader case has an early control reader on the **same publication**, so
equal shifts at different acquisition boundaries test publication-scoped behavior.
A passing characterization can report `timestampsPreserved: false`: it establishes
an observed shift, not a runtime correction. Inconsistent shifts, damaged pictures,
missing tails, bad decoder evidence or relay warnings fail the command.

The final maintained run `artifacts/qa/relay-clock-4F0FVH` passes all three cases:

| Publication / reader           | Acquired source pictures | PTS shift (90 kHz ticks) | Worker output               |
| ------------------------------ | ------------------------ | ------------------------ | --------------------------- |
| Zero origin                    | 60–239 (180)             | -9000 throughout         | All 180 retained            |
| 123.25 s origin                | 59–239 (181)             | -9000 throughout         | All 181 retained            |
| Late reader, 123.25 s origin   | 119–239 (121)            | -9000 throughout         | All 121 retained            |
| Same-publication early control | 59–239 (181)             | -9000 throughout         | Raw/decoder comparison only |

Native local archives and publisher counters contain all 240 pictures in each
case. Every acquired compressed picture matches its pre-relay counterpart; all
primary worker decoder timestamps match the raw relay output. All owned processes
exit successfully, all three containers are removed, and relay warnings and cleanup
errors are empty. The differing acquisition prefixes are measured rather than
treated as delivery of the missing startup pictures. The -9000 result belongs to
these fixtures; it does not establish the original app run's -10919 callback origin.

The injected setup failure `SCOREBUG_TEST_RELAY_SETUP_FAILURE=before-send` exits 1
with the intended error in `relay-clock-UX3vCQ`. Both started children terminate,
the unbound UDP socket is handled, and the container is removed with no cleanup
errors. An independent Docker inspection confirms that exact container is absent.

## Worker frame-cap regression found by the comparison

The stronger output-identity gate exposed a production defect in
`relay-clock-OKIUc0`: all 181 acquired pictures reached the worker, but its 30 fps
cap discarded every third picture. Native floor quantization can place a source
PTS one 90 kHz tick before a nominal boundary (177000, 180000, 182999, 186000).
The previous half-tick tolerance assigned that picture to the prior bucket,
reducing a nominal 30 fps input to approximately 20 fps.

The cap now allows one input tick for floor quantization plus its existing half
tick for rescaling (`1.5 * TB`). It still selects at most one picture per anchored
bucket, preserves source PTS and uses passthrough with output-only normalization.
This is a finite 90 kHz qualification, not a claim about all possible coarse input
timebases or arbitrary jitter.

The maintained timestamp command includes four real-media regressions: nonzero
origin, 33-bit wrap, late reader phase, and late floor phase. The original filter
produces 60/60/51/76 output pictures from 90/90/77/76 inputs in
`worker-cap-quantization-luhXik`. The repaired filter retains 90/90/77/76 on both Mac
software (`worker-cap-quantization-mF6dnu`) and Linux CPU
(`worker-cap-quantization-O6E7J5`). Exact wire PTS, source identities, fd3 observations,
output timing, audio markers and balanced EOF are checked independently. Existing
60-to-30 capping, 25 fps, source-gap and unequal A/V-start assertions are retained.
Production transport-clock cases also pass again on Mac (`transport-clock-UzjhSs`)
and Linux CPU (`transport-clock-JDAMu9`), with the incomplete paths still failing
their intended negative controls. The complete raw relay run above uses this fix.
Mac VideoToolbox also passes all four regressions
(`worker-cap-quantization-LU0UDx`) and all five existing acquisition/cadence cases;
the latter retain 90/90/75/78/90 output pictures from 90/180/75/78/90 decoded inputs.
No NVIDIA hardware is exercised by these results.
The Linux CPU full timestamp CLI also passes all four regressions
(`worker-cap-quantization-QvQO86`) and all five existing cases with the same
90/90/75/78/90 output counts.

The full iPhone 14/iOS 17.5 simulator workflow `native-app-bR99Ps` passes with the
Mac worker and a 30-second requested stream hold: 1,867 archive frames (0–1866),
1,427 acquired live frames (227–1653), both at 30 fps with no loss inside the
recorded intervals. The 60 encoded startup pictures before live acquisition remain
explicit; no encoded tail is missing. Native scoring changes the live overlay,
the clean archive continues after streaming stops, and both files fully decode.
Maximum A/V marker errors are 0.021 ms archive / 64.917 ms live; track-end separations
are 16 ms / 20.551 ms. Exact scoped native clock export, two report-age proofs,
archive diagnostics and terminal process/cleanup checks pass. This short barcode
fixture does not establish physical camera, radio or high-motion performance.

Final tooling passes 525 tests; worker tests pass 179 and type checking passes.
Independent specification and quality reviews approve the relay helper/harness and
the cap repair. Qualification logs and a source/artifact hash manifest are retained
under `artifacts/qa/relay-clock-final-verification.json`.

## Capture-tool defect excluded from the evidence

The initial prototype used a stdin pipe between two libsrt sample transmitters and
produced relay decode errors. Its post-relay output is invalid evidence. Upstream
[SRT 1.5.6 ConsoleSource](https://github.com/Haivision/srt/blob/v1.5.6/apps/transmitmedia.cpp#L705-L741)
has a short-read resize condition that can leave the payload at the requested size;
the [forwarding loop](https://github.com/Haivision/srt/blob/v1.5.6/apps/srt-live-transmit.cpp#L806-L849)
sends that full payload. A short read can therefore insert zero padding. Source
inspection explains a corruption mechanism, without establishing the exact read
lengths or source provenance of the installed binary. The maintained fixture uses
UDP datagrams of at most 1316 bytes; that input path honors each datagram's actual
length. Subsequent raw captures have no relay warnings and all retained VCL hashes
match, independently excluding the observed corruption from those comparisons.

## Production decision

Keep the existing relay media timing and add explicit publisher-epoch clock mapping
metadata in the owned relay/gateway path. That avoids changing the A/V timing already
qualified for playback. The mapping must be captured at the actual first supported
ingress callback and tied to a unique publication epoch; the control plane must bind
it to the authorized publishing attempt and worker session. Neither an observed
constant such as 9000/10919 nor a reader's first decoded frame can stand in for it.

A byte-preserving SRT route or per-frame in-band identity remain alternatives, but
introduce a different deployment topology or SDK/worker metadata path. Patching the
relay to preserve PTS is another option and requires independent A/V, wrap, reconnect
and output qualification. None is enabled by this diagnostic command. Next work is
the scoped relay metadata contract, followed by matched source intervals and
available-capacity evidence before enabling automatic quality. The
[public worker epoch](superpowers/plans/2026-09-15-public-worker-epoch.md) now gives
native consumers a separate opaque reporting-session identifier. The existing
status contract continues to exclude private reporting session IDs and timing
tokens. This identity must be associated with the actual publication mapping;
it does not supply that mapping by itself.
