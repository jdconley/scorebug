# Receiver Probe Status Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline under the existing autonomous authorization. Track the steps below.

**Goal:** Deliver authenticated receiver measurements to native code with conservative freshness and explicit local probe identity.

**Architecture:** Extend the private publication lookup with a separately sanitized snapshot. Attach it to current worker status only after rechecking scope, then validate its identity and age in shared Swift core.

**Tech Stack:** TypeScript/Zod/Vitest, Swift/XCTest, existing authenticated HTTP and ContinuousClock.

## 1. Contract and production API

Files: `packages/protocol/src/receiver-probe.ts`, `worker-status.ts`, `index.ts`;
`apps/control-plane/src/receiver-probe.ts`, `ingest.ts`, `relay-lifecycle.ts`,
`worker-publication.ts`; corresponding relay and status tests.

- [x] Add shared golden status fixture with a valid two-message snapshot; exercise
      its exact bytes in both languages. Add adapter tests for sanitization, counter
      conservation, canonical integers, zero/nonzero timestamp rules, packet/rate/clock
      bounds, unknown invalidity, and legacy absence.
- [x] Run the focused Vitest tests and preserve the missing-feature failure.
- [x] Add contract `WorkerReceiverProbe = { snapshot: ReceiverProbeSnapshot;
ageUpperBoundMs: number }`. Ingest parses only the selected publisher's optional
      snapshot using Zod, stripping unknown fields. Lifecycle returns
      `{ publication, receiverProbe? }` only after verifying the signed attempt.
- [x] Add status tests for attachment, scope change during lookup, unavailable
      measurement, preserved publication, and injected monotonic age rounding/faults.
      Run them red before implementing the timing boundary:
      `started = monotonicNow(); found = await relay.publication(before);`
      then resample status/scope and use `Math.ceil(monotonicNow() - started)` only
      for finite, nonnegative, safe-integer-bounded elapsed time.
- [x] Run `pnpm --filter @scorebug/control-plane test` and protocol/control-plane
      typechecks. Verify worker report injection remains rejected.

## 2. Native decoding and freshness

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerReceiverProbe.swift`,
`WorkerStatus.swift`, corresponding XCTest and fixture files.

- [x] Add golden round-trip, malformed optional decode, explicit expectation,
      immutable scope, arithmetic, last-delivery age, expiry, and wrong-scope tests.
- [x] Run `swift test --package-path ios/Packages/ScorebugCore` with the licensed
      Xcode 26.2 developer directory and preserve the missing-feature failure.
- [x] Add Codable value types. Decode optional report with `try?`, independently
      validate all scalar/cross-field invariants, require a locally supplied probe
      expectation, and capture scope by value. Use UInt64 for strings and Int64
      duration conversion so watchOS arm64_32 cannot overflow.
- [x] Compute receipt age as server upper age plus full request duration; later age
      adds monotonic residence. Last-delivery age additionally includes
      `observedAtNanoseconds - lastDeliveredAtNanoseconds`. No completed messages means
      last-delivery age is unavailable. Existing status lease limits every query.
- [x] Run all core tests, model integration tests, simulator build-for-testing and
      unsigned combined iPhone/Watch Release build sequentially. Review the diff and
      document measured results and remaining policy work; commit the checkpoint.

## Verification checkpoint

Implemented the additive contract and authenticated API path, native strict
optional decoding, explicit local-probe expectation, immutable scope, snapshot
age and last-delivery age. Publication equality remains unchanged. Cache bypass
covers the native status request and private relay request; the existing public
`no-store` response is asserted.

Review found the relay's whole-message reservation rule also applies to pending
packets at the 16 MiB boundary. Matching API and Swift regressions failed before
the correction and now pass. Explicit-null optional snapshot fields also fail
closed without invalidating ordinary status. Follow-up review found no further
issues in those fixes.

Verified with licensed Xcode 26.2:

- 437 control-plane tests and protocol build; control-plane typecheck passes.
- 307 shared native core tests, including native HTTP decoding/cache behavior.
- 222 capture app model tests.
- ARM64 simulator build-for-testing and unsigned combined iPhone/Watch Release
  build pass; this is compilation, not physical-device qualification.
- Shared golden fixture bytes match; diff whitespace checks pass.

Evidence: `artifacts/qa/receiver-status-verification.json` and the referenced
`receiver-status-*.log` files. This phase does not repeat the earlier actual
marked-probe media trial or claim automatic adaptation is qualified.

Next connect an owned production probe to this expectation, construct causal
receiver intervals with bounded age, reconcile sender acceptance, and qualify
candidate cost. Repeated/staged probing is still required because the current
sender and relay retain one probe attempt per connection. Production automatic
upgrades remain disabled. Phone/Watch networking, other proxy hosts, and long
soaks retain their separate qualification gates.
