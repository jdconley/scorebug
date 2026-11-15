# Public worker epoch implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the
> bounded native-client task and independent specification then quality reviews.
> Parent owns API/protocol/fixture changes and all media/build execution except
> an explicitly handed-off Swift test interval. Never edit the original checkout.

**Goal:** Give native consumers a public session identity so repeated worker attempt
numbers after worker/API replacement cannot identify the same observation scope.

**Architecture:** Allocate an independent opaque `workerEpoch` UUID for each
process-local worker reporting session. Return it only alongside an accepted report
matching the selected worker, match and broadcast generation. Keep private session
IDs and timing tokens out of public status; legacy responses omit the new field.

**Tech stack:** TypeScript protocol, existing authenticated Hono status route,
Swift Codable shared by iPhone/watchOS, Vitest/XCTest and local worker fixture.

## Design decisions

A numeric attempt alone repeats across processes. Exposing the existing private
reporting session would break the current public-status boundary. A deterministic
hash of it adds an unnecessary relationship to a private value. A separate random
UUID is cheap, opaque and makes the lifecycle explicit. It is diagnostic metadata,
not authorization, freshness, readiness, a relay mapping or a source-loss count.

The epoch is stable for idempotent registration, duplicate/new reports, TTL expiry,
and pipeline retries in a session. Worker replacement and API process replacement
allocate a new value, even when the worker's run ID and attempt repeat. Unknown,
stopped and mismatched-generation status omit it because they have no corresponding
report. Clients decode an optional opaque string without synthesizing a fallback.
Stale status retains the report's epoch but stays stale. Existing strict request
schemas reject client-supplied epochs. No adaptive consumer is enabled here.

## Task 1: Server lifecycle and public wire

Files: `packages/protocol/src/worker-status.ts`,
`apps/control-plane/src/worker-observations.ts`,
`apps/control-plane/test/worker-observations.test.ts`,
`apps/control-plane/test/worker-status-contract.test.ts` and
`apps/control-plane/test/worker-report-age.test.ts`.

- [x] Add behavioral HTTP tests for initial absence; matching report publication;
      same-run registration/report/attempt stability; stale retention; worker replacement
      with repeated attempt; API restart with repeated run; stop/generation absence;
      invalid/replayed reports not changing epoch; and no private credentials in status.
      Use the existing `fixture()` HTTP setup, for example:

```ts
expect((await f.status()).status.workerEpoch).toBeUndefined();
expect((await f.report()).status).toBe(200);
const initial = (await f.status()).status.workerEpoch;
expect(initial).toMatch(/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/);
expect(initial).not.toBe(f.session.sessionId);
expect(initial).not.toBe(f.session.timingToken);
expect((await f.report()).status).toBe(200);
expect((await f.status()).status.workerEpoch).toBe(initial);
```

- [x] Run red: `pnpm --filter @scorebug/control-plane test -- worker-observations.test.ts`.
      Require a missing-epoch assertion failure before implementation; save the log.
- [x] Add the optional public field and independent session storage:

```ts
// WorkerMediaStatus
workerEpoch?: string;
// Session
workerEpoch: string;
// New Session in register()
workerEpoch: randomUUID(),
```

Resolve one `session` in `status()`, derive its report, and include
`workerEpoch: session!.workerEpoch` only in the existing final matching-report
response. The no-report base remains unchanged; the method is synchronous.

- [x] Run green plus API/protocol/worker type checks. Existing auth, strict payload,
      retirement, age and counter-reset tests must continue to pass.

## Task 2: Native wire compatibility

Files: `packages/protocol/fixtures/worker-epoch-v1.json`,
`ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/Fixtures/worker-epoch-v1.json`,
`ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerStatus.swift`,
`ios/Packages/ScorebugCore/Tests/ScorebugCoreTests/WorkerStatusTests.swift`,
`scripts/test/contracts.test.mjs`.

