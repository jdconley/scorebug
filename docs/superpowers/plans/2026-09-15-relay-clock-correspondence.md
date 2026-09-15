# Relay clock correspondence investigation plan

> **For agentic workers:** Use superpowers:systematic-debugging and
> superpowers:subagent-driven-development for bounded independent source review
> and specification/quality review. One owner executes media/build commands.

**Goal:** Locate the native-to-worker timestamp shift with packet evidence before
using worker feedback for source loss or adaptive quality.

**Architecture:** Capture the exact native MPEG-TS bytes entering an owned local
MediaMTX relay and its raw SRT output, without an intervening FFmpeg remux. Match
video access units by content and compare their parsed 33-bit PES timestamps.
Compare raw output to decoder timestamps independently. Preserve every boundary
and acquisition gap; inferred offsets are diagnostics, not runtime normalization.

**Tech stack:** Existing native DualOutputSmoke, libsrt live transmit, pinned local
MediaMTX Docker image, Node bounded fixtures, existing TS parser, FFmpeg decoder.

## Evidence and hypothesis

Previous turn was progress: commits 89629bf and 3926096 expose the actual native
clock, bind it to app scope, and pass package/model/tools, five-scenario dual-output,
and native app workflow checks. The full app workflow `native-app-0YPFpe` has equal
endpoint discrepancies of -10919 ticks with intact frames. No all-frame comparison
or root-cause claim has yet been established.

Pinned MediaMTX v1.21.0 source demuxes SRT through `mpegts.ToStream`, applies a shared
`mpegts.TimeDecoder`, and remuxes via `mpegts.FromStream`. Hypothesis: relay ingest
rebases against an incoming timestamp. Verify dependency version and source and
compare captured bytes before deciding on any runtime change. No literal offset
from this run may be installed as a fix.

## Task 1: Bounded raw-byte reproduction

- [ ] Inspect pinned relay/dependency source and settings for timestamp rebasing.
  Retain source references and distinguish inference from executed evidence.
- [ ] Use owned dynamic loopback ports/container and libsrt raw stdin/stdout bridges
  to tee native output into a bounded input TS artifact and forward the same bytes.
  Start a raw relay reader after the owned path is ready; retain explicit joins,
  exits, API readiness and terminal cleanup. Restrict source to <=300 video frames
  and each TS artifact to <=32 MiB, matching the existing finite parser limits.
- [ ] Decode barcode identities on both sides and pair equal access units (content
  digest, excluding framing-only NAL differences where explicitly characterized).
  Compare modulo-2^33 timestamps for every matched frame, not only endpoints.
  Probe raw relay output timestamps to separate relay rewriting from FFmpeg input
  behavior. Preserve startup gaps and all unsupported layouts as failures.
- [ ] Repeat with an offset source clock and late reader to test whether the observed
  shift belongs to publication or reader acquisition. Record reproducible commands,
  bounded artifacts and exact process outcomes. Keep media gates unchanged.

## Task 2: Turn the diagnosis into maintained qualification

- [ ] Based on observed packet layout, add the smallest bounded comparison helper
  and behavioral fail-first tests for missing/ambiguous frames, malformed packets,
  wrap correspondence, shifted timestamps and missing decoder evidence.
- [ ] Promote the proven owned experiment into a reproducible local qualification
  command with deterministic cleanup and explicit positive/negative clock results.
  A run may establish a shift without claiming timestamp preservation; name those
  outcomes separately and fail missing or contradictory evidence.
- [ ] Run focused/full tools tests and the complete raw relay qualification; obtain
  independent specification then quality review and commit verified evidence/docs.
- [ ] Choose the next production approach from the evidence: preserve the source
  clock at relay, carry an authenticated scoped relay mapping, or use qualified
  in-band source identity. Public worker-session identity remains independently
  required. Do not enable runtime adaptation from this diagnosis alone.
