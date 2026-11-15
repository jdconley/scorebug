# Pipeline geometry correlation implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development, then independent specification and quality review. Root owns documentation and commits.

**Goal:** Join proxy decoded-dimension evidence to the exact native accepted source window without exposing private read IDs or inferring identity from process ordering.

**Architecture:** The supervisor already creates an opaque UUID for each actual relay read; authenticated reporting and relay lookup already validate that association. Derive a public, domain-separated SHA256 correlation key on both sides of that existing association. Pass the private ID through typed worker startup metadata, never recover it from a logged URL. Expose only the derived key and the accepted decoded interval in native diagnostics.

**Tech Stack:** Node crypto, TypeScript protocol/control plane/worker, Swift Codable/Core/app diagnostics, existing ownership and freshness tests.

## Status and invariants

**Completed source dependency:** reviewed and committed as `026189c`; test and hash evidence is recorded in the [session log](../../session-logs/2026-09-26-pipeline-geometry-correlation.md). The future recovery720 checker remains separate.

This dependency follows the [decoded geometry observer](2026-09-26-decoded-geometry-evidence.md) and precedes the explicit ordinary recovery720 lane. It does not enable the higher ladder. Public keys identify evidence; they grant no permissions and establish neither freshness, delivered quality nor capacity. Keep authentication and existing before/after scope checks unchanged.

`pipelineOrdinal` is diagnostic log ordering, not supervisor attempt. Relay `readerId` differs from private `pipelineReadId`. One worker process is insufficient evidence that a decoder belongs to the native observation. Preserve the protocol invariant that raw private read IDs are never copied into public observations.

## 1. Shared derivation and typed worker identity

Files: protocol helper/export and tests; `apps/home-daemon/src/supervisor.ts`, `index.ts`, `worker-terminal.ts`; their existing tests.

- [x] Define a platform-neutral helper returning the exact hash input only for a canonical lowercase UUID. Use the existing canonical UUID shape (36 ASCII characters, hyphens at8/13/18/23, lowercase hexadecimal elsewhere). Export it through the protocol package. Test malformed, uppercase, whitespace/control, overlong and absent inputs, plus a fixed golden vector.

```ts
export const PIPELINE_READ_KEY_PREFIX = 'scorebug-pipeline-read-v1:';
// validate the complete canonical UUID before returning this value
return PIPELINE_READ_KEY_PREFIX + pipelineReadId;
```

Node callers derive the key using:

```ts
createHash('sha256').update(input, 'utf8').digest('hex');
```

- [x] Add a third optional readonly argument `start(input, onProgress, metadata?)`, preserving compatibility with existing two-argument callbacks. Populate metadata from the already-generated `identified.pipelineReadId`. Preserve the existing identified URL and private reporter observation exactly. Metadata is immutable and tied to that single call. Invalid or unsupported identity omits the key and never fails pipeline startup. Do not generate another ID or parse the URL again.
- [x] Pass metadata to terminal scope creation. Derive optional `pipelineReadKey` there, validate before hashing, and attach it to geometry/terminal records. Unsupported URLs retain absent identity. Tests must prove two starts get distinct keys, matching the IDs retained by their reporter observations for the same start and a retry, and invalid metadata cannot appear as a public key. Keep raw ID/URL/token out of logs.

## 2. Publish only the authenticated derived association

Files: `packages/protocol/src/worker-status.ts`; `apps/control-plane/src/worker-publication.ts` and `test/worker-publication.test.ts`; `ios/Packages/ScorebugCore/Sources/ScorebugCore/WorkerPublication.swift` and corresponding tests/fixtures.

- [x] Add optional `pipelineReadKey?: string` to public WorkerPublication. This is separate from private WorkerObservationRequest.pipelineReadId. Existing clients/fixtures without the optional field remain valid.
- [x] In `publicationStatus`, only after `found && after && canonical(before) === canonical(after)`, derive the key from the validated `before.pipelineReadId` and copy it into the returned publication. Construct a new publication, overriding or discarding any key in found.publication; explicitly test malicious key substitution. Never copy an unverified key returned from elsewhere. Failed relay lookup, changed epoch/attempt/game/generation/read ID, ambiguous relay readers or stale scope cannot publish the key.
- [x] Add mutation tests for read-ID substitution, reporting-scope changes while relay lookup awaits, and absent/invalid ID; keep existing before/after tests. Golden key must match worker derivation for the same UUID. No authentication, route selection or capacity policy changes.
- [x] Swift WorkerPublication gains optional `pipelineReadKey: String?` and a default-nil initializer argument. When present, validatedPublication requires exactly64 lowercase ASCII hexadecimal characters. Absence remains compatible; new geometry qualification later requires presence. Include Codable roundtrip, invalid-key and legacy fixture tests.

## 3. Retain accepted native decoder coordinates

Files: `ios/Sources/Scorebug/Capture/PublishingQualitySession.swift`, `PublishingQualityDriver.swift` only if budget handling needs a verified change, and app model tests.

- [x] Extend DEBUG acceptedSourceMapping with the key and previous/first/last decoded PTS plus decoded frame count from the exact accepted WorkerSourceIntervalObservation. Do not combine current publication identity with an older accepted interval. Include the optional key in currentSourceIdentity hashing only when present, preserving legacy nil-field hashes.
- [x] Emit the following only under the existing owner/sequence/window-match conditions:

```text
policyPipelineReadKey
policyDecodedPreviousPTS
policyDecodedFirstPTS
policyDecodedLastPTS
policyDecodedFrameCount
```

Use signed integer decimal strings in the existing1/90000 decoded clock; do not reuse the nonnegative floating-time diagnostic parser. Preserve source-PTS/capture-uptime mapping and source scope. Missing identity stays missing. Tests reject stale accepted state, changed scope, closed session and unavailable key; test exact values from a validated observation.

- [x] Verify populated pressure-cause plus pending/application/trial diagnostics remain at most4096bytes, with these protected fields and appliedTransition preserved. Do not silently leave older diagnostics visible if the protected payload cannot fit. Resolve demonstrated budget failures explicitly without removing ownership or causal evidence.

## 4. Verification and completion

- [x] Run protocol tests/build, targeted control-plane association/race tests, worker supervisor/terminal tests and typechecks. Run affected SwiftCore/app model tests plus DebugUI and Release builds with installed toolchain only.
- [x] Preserve executed commands, logs, counts and hashes; perform independent specification then quality review, verify reviewed blobs and commit the dependency.
- [ ] Independent recovery720 checker will require a unique complete geometry terminal for the key, expected game/generation and geometry coverage of the accepted decoded interval, with decoder lifetime totals matching the existing metadata observer. Use matched native metadata for the accepted frame count; run summaries do not reconstruct every interior PTS. Require the first/last accepted decoded endpoints to lie in the expected geometry run and preserve the exclusive previous anchor semantics. This future checker must reject duplicate keys, omitted geometry, invalid/unfinished observer, unexpected dimensions, inconsistent frame counts and unmatched boundary coverage. It will separately validate native applied-format receipts and allthree final media outputs.

No live hardware capture overlaps builds or heavy media analysis. No new permission, API credential or public read selector is introduced.