- [x] Create byte-identical fixtures for `current`, `stale`, `replacement` and
      `legacy`. Current/stale use UUID `d6c217a3-27c5-44ea-a55e-3b951c67981f`;
      replacement uses `d1e71c84-e637-4215-b5d2-3840e5a6fe40` with the same worker and
      attempt; legacy omits the field. All use the existing worker-status wire shape.
- [x] Add Swift failing round-trip checks: read `[String: WorkerMediaStatusResponse]`,
      encode with `JSONEncoder`, compare `NSDictionary` to original JSON. This fails
      behaviorally because current decoding discards the unknown epoch. Then assert
      native current/stale equality, replacement inequality, legacy nil and HTTP decode.
- [x] Add `public var workerEpoch: String?`, an initializer argument
      `workerEpoch: String? = nil`, assignment, `CodingKeys.workerEpoch`, and
      `encodeIfPresent(workerEpoch, forKey: .workerEpoch)` to `WorkerMediaStatus`.
      Keep synthesized optional decoding and existing initializer call sites compatible.
- [x] Add a tooling fixture parity test and run full Core tests (Xcode 26.2),
      full tooling tests and arm64_32 watchOS 10 Core build. Wrong JSON types must fail;
      epoch text is opaque and alone never proves a complete observation scope.

## Task 3: Production path evidence and review

Files: `scripts/test-worker.mjs`, `docs/worker-decoded-video.md`,
`docs/adaptive-telemetry.md`, this plan.

- [x] Extend the existing real worker fixture's `ready()` evidence with a UUID
      assertion. After worker crash/restart require a different epoch; after API restart
      require another new epoch; after source recovery require the same API/session
      epoch. Store full scoped statuses in the existing bounded clock proof artifact.
      These are the same lifecycle assertions proven red in the HTTP tests.
- [x] Run the full software-worker fixture with Xcode 26.2 environment and retain
      process/source/API recovery, native score overlay and match-end checks. Run the
      combined unsigned iPhone/watchOS Release build. Do not rerun unchanged media
      quantization qualifications: this change does not touch the encoder pipeline.
- [x] Obtain independent specification and then quality review; resolve findings.
      Record actual test/fixture outcomes, hashes and remaining relay mapping work;
      update documentation and commit the verified bounded change.

## Scope still required for the full goal

An epoch is one scope component. The app still needs authenticated publisher-epoch
relay mapping, matched source intervals, profile transition/capacity qualification
and impairment traces before automatic quality adjustment. Physical phone/watch
radio and remote GPU/cloud validation remain separate. Keep the full goal active.

## Verified outcome

The HTTP tests first fail six missing-epoch assertions; Swift first fails the
fixture round trip because the unknown field is discarded. After implementation,
all 269 API tests, 239 Core tests and 526 tooling tests pass. Protocol, API and
worker type checks pass. Existing canonical status/age assertions now explicitly
validate the added UUID while retaining exact comparison of all original fields;
the legacy fixture itself is unchanged.

The complete software-worker workflow exits 0. Its four authenticated status
snapshots show three distinct epochs: initial attempt 1, replacement-worker attempt
1, replacement-API attempt 2, then source-recovery attempt 3 sharing the third
epoch. Evidence is retained in `artifacts/qa/worker-epoch-software-ig08j1nx`;
prior mutable fixture artifacts were copied before rerunning. Source recovery
returns output in 8,215 ms, within the existing ten-second gate. Scoring changes
the overlay without restarting the encoder; crash reaping, API lease expiry,
source loss/recovery, moving-frame cadence and match-end shutdown all pass.

Core compiles for arm64_32 watchOS 10. The combined unsigned iPhone/Watch Release
build passes under Xcode 26.2. Independent specification and quality reviews
approve the change. Logs use `artifacts/qa/worker-epoch-*`; final source/evidence
hashes and check outcomes are in `artifacts/qa/worker-epoch-final-verification.json`.
These results qualify public session identity and existing local workflows, not
publisher-to-relay mapping, runtime adaptation or physical radio performance.
