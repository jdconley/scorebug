# Native publisher padding probe implementation plan

> **For agentic workers:** Use superpowers:executing-plans in the existing isolated worktree; autonomous continuation is already authorized.

**Goal:** Add an explicitly enabled, publication-owned native SRT padding primitive, preserving media priority and terminal lifecycle behavior.

**Architecture:** A small synchronized probe lease is shared by the stream actor and its socket actor. The existing transport consumer offers at most one seven-packet MPEG-TS null message after completing a media payload and only when its muxer queue is empty. The socket actor samples real statistics, validates the lease, and makes a nonblocking optional write in one synchronous operation. No new queue, timer, consumer or per-frame task is introduced. This primitive measures local acceptance, never receiver delivery or capacity.

**Tech stack:** Swift 6, existing HaishinKit source subset and pinned libsrt 1.5.4, Swift Testing, existing Apple build directories.

## Decisions

A second independent probe task could conflict with the sole media writer. Injecting padding into the ordinary queue could delay media or consume its capacity. Instead, use optional opportunities at existing transport boundaries. This first native integration may underdeliver the requested probe rate; that must remain explicit and cannot qualify an upgrade. Later higher-load scheduling requires its own media-priority and cadence evidence.

`SRTStream` gains immutable `allowsBandwidthProbes: Bool = false` and begin/renew/cancel/snapshot methods requiring the current publishing generation and a returned UUID. One attempt per publication initially, with 1–2,000,000 accounted bits/second, no startup/catch-up burst, 300 ms renewal lease, 60-second/16 MiB bounds, actual accepted bytes/completion time and sticky reason. Starting requires current fresh native statistics and a ready transport clock. Replacement, finish and close synchronously revoke the shared permit, so an actor hop cannot submit obsolete padding. New publication starts fresh. Concurrent starts and stale renewals fail.

`SRTSocket` performs optional sends without suspension or a second writer. It refuses while a media send owns the socket. It saves `SRTO_SNDSYN`, temporarily disables blocking, submits one message, captures the native error, and restores the original setting before returning. EASYNCSND withdraws padding only; native/restore failures retain the existing terminal transport failure semantics. The original media send timeout and behavior remain unchanged. This uses the documented post-connect [SRT blocking option](https://github.com/Haivision/srt/blob/master/docs/API/API-socket-options.md#srto_sndsyn).

Local fresh pressure sampling occurs only on an eligible transport opportunity. Missing/stale/invalid statistics, RTT or send buffer above 50 ms, and new retransmission/drop counts withdraw padding. A lease cannot be revived after expiry. If no media arrives, no padding is submitted; lease expiry is evaluated when state is next observed or offered. No dedicated watchdog task is needed to stop nonexistent writes. The synchronized permit serializes revocation with the short nonblocking native call; it cannot retroactively cancel an already accepted datagram.

## Tasks

- [x] Add `SRTBandwidthProbeTests.swift` with pure-clock tests for packet shape, bounded tokens, expiry/late renewal, pressure/freshness/counters, byte/time limits, cancellation and accepted-completion accounting. Run to a causal failure, then implement `SRTBandwidthProbe.swift` with immutable public snapshot/reason types and an internal synchronized permit. Test cancellation racing an already entered submission.
- [x] Add socket tests for nonblocking padding success/EASYNCSND/error, prior blocking-mode restoration, cancelled/revoked probe, competing media ownership and missing statistics. Implement the native optional-send operation using an injectable synchronous operation boundary for deterministic errors; exercise the real flag get/set path on a native socket as well.
- [x] Add stream tests for default disabled behavior, exact generation/UUID checks, one attempt, queued-media priority, finish/replacement/close revocation and fresh publication reuse. Add exact pending-output accounting to `TSWriter` and the single optional call in the existing transport consumer. No archive or controller changes.
- [x] Run the full SDK suite, streaming package tests, provenance round trip and unsigned combined iPhone/Watch Release build using Xcode 26.2 and existing build directories. Review lifecycle/native-write/error paths and fix demonstrated defects. Record actual evidence and commit.

## Subsequent qualification gates

Connect the opt-in API through the app's owned publishing adapter and DEBUG fixture, with bounded lease renewal/diagnostics. Add authenticated attempt/connection-bound pre-demux GoSRT counters before implementing receiver-based admission. Null packets alone do not identify a stage. Then qualify actual native simultaneous archive/live media, pressure/feedback loss/recovery, unique pictures, 24-fps floor, A/V coverage and measured candidate cost. Keep production adaptation disabled and retain all physical phone/Watch, portable-host and soak requirements.

## Completed checkpoint

Implemented the default-disabled native primitive, media admission accounting,
nonblocking socket operation and scoped stream lifecycle API. The full SDK suite
passes 190 tests in 30 suites; the streaming adapter passes all 61 tests. The
unsigned combined iPhone/Watch Release build passes using Xcode 26.2. Verification
matches all 162 original upstream hashes and the exact maintained patch round
trip (18 modified upstream files and eleven added source primitives).

Review reproduced and fixed three defects: an empty-queue observation could become
stale across actor hops; a configuration change during awaited statistics could
admit an obsolete probe; and successful native acceptance could disappear from
diagnostics when restoring blocking mode failed. Targeted regressions failed
before the fixes and passed afterward. Re-review found no remaining blockers.
An entered-send cancellation regression retains the already accepted message and
prevents later sends. All owned test/build sessions completed and were joined.

The first two adapter test attempts used a stale SwiftPM source inventory and
failed to discover the three added source files. Refreshing the unchanged root
package manifest regenerated that inventory; the final run passed. Failed logs
are retained alongside the final result rather than replaced.

Evidence is under `artifacts/qa/native-padding-*`, with terminal hashes in
`native-padding-final-verification.json`. The tests exercise native socket flag
get/set with injected writes, deterministic lifecycle interleavings and a minimal
compressed transport fixture. They do not establish connected native SRT delivery,
decoded picture correctness, camera/archive behavior or sustained live cadence.
The app still constructs the stream with probing disabled. The prior native
24-fps and A/V failures remain unresolved by this checkpoint.
