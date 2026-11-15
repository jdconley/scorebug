# Native transport clock implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for independent
> implementation/review boundaries. Only one owner runs Swift/media validation.

**Goal:** Serialize native MPEG-TS timestamps correctly and expose a truthful
source-to-transport clock anchor for each publishing generation.

**Architecture:** Correct the existing bit serializer/decoder, then share a checked
rational source-time projection between PES/PCR writing and an immutable clock value.
The SRT actor exposes that value with its publishing generation; replacement/closed
attempts cannot masquerade as current. Keep worker flags, adaptation and archive
configuration unchanged in this slice.

**Tech stack:** CoreMedia CMTime, Swift 6, the maintained HaishinKit source subset,
Swift Testing, existing native dual-output fixture and Apple build checks.

## Design

The preceding transport experiment proves that preserved worker timestamps can be
matched modulo 2^33 on Mac and Linux, with explicit timestamp passthrough and output
normalization. It does not prove the native serializer's bit layout or source-time
projection. Source inspection finds independent defects: `TSTimestamp.decode` uses
byte 3 instead of byte 4 for the low bits; `encode` allows high timestamp bits to
alter the prefix nibble. The existing packet fixture's expected value encodes the
decoder defect and must be checked against its literal PES bytes.

Prefer one exact checked projection over duplicating the existing Double formula
in telemetry. Subtract source and origin rationally, quantize the nonnegative delta
toward zero to 90 kHz, and add the 9,000-tick PES lead with overflow checking. PCR
uses the same quantized delta without the lead. Invalid/nonzero-epoch source values,
source before origin, unrepresentable subtraction/quantization and overflow fail
explicitly before timestamp serialization. The wire carries the low 33 bits while
the anchor retains the non-wrapped domain. Preserve both PTS and DTS composition
relative to that common origin and lead; avoid adding the DTS lead twice.

The alternative of retaining Double conversion and exporting a tolerance would
leave the anchor dependent on absolute uptime and two independently rounded values.
A telemetry-only ideal timestamp could disagree with actual media. Shared checked
projection makes media and observations use the same defined transform.

An anchor describes the muxer's source origin and projection, not network receipt,
frame loss, available capacity or a profile boundary. Source-loss counting still
requires matching source intervals. Existing archives and worker behavior remain
independent.

## Task 1: Correct timestamp bit serialization

**Modify:** `vendor/HaishinKit/SRTHaishinKit/Sources/TS/TSPacket.swift`,
`vendor/HaishinKit/SRTHaishinKit/Tests/TS/TSPacketTests.swift`, and the literal
fixture expectation in `Tests/TS/PacketizedElementaryStreamTests.swift`.

- [x] Add failing known-byte tests for nonzero low bits and arbitrary decoded
      timestamp fields; cover all 128 low-seven-bit patterns and a nonzero Data offset.
- [x] Add failing prefix/marker and independent wire-value tests for each timestamp
      prefix, 2^33-1, 2^33, larger signed-Int64 values and negative modulo values.
- [x] Correct only timestamp field masks/byte selection. Decode the existing literal
      PES fixture independently and replace its incorrect expected timestamp only when
      confirmed by those bytes. Run focused and full SDK tests with retained red/green logs.

## Task 2: Define exact projection and scoped anchor

**Files:** new `SRTHaishinKit/Sources/TS/TransportClock.swift` and tests;
`PacketizedElementaryStream.swift`, `TSWriter.swift`, `SRTStream.swift`.

- [x] Implement a scalar immutable origin/90k/lead mapping with explicit optional
      failure, testing fractional boundaries, large absolute clocks, mixed timescales,
      epoch/nonnumeric input, negative deltas and checked overflow before integration.
- [x] Make PES/PCR writing share that projection, latch invalid timestamps before
      payload emission, and preserve common A/V origin and PTS/DTS offsets. Prove exact
      header bytes against the mapping; test startup failure, finish and reset lifecycles.
- [x] Expose the muxer-selected anchor through an attempt-scoped SRT snapshot, only
      for the matching publishing generation. Test absent/startup, current, failed,
      finishing and replacement cases without inventing an origin before media startup.

## Task 3: Verify and record

- [x] Obtain specification then quality reviews at implementation boundaries.
- [x] Regenerate the maintained SDK patch from its verified original hashes; require
      all 162 original hashes and exact reverse/forward byte round trip.
- [x] Run affected SDK/Streaming tests and Apple builds. Run the five-scenario native
      dual-output fixture because wire timestamp arithmetic changes, retaining all
      existing frame/A/V/rate/archive gates.
- [x] Update telemetry/plan documentation with measured evidence and remaining worker
      integration, source-interval and profile-boundary work.

