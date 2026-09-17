# Staged Probe Publisher and Fixture Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded publisher adapter implementation, then spec and quality review. Parent owns the DEBUG scheduler and serialized builds.

**Goal:** Make the bounded staged native probe API available to app publishers and provide a deterministic three-stage DEBUG exercise without enabling automatic quality changes.

**Architecture:** Both publishers retain their existing joined probe-operation ownership. Explicit staged starts/replacements forward exact identities to the native SDK, validate returned stage identity, and preserve synchronous authority references and cumulative diagnostics. A DEBUG staged schedule renews each owner, retires and snapshots it before replacement, and exports final per-stage totals for independent reconciliation. Default v1 fixture behavior remains unchanged.

**Tech Stack:** Swift actors/XCTest, native SRT SDK, existing capture fixture export. Current production and CLI qualification paths remain unchanged until the independent staged verifier is integrated.

## Publisher adapters

Files: `ios/Packages/ScorebugStreaming/Sources/ScorebugStreaming/{PublishingBandwidthProbeSnapshot,SRTPublisher,SRTMediaPublisher}.swift`; existing/new streaming probe tests.

- [x] Write failing tests for staged start/replacement, exact stage/generation/UUID rejection, stale returned stages, concurrent operations, cancellation/settings/stop during replacement, and unchanged default legacy behavior.
- [x] Add optional campaign start and cumulative accepted bytes to the wrapped snapshot and forward native authority by reference. Extend both public begin methods with `staged: Bool = false`; native adapter forwards to SDK. Internal media publisher Operations gains defaulted `beginStagedProbe` and `replaceProbe` closures so old fixture constructors remain source compatible.
- [x] Add `replaceBandwidthProbe(id:publishingGeneration:stage:bitRate:)` to both adapters. Require local current exact stage/UUID/generation and no encoder/probe operation. Execute inside existing joined operation and revision/health checks. Returned replacement must have same generation, next stage, different UUID, unchanged campaign origin and valid cumulative accounting. Invalid returned handles are cancelled. Replacement failure retires existing ownership and permits explicit retry against still-current identity.
- [x] Renewal must preserve stage and campaign identity. A staged start must return stage 1; the legacy start cannot silently return a staged owner. Keep stop and caller cancellation joining the operation; media stays independent of optional traffic failure.
- [x] Run focused red/green and full streaming tests; coordinate build slot with parent. No SDK patch edits in this task.

## DEBUG repeated scheduler

Files: `ios/Sources/Scorebug/Capture/NativeBandwidthProbeFixture.swift`, `ios/FilmModelTests/NativeBandwidthProbeFixtureTests.swift`, receiver-fixture flag wiring in `CaptureStreamingModel.swift` and `AppUITests/NativeStreamingTests.swift`.

- [x] Add mode `staged` and optional stage/campaign/cumulative diagnostic fields to native sample JSON. Add defaulted staged begin and replace operations. Legacy JSON keeps formatVersion 1; staged JSON uses 2. Forward exact SDK authority through sample conversion and app observation.
- [x] Default staged exercise begins after the existing 20-second readiness delay at 500 kbps, renews every 100 ms for 80 polls, cancels and reads a retired snapshot, then replaces at 1 Mbps for 80 polls and 2 Mbps for 80 polls. Retire and snapshot the final stage too. Each retirement event includes a monotonic `retirementRequestedAt` captured before cancellation, providing a conservative cutoff for future interval verification. Three stages total, within the native 60-second/16-MiB campaign. Test timing can shorten poll counts. Record `began`, `renewed`, `retired`, `replaced`, and `final` events. Keep evidence bounded (maximum 607 events, no historical task accumulation).
- [x] A withdrawal, failed operation, stop or malformed evidence ends the schedule; it does not restart itself. Stop joins pending work before export. Scope/generation/rate/stage/UUID/campaign/counters and observations must remain consistent. Same-stage totals advance by exactly the same amount as local bytes; stage transition requires retired prior observation, zero initial local bytes and exact prior cumulative total. Unknown authority is never invented by an exported report.
- [x] Add failing tests for three-stage export/accounting, stop during replacement, malformed stage/campaign/cumulative transitions, and legacy behavior. Run focused and full native model tests.

## Verification and follow-through

- [x] Review spec then quality; run full streaming/model tests and ARM64 simulator plus unsigned combined iPhone/Watch Release. Preserve new-prefix evidence and earlier frozen artifacts, update main plan, commit.
- [x] Document remaining independent verifier integration explicitly: current CLI only admits legacy renew/expire. Before any real staged run, extend sender, authenticated receiver collector, receiver interval verifier and CLI mode checks together, build the staged relay image, and test mutation rejection. Then qualify actual A/V plus independent archive, measured candidate cost, upward recovery and long-session campaigns. This checkpoint does not qualify those gates.


## Verified checkpoint

Both publisher adapters now expose staged start and exact-identity replacement,
validate stage/campaign/accepted-byte metadata on returned handles, preserve native
authority by reference, and retain joined cancellation/stop behavior. Legacy start
and renewal reject accidental staged substitutions. Malformed returned owners are
retired, and failed replacement can be retried against the still-current identity.

The DEBUG scheduler renews 500 kbps, 1 Mbps and 2 Mbps owners in sequence, snapshots
each retirement (including the last), and exports version 2 with cumulative counters
and pre-cancellation retirement timestamps. Its 607-event bound includes the final
snapshot. Missing final evidence on an admitted staged run is invalid, verified by
a regression that first exported completed/valid and now fails closed. Legacy modes
and their version-1 evidence remain unchanged. Simulator receiver-history and UI-test
flag wiring recognize staged mode; the CLI remains deliberately unchanged until
independent staged verification is available.

All 99 streaming and 298 native model tests pass, including 12 fixture tests.
The native loopback adapter test establishes both media tracks and waits for actual
ACK statistics to meet native admission limits before exercising staged replacement,
failed replacement/retry, authority revocation and renewal. Initial failed setups
(no transport clock and libSRT's initial 100-ms RTT) are retained with diagnostics;
no production admission limits were relaxed. This is adapter lifecycle coverage,
not a decoded multi-stage A/V and archive qualification.

The ARM64 simulator and unsigned combined iPhone/Watch Release builds pass. The
embedded Watch executable's arm64 and arm64_32 slices are inspected directly; Watch
sources are unchanged. Spec and quality reviews are approved. Source and evidence
hashes: `artifacts/qa/staged-probe-publisher-final-verification.json`. Previous frozen
evidence is unchanged.

Next integrate version-2 sender, authenticated receiver and native interval
verification together with the CLI mode/relay image selection. Preserve one clock
intersection and cumulative accounting across stages; use the sender retirement
request as a conservative interval cutoff. Then run real staged SRT plus independent
recording before candidate-cost admission, automatic recovery and long-session,
physical-device and remote-worker gates.
