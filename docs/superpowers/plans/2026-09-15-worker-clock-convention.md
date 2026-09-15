# Worker clock convention implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the bounded
> server/worker task and independent specification then quality reviews. The parent
> owns Swift execution; no overlapping native builds or media runs.

**Goal:** Carry an explicit decoder timestamp convention through worker reports and
native status decoding without breaking reporting to older servers.

**Architecture:** The actual production pipeline labels decoder snapshots with
`mpegts-pts-90k-v1`. New server session responses advertise support; the reporter
only sends this optional label when that exact convention is supported. API storage
locks the convention (including absence) across snapshots in a worker attempt.
Swift preserves optional/unknown labels but recognizes only the defined convention.

**Tech stack:** Shared TypeScript protocol, Zod HTTP validation, worker reporter,
Vitest HTTP fixtures, Codable and Swift XCTest on iPhone/Watch-compatible Core.

## Design

The production worker now preserves transport PTS, but deployed older workers do
not. Signed 90 kHz numbers alone cannot distinguish these semantics. Add optional
`clock: string` to `DecodedVideoSnapshot`, with exported protocol constant
`DECODED_VIDEO_TRANSPORT_CLOCK = 'mpegts-pts-90k-v1'`. Its defined meaning is decoder
input PTS rescaled to signed 90 kHz, with no worker input-origin rebase, comparable
to MPEG-TS wire PTS modulo 2^33. It does not assert source-loss counts, payload
identity, native publishing attempt correspondence or viewer delivery.

Add optional `decodedVideoClock: string` to `WorkerSessionResponse`. New servers
advertise the constant on initial and idempotent session registration. The reporter
retains this session metadata locally, but constructs the observation envelope
explicitly from workerId/sessionId/timingToken/sequence/observation: never spread the
new capability into the strict observation envelope. Clone the supplied observation
as before. Remove its clock unless both the advertised and supplied labels exactly
match the defined convention. Old/future/missing capabilities therefore preserve the
legacy shape without mutating the supplier. Session renewal must re-evaluate support;
report acknowledgements update timing tokens without changing negotiated capability.

Only the actual pipeline attaches the constant; generic telemetry collectors and
fake/legacy handles remain unlabeled. The API accepts bounded nonempty lowercase
ASCII identifiers (`^[a-z][a-z0-9-]{0,63}$`) so future unknown conventions can remain
explicitly unknown to old native clients. Null, wrong types, oversized or malformed
labels fail HTTP validation. Once any decoded snapshot is accepted in an attempt,
its label including absence is immutable when subsequent snapshots are present.
A whole omitted snapshot cannot erase this guard. A new attempt or new worker
session may establish a different convention. Rejected changes must not mutate
stored counters, sequence, timing tokens or previously accepted observations.

Swift adds optional raw `clock: String?` with a default nil initializer argument and
encodes it only when present. A computed `usesTransportClock` is true only for the
known exact string. Unknown strings decode and round-trip without changing the
rest of the status, but never become known-clock evidence. Existing legacy JSON
remains unchanged. Do not make report-age freshness depend on this tag: time age
and source clock mapping are separate facts.

An unconditional field would break old strict APIs; a version inferred from worker
name or first PTS would be unreliable. Explicit negotiated optional metadata keeps
old reporting functional and makes the uncertainty visible. The user's standing
autonomous-work authorization covers implementation and local verification.

## Task 1: Protocol, API and worker

**Files:** `packages/protocol/src/worker-status.ts`,
`apps/control-plane/src/routes/media.ts`,
`apps/control-plane/src/worker-observations.ts`,
`apps/home-daemon/src/pipeline.ts`, `apps/home-daemon/src/worker-reporter.ts`,
corresponding existing/new test files.

- [x] Add the constant and optional typed fields.
- [x] Write failing HTTP tests for initial/idempotent advertised support, known and
  unknown bounded clock round-trip, malformed rejection, and immutable known/absent
  conventions across omissions, retries and new attempts/sessions.
- [x] Add failing reporter tests for old/new/unknown capabilities, supplier-copy
  ownership, exact envelope shape, ack token updates and capability re-evaluation
  after session renewal. Add actual pipeline snapshot label assertion.