Command base: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path vendor/HaishinKit`.
The user's standing autonomous-work authorization covers this repair and validation.

## Exact projection implementation decision

CoreMedia subtraction can itself round when mixed-timescale arithmetic cannot fit
its result timescale. Therefore the implementation does not subtract CMTime values
and then assume the intermediate is exact. It splits each signed timestamp into
floor seconds plus a nonnegative remainder at its original positive Int32 timescale.
Subtract whole seconds with overflow checking. The fractional cross-products and
denominator fit signed Int64 because both timescales are positive Int32; borrow one
whole second when the fractional difference is negative. Reject a negative delta.
Multiply whole seconds by 90,000 with overflow checking. Compute the fractional
floor using UInt64 `multipliedFullWidth` / `dividingFullWidth`, whose quotient is
strictly below 90,000. Checked addition yields a nonnegative Int64 PCR-domain tick;
checked addition of 9,000 yields the PES tick. There is no floating-point conversion,
newer-OS Int128 dependency, or rounding of the intermediate rational difference.
Input rounded flags describe the rational timestamp supplied by the caller and do
not invent extra precision; numeric epoch-zero values remain valid inputs.

`TransportClock` is immutable and initialized only from a valid numeric,
positive-timescale, epoch-zero source origin. Its public presentation projection
returns optional unwrapped Int64 ticks; its PCR projection shares the same delta
without the lead. Wire encoding alone applies modulo 2^33. A scoped SRT snapshot
contains the current publishing generation and clock; it is absent before the
muxer chooses an origin, during finishing, after failure/close and for a replacement
that has not chosen its own origin. Retaining an old immutable snapshot cannot make
it belong to a new generation. No frame/profile boundary is inferred from it.

## Implementation and verification

The wire serializer now preserves timestamp prefix/marker bits while taking only
33 timestamp bits, and the decoder reads its low seven bits from the correct byte.
Independent literal fixtures cover all 128 low-bit patterns, nonzero Data offsets,
three prefixes, signed extrema and wrap. The original PES fixture bytes remain
unchanged; their independently decoded value is 126,000, correcting the old test's
126,384 expectation. The controlled bit regression failed before the repair and
passes afterward (`native-clock-bits-red.log` / `native-clock-bits-green.log`).

PES header replacement is atomic: invalid projection cannot leave partly changed
flags, bytes or length, and reuse replaces rather than appends timestamp fields.
PTS and DTS use the same 9,000-tick lead. Writer preflight rejects unrepresentable
values before payload emission while retaining the existing startup-error priority.
PCR cadence compares quantized ticks directly, avoiding absolute-Double cancellation;
an independent large-origin fixture proves 19/20/39/40 ms cadence boundaries. Actual
writer packets also prove 33-bit wrap while the exposed clock stays unwrapped.
Retained behavioral red logs include `native-clock-pes-red-controlled.log`,
`native-clock-pcr-red.log` and `native-clock-scope-red.log`.

The SDK snapshot is absent before origin selection, while finishing, after failure
or close, and during a new generation's startup. An old retained immutable snapshot
keeps its original generation and origin. No source-loss or applied-profile claim
is attached to this value.

Validation after integration:

- Full SDK: 124 tests in 20 suites pass (`native-clock-sdk-full.log`).
- Streaming adapter: 21 XCTest tests pass (`native-clock-streaming-full.log`).
- Combined iPhone/Watch unsigned device Release and arm64 simulator Debug builds
  pass (`native-clock-apple-release.log`, `native-clock-apple-simulator.log`).
- The maintained patch verifies all 162 original upstream SHA-256 hashes and exact
  reverse/reapply bytes (`native-clock-provenance.log`). It now contains 17 modified
  original files and four added source files; regression tests remain tracked.
- Independent specification and quality reviews approve both the bit repair and
  the integrated exact clock/lifecycle implementation.

All evidence paths above are under `artifacts/qa/`. Earlier ten-minute app results
predate this change and are not substituted for current-code media validation.

### Five-scenario native media result

`pnpm test:dual-output` exits 0 with current native clock code; retained evidence is
`artifacts/qa/dual-output-yKe5LJ/` and `native-clock-dual-output.log`. All five native
scenario processes complete successfully. Every archive has all 420 source frames
(0–419), 30 fresh fps, full audio coverage and zero archive rejections, including
stalled and absent receivers. Both normal live outputs also retain all 420 frames,
with 30 fps in every measured cadence window. Normal and 123.25-second-origin live
packet rates fall from 5.992 to 1.982 Mbps and 6.068 to 2.016 Mbps after the requested
6-to-2 Mbps encoder update.

Archive marker error is at most 0.020833 ms, with a 14.666 ms audio tail offset.
Normal live marker error is at most 65.364 ms and tail offset 15.988 ms. Peak native
RSS is 95.1 MiB; maximum source scheduling lag is 12.789 ms. The stalled receiver
records 107 rejected live samples; the absent receiver records 76 evictions and
449 rejections. These explicit live failures leave their complete archives intact.
All existing cadence, identity, A/V, rate-change and memory gates remain unchanged.

### Remaining work

Production worker timestamp flags still use the old path. Connect the qualified
preserving path and the SDK clock through production app/worker telemetry, with
attempt identity and wrap handling. Then establish counts over matching source
intervals, applied-profile boundaries, usable video capacity after overhead,
thermal/worker pressure and measured impairment behavior. Keep automatic quality
control disabled until those independent requirements are qualified. This short
Mac fixture does not establish physical camera/Watch networking, sustained workload
capacity or another host's hardware performance.
