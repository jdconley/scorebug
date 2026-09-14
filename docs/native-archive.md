# Native local archive qualification

`ios/Packages/ScorebugMedia` contains the shared native recording core, with iOS 17
and macOS 13 deployment targets. `tools/media-harness` exercises that core with
actual AVFoundation decoding and encoding on a Mac. It has no scoring, API, or
network dependency.

## Recording and recovery contract

- `SegmentedArchiveWriter` encodes raw NV12 video and PCM audio to H.264/AAC.
  The initial profile is 1920×1080, 30 fps, 12 Mbps video, and 48 kHz mono audio
  at 128 kbps. Both tracks use an explicit shared timestamp origin. The writer
  validates dimensions, audio format, and increasing timestamps.
- Two-second segmented MP4 output is stored as an initialization bundle followed
  by media bundles. Each bundle contains its payload, sequence, timing metadata,
  size, and SHA-256 digest. Files and directories are synchronized before and
  after exclusive atomic publication. The manifest is a replaceable cache.
- Recovery scans committed bundles, checks their order and integrity, and ignores
  incomplete staging directories. It includes a committed bundle missing from a
  stale manifest. Corruption or sequence gaps produce an explicit error.
- Unknown or insufficient disk capacity stops writing. Preflight includes the
  actual next manifest and metadata, payload, filesystem overhead, and a reserve.
  A storage error latches; the store does not discard existing completed bundles.
- The writer serializes access and retains its segment delegate. A `false` append
  result means the caller still owns the sample and must retry or explicitly fail
  recording. The fixture holds at most one pending sample per track and bounds
  its retries. Production capture queues are a separate remaining task.
- `ArchiveExporter` assembles fragments, remuxes to a standard MP4 without
  reencoding, and fully decodes the video and audio before publishing the file.
  It uses an exclusive destination, checks temporary-space requirements, supports
  cancellation, and preserves original fragments on success and failure.

These guarantees concern process termination and application-level I/O failures.
The fixture does not simulate a device power loss or establish a universal maximum
tail loss under every encoder, storage, and thermal condition.

## Run locally

Use Swift 6/Xcode, Node 22 or newer, and FFmpeg/ffprobe with H.264/AAC support.
`FFMPEG_PATH` and `FFPROBE_PATH` override media executable discovery.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  swift test --package-path ios/Packages/ScorebugMedia
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
  pnpm test:archive
```

The harness creates an isolated directory under `artifacts/qa/archive-*` and keeps
the source, fragments, recovered/exported videos, logs, and JSON measurements.
It uses no camera or external streaming destination. Its child processes are
owned and cleaned up by the harness.

The 14-second moving fixture includes source-frame barcodes, uniquely identified
audio pulses, and a black region for verifying that the archive remains clean.
Checks include a complete video/audio decode, all 420 fresh source video frames,
audio continuity, frame cadence, and a 100 ms A/V timing budget. Export checks
compare encoded packet hashes and verify that original fragment hashes remain
unchanged. Native export is also cancelled in flight, and a competing destination
is created between preflight and publication. Both cases must preserve originals
and remove only the exporter's own temporary files.

Five additional processes are forcibly terminated:

1. Immediately before the second media bundle commits.
2. Immediately after that bundle is renamed, before the manifest is updated.
3. During real-time feeding at 6.3 seconds.
4. During real-time feeding at 8.3 seconds.
5. During real-time feeding at 10.3 seconds.

The first two use accelerated input and a precise storage checkpoint. The last
three use real-time input. Every recovered clip must contain a contiguous prefix
of source frames, decode fully with audio, and export successfully. The measured
tail-loss bound includes one potentially unreported accepted video frame and must
remain within the plan's five-second budget.

## Current evidence and limits

On the M4 Max Mac with Xcode 26.2 and FFmpeg 8.1.2, the reviewed complete run
preserved all 420 video frames at 30 fresh fps with zero source-frame loss and
seven matched audio pulses. Maximum measured A/V offset was 0.71 ms. All five
termination cases recovered playable media; the largest measured tail-loss bound
was 2.60 seconds at the pre-commit checkpoint. This is a short fixture result.

All 31 native tests pass, including generated NV12/PCM lifecycle regressions for
concurrent finish/cancel, cancellation when AVFoundation suppresses completion,
and a late completion after cancellation. Generic iOS simulator and unsigned
device builds pass with an iOS 17 deployment target. These are compilation checks,
not runtime camera qualification.

Still required: camera capture integration, bounded independent archive/publish
queues, app recording states and recovery UI, interruptions and new recording
parts, simultaneous archive/SRT operation, longer recording qualification, and
physical iPhone tests. The prototype camera app does not yet use this package.