- [x] Run focused tests and retain behavioral failures before production changes.
- [x] Implement the handshake/filter/immutability behavior described above. Keep
  existing counter, age and session guards. Run focused then full API/worker tests,
  protocol build and affected type checking. No production media argv changes.

## Task 2: Native wire compatibility

**Files:** `ios/Packages/ScorebugCore/Sources/ScorebugCore/DecodedVideoSnapshot.swift`,
Core decoded-video tests, `packages/protocol/fixtures/decoded-video-clock-v1.json`.

- [x] Create shared known/legacy/unknown status examples with signed wrap-region PTS.
  API tests must accept and preserve these exact status observation payloads.
- [x] Add failing Swift decode/round-trip assertions and exact known-label recognition;
  preserve existing optional omission and mandatory null encoding behavior.
- [x] Implement optional raw clock and computed exact convention recognition.
- [x] Run complete Core tests and compile arm64_32 watchOS 10 plus combined iPhone/
  Watch Release. Reuse existing package build commands and Xcode 26.2 toolchain.

## Task 3: Integrated proof and documentation

- [x] Obtain specification then quality reviews and fix actionable findings.
- [x] Run full tooling tests and local worker lifecycle/media fixture. Verify actual
  production-tagged reports reach the authenticated status endpoint, in addition to
  existing scoring, recovery and stop behavior. Keep old-server tests as regressions.
- [x] Update `docs/worker-decoded-video.md` and `docs/adaptive-telemetry.md` with scope,
  exact test results and remaining native anchor/interval work; commit this change.

The phone's SDK clock export, native-to-worker attempt correlation, matched source
intervals, profile boundaries, capacity/pressure and impairment tests remain separate
required work. This field does not enable automatic quality changes.


## Verified implementation

The actual pipeline now labels its snapshots; the reporter negotiates before
sending the optional field, explicitly constructs the strict envelope and retains
capability across timing-token acknowledgments. Old and unknown server capabilities
preserve the old report shape without mutating the supplier. API immutability uses
the retained snapshot, so omitted reports cannot upgrade an originally unknown
convention later in the same attempt. New attempts/sessions may select a new one.
Swift preserves optional raw labels and recognizes the exact known convention.

Retained behavioral failures precede the implementations: nine API and thirteen
worker tests failed for missing advertisement/validation/forwarding/pipeline labeling;
Swift first failed because the label was dropped on round-trip, then failed exact
known-label recognition with its stub returning false. Final checks:

- API: 263 tests in 14 files pass (`worker-clock-api-green.log`).
- Worker: 179 tests in 12 files pass (`worker-clock-worker-green.log`).
- Native Core: 235 tests pass (`worker-clock-swift-core.log`), including unchanged
  old shared fixtures and the known/legacy/unknown signed-PTS fixture.
- Tooling: 431 tests pass (`worker-clock-tools.log`), including fixture parity.
- Protocol build and protocol/API/worker type checks pass.
- Core compiles for arm64_32 watchOS 10; combined unsigned iPhone/Watch Release
  builds successfully (`worker-clock-watch-build.log`, `worker-clock-apple-release.log`).
- Full local software-worker workflow exits 0 (`worker-clock-workflow.log`): native
  score overlay updates without encoder restart; process/API/source recovery and
  match-end shutdown pass. Media has audio and fresh video near 30 fps.

`native-worker-software/clock-observations.json` retains four authenticated
startup/recovery status snapshots with the known label, across attempts 1/1/2/3
(the repeated 1 follows process replacement). Those snapshots have no completed
window yet: they prove actual pipeline/reporter/API negotiation, not matched source
intervals or a loss denominator. Shared HTTP/Swift fixtures separately prove
completed-window label and signed-PTS preservation. Earlier software-worker evidence
was retained as `native-worker-software-before-clock-convention-20260915T211731Z`.
All paths above are under `artifacts/qa/`.

This completes convention negotiation. The native SDK anchor is still not exposed
through the app's publication observations. That integration and actual matching
source-interval counts remain the next prerequisite to automatic quality changes.


Independent specification and quality reviews approve the completed change.
The repeated attempt 1 in the workflow also makes the next identity requirement
concrete: worker attempt numbers restart when a process/session is replaced.
Correlation must distinguish those sessions, not use worker ID and attempt number
alone. The current label identifies a coordinate convention, not that missing
cross-process identity or the phone's publishing attempt.
