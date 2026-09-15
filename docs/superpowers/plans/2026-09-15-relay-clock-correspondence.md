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

## Starting evidence and hypothesis

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

- [x] Inspect pinned relay/dependency source and settings for timestamp rebasing.
      Retain source references and distinguish inference from executed evidence.
- [x] Use owned dynamic loopback ports/container and libsrt raw stdout capture and a packet-aligned UDP bridge
      to tee native output into a bounded input TS artifact and forward the same bytes.
      Start a raw relay reader after the owned path is ready; retain explicit joins,
      exits, API readiness and terminal cleanup. Restrict source to <=300 video frames
      and each TS artifact to <=32 MiB, matching the existing finite parser limits.
- [x] Decode barcode identities on both sides and pair equal access units (content
      digest, excluding framing-only NAL differences where explicitly characterized).
      Compare modulo-2^33 timestamps for every matched frame, not only endpoints.
      Probe raw relay output timestamps to separate relay rewriting from FFmpeg input
      behavior. Preserve startup gaps and all unsupported layouts as failures.
- [x] Repeat with an offset source clock and late reader to test whether the observed
      shift belongs to publication or reader acquisition. Record reproducible commands,
      bounded artifacts and exact process outcomes. Keep media gates unchanged.

## Task 2: Turn the diagnosis into maintained qualification

- [x] Based on observed packet layout, add the smallest bounded comparison helper
      and behavioral fail-first tests for missing/ambiguous frames, malformed packets,
      wrap correspondence, shifted timestamps and missing decoder evidence.
- [x] Promote the proven owned experiment into a reproducible local qualification
      command with deterministic cleanup and explicit positive/negative clock results.
      A run may establish a shift without claiming timestamp preservation; name those
      outcomes separately and fail missing or contradictory evidence.
- [x] Run focused/full tools tests and the complete raw relay qualification; obtain
      independent specification then quality review and commit verified evidence/docs.
- [x] Choose the next production approach from the evidence: preserve the source
      clock at relay, carry an authenticated scoped relay mapping, or use qualified
      in-band source identity. Public worker-session identity remains independently
      required. Do not enable runtime adaptation from this diagnosis alone.

## Task 3: Preserve near-boundary frames in the existing worker cap

The stronger worker-output gate exposed a real defect in `relay-clock-OKIUc0`:
native/relay/decoder retain all 181 offset-source pictures, but output drops every
third one. PTS values include 177000, 180000, 182999, 186000; the existing half-input-
tick adjustment still puts 182999 in the prior 30 fps bucket. This is source-time
quantization, not loss at the relay. Do not relax the frame identity gate.

- [x] Add a finite real-FFmpeg regression to the existing worker timestamp
      qualification for a 30 fps MPEG-TS input with every third frame one tick early,
      including nonzero/near-wrap time origin and a late input start. Preserve the
      exact source barcode and assert all decoded and output pictures remain intact.
      Existing 60-to-30 capping, source gaps, A/V and tail cases must still pass.
- [x] Verify behavioral red with the actual production argv. Then adjust only the
      bucket phase tolerance to cover one native floor-quantization tick plus the
      existing half input-tick rounding allowance (1.5 \* TB). Keep at most one selected
      picture per anchored bucket, preserve source PTS, and retain passthrough/output
      normalization. Do not use output duplication or infer fps from packet count.
- [x] Run worker unit tests/typecheck and complete timestamp qualifications; repeat
      production transport-clock and relay qualifications after the change, including
      output frame identity checks. Review this production behavior independently.

## Verified result and remaining work

All bounded tasks above are complete. The [source contract and measured results](../../relay-clock-correspondence.md)
separate relay normalization, reader acquisition and a genuine production frame-cap
bug. The stdin prototype was invalidated and replaced with a UDP bridge; the
maintained raw qualification verifies every acquired picture and timestamp with
same-publication early/late readers. Fault injection verifies cleanup before the
UDP socket is bound.

The cap regression first fails with the original production filter, then passes
with the minimal tolerance repair on Mac software, Mac VideoToolbox and Linux CPU.
Existing cadence/A/V checks and all six production transport cases pass. The full
iPhone 14/iOS 17.5 native recording/scoring/streaming/export workflow also passes.
Final tooling passes 525 tests, worker tests pass 179 and type checking passes;
independent specification and quality reviews approve both changes. Evidence and
source hashes are retained in `artifacts/qa/relay-clock-final-verification.json`.

Next: add a separate public worker epoch, then an authenticated publisher-epoch
mapping captured at the relay's actual normalization boundary. Never expose the
private reporting session/timing token, infer a mapping from a late reader, or use
a fixture offset as a production correction. Matching source intervals, profile
transition boundaries, capacity and impairment qualification remain prerequisites
for runtime adaptation. Physical device/radio and other GPU/cloud qualification
remain separate from these local fixtures.
