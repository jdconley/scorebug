# Staged Probe Status and Ownership Plan

> **For agentic workers:** Use superpowers:subagent-driven-development with bounded Core implementation and separate spec/quality reviews. Parent owns integration and heavy verification.

**Goal:** Carry authenticated v2 probe stages to the native receiver tracker and reject retired local observations across async reads.

**Architecture:** Preserve v1 compatibility, add explicit v2 stage/cumulative-byte validation in TypeScript and shared Swift, and preserve connection-level clock/accounting across stage changes. An SDK-owned synchronously revoked authority accompanies native snapshots through the streaming adapter and app. Stage plus UUID and publishing generation identify a probe; receiver reports never create local authority.

**Tech Stack:** TypeScript/Zod/Vitest, Swift shared Core/XCTest, native SRT/Testing, capture-model XCTest.

## Contract and implementation

- [x] Shared protocol/parser: accept the two explicit conventions. V2 requires integer stage 1...32 and canonical decimal `totalDeliveredPayloadBytes`, a multiple of 1316, at least current-stage bytes and at most 16 MiB. Pending packets reserve another entire message against the cumulative budget. V1 must not carry either v2 field; explicit null is invalid. Existing timestamp/sequence/identity checks remain. Add shared v2 golden bytes and parser/authenticated forwarding regressions before implementation.
- [x] Core: append optional `stage: Int?` and `totalDeliveredPayloadBytes: String?` with default nil to the wire value and optional stage to locally constructed expectation. Explicitly present null/wrong types cannot be decoded as absence. Freshness requires convention/stage match to local expectation. Golden round trips must preserve both formats.
- [x] Core tracker: keep current-stage windows separate from publication-level high water. Within one authenticated publication/native generation, v2 stages may only advance, with a different current UUID. Reject version changes and same-stage identity/rate changes. Keep clock offset intersection, serial receipt ordering, observed-time high water, total-byte monotonicity and quarantine across stages. Within-stage total deltas must equal stage-byte deltas; at a new stage total must cover all previously observed complete messages, any prior pending message and the new stage. New-stage first delivery cannot precede the prior receiver observation. Missing/stale evidence supplies no healthy credit. A new publication or explicit owner reset may clear state; a new stage may not clear a contradiction. Test valid stages/gaps, delayed old stages, scope substitutions, reused historical UUID with a newer stage, counter/clock inconsistencies, pending boundaries, quarantine and bounded memory.
- [x] Native ownership: the SDK creates a readonly authority for each real probe identity. Every terminal `stop` path revokes it under the existing synchronous probe lock. A retained immutable snapshot must stop permitting observations after cancellation, replacement, expiry, pressure, failure or close. Forward authority and optional stage through the streaming snapshot to app observations. Stage is nil for current live v1 probes. The app checks authority synchronously after its async snapshot read; observations in either format without ownership proof fail closed. Test a suspended read returning a revoked snapshot while recording remains active; the local health loop must also withdraw retained evidence before lease expiry and clear window continuity.
- [x] Capture matching/export: derive expected stage from the local observation; include stage/cumulative counters in bounded DEBUG evidence when present. Never derive expected stage from server JSON. The live scheduler remains single-probe until joined replacement and cumulative sender budgets are implemented.
- [x] Run focused red/green tests, full Core/SDK/streaming/model and relevant control-plane/tools tests, patch provenance, ARM64 simulator build and unsigned combined phone/Watch Release. Review spec then quality, preserve fresh evidence and previous frozen artifacts, update main plan and commit.

## Qualification boundary

This establishes authenticated identity and revocation, not measured spare capacity or an automatic upgrade decision. A real staged SRT experiment still requires the native replacement API, cumulative sender budgets and media qualification. Fresh candidate encoding cost, recovery, physical device routes and remote workers remain required by the main plan.


## Verified checkpoint

The API and shared Core now validate v2 without erasing stage identity; the app
constructs expectations from its native owner. Core keeps only the current stage
and publication high water. SDK authority is shared by reference through the
adapter and DEBUG wrapper, and terminal paths revoke it. Both formats require
native authority after async reads. Local health revocation/expiry clears retained
evidence and coverage, including the case where native renewal continued while
the app lost its observed lease.

Red tests reproduced unsupported v2, legacy stripping of stage fields, missing
native ownership, and retained evidence after revocation. The continuity regression
also fails under a mutation removing only the local-health `observe(nil)` call;
production source was restored byte for byte before the final suite.

Verification passes 397 Core, 206 SDK, 88 streaming, 479 control-plane, 1442 tooling,
and 292 final native-model tests. Workspace typechecking also passes. The ARM64 simulator build and unsigned combined
phone/Watch Release pass, including the Watch arm64_32 compiler target. SDK patch
provenance again round-trips all 162 original hashes. Spec and quality reviews are
approved; the suggested continuity regression has been added and reviewed.

Evidence and source hashes: `artifacts/qa/staged-probe-status-final-verification.json`.
Previously frozen deadline/wire evidence is unchanged. These results do not qualify
actual repeated SRT traffic, automatic quality recovery, candidate-cost admission,
physical devices or remote workers. Next implement native stage replacement that
joins the old wake/send owner, enforces cumulative byte/time/stage budgets and
revokes on pressure/reset/route/stop, then run real media qualification.
