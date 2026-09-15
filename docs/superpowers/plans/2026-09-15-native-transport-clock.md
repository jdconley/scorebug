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

- [ ] Add failing known-byte tests for nonzero low bits and arbitrary decoded
  timestamp fields; cover all 128 low-seven-bit patterns and a nonzero Data offset.
- [ ] Add failing prefix/marker and independent wire-value tests for each timestamp
  prefix, 2^33-1, 2^33, larger signed-Int64 values and negative modulo values.
- [ ] Correct only timestamp field masks/byte selection. Decode the existing literal
  PES fixture independently and replace its incorrect expected timestamp only when
  confirmed by those bytes. Run focused and full SDK tests with retained red/green logs.

## Task 2: Define exact projection and scoped anchor

**Files:** new `SRTHaishinKit/Sources/TS/TransportClock.swift` and tests;
`PacketizedElementaryStream.swift`, `TSWriter.swift`, `SRTStream.swift`.

- [ ] Implement a scalar immutable origin/90k/lead mapping with explicit optional
  failure, testing fractional boundaries, large absolute clocks, mixed timescales,
  epoch/nonnumeric input, negative deltas and checked overflow before integration.
- [ ] Make PES/PCR writing share that projection, latch invalid timestamps before
  payload emission, and preserve common A/V origin and PTS/DTS offsets. Prove exact
  header bytes against the mapping; test startup failure, finish and reset lifecycles.
- [ ] Expose the muxer-selected anchor through an attempt-scoped SRT snapshot, only
  for the matching publishing generation. Test absent/startup, current, failed,
  finishing and replacement cases without inventing an origin before media startup.

## Task 3: Verify and record

- [ ] Obtain specification then quality reviews at implementation boundaries.
- [ ] Regenerate the maintained SDK patch from its verified original hashes; require
  all 162 original hashes and exact reverse/forward byte round trip.
- [ ] Run affected SDK/Streaming tests and Apple builds. Run the five-scenario native
  dual-output fixture because wire timestamp arithmetic changes, retaining all
  existing frame/A/V/rate/archive gates.
- [ ] Update telemetry/plan documentation with measured evidence and remaining worker
  integration, source-interval and profile-boundary work.

Command base: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer swift test --package-path vendor/HaishinKit`.
The user's standing autonomous-work authorization covers this repair and validation.
