# Native publishing-attempt grants implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the
> bounded Swift implementation and independent specification then quality reviews.
> Work only in the validation worktree. One owner executes Swift/Go/media builds;
> pure Node tests can run separately. Continue under the user's autonomous approval.

**Goal:** Bind each native publishing attempt to an authenticated private SRT query
that survives the real app-to-relay connection, without restarting the media path.

**Architecture:** The selected capture requests access with its existing local
attempt UUID. The API signs that UUID and the already authorized generation-specific
path with its installation secret. The returned SRT stream ID carries the signed
query. Swift checks the response and query identify its requested attempt before
starting the publisher. The relay's existing private connection API retains the
query. A verifier returns only the UUID, never the proof or credentials.

**Tech stack:** Node crypto HMAC-SHA256, existing authenticated media route, Swift
MatchHTTPClient/CaptureStreamingModel, real encrypted SRT/native simulator fixture.

## Design

Keep the current path/read/publish encryption capabilities stable for a broadcast
generation. Changing paths on every retry would require durable coordination and
could interrupt recovery. An unsigned query would allow accidental or deliberate
relabeling of an attempt. Use a signed query with exact bounded syntax instead:

```text
streamid=publish:<existing-path>:sbp1=<lowercase-UUID>.<64-lowercase-hex-HMAC>
HMAC input = JSON.stringify(['scorebug-publish-attempt-v1', path, publishingAttemptId])
```

The private proof is scoped to installation, match, selected worker/output/capture,
recording and generation through the existing HMAC-derived path. It is an identity
attestation, not a new publishing authorization, revocation mechanism or freshness
claim. Anyone holding a valid URL may replay that same attempt; current publication
UUID and actual reader association must distinguish connections. Keep the proof out
of public state/logs. Absence or malformed/unverifiable queries mean unknown.

`publishingAttemptId` is optional on the API request for legacy callers. Omitted
requests retain their exact existing URL/response shape. Present IDs must be canonical
lowercase UUID strings; reject invalid values before relay I/O. Echo the ID in the
private access response only when requested. Swift's optional UUID argument defaults
to nil; the filming model always passes its current attempt. A requested ID requires
an exact response echo and one canonical stream ID whose query contains that ID.
Missing/mismatched/malformed attempt responses fail before publishing. Old APIs that
cannot issue the new grant cannot silently claim attempt association.

This step does not enable adaptive quality or publish source-receipt claims. Next:
capture the publisher UUID when a relay reader is attached, tag each worker pipeline
read distinctly, then associate authenticated attempts, actual reads and workerEpoch
in bounded server-owned status. Looking up the current path publisher alone cannot
prove what a previously opened reader is receiving.

## Task 1: API grant and verifier

Files: new `apps/control-plane/src/publishing-attempt.ts` and matching test;
`relay-lifecycle.ts`, `routes/media.ts`, their tests.

- [x] Add failing tests for stable per-attempt signing, different IDs, wrong secret/path,
      changed generation/selection, malformed/case/length values, signature tampering,
      duplicate/trailing query content, legacy omission and unchanged base capabilities.
      Use `publishAttemptQuery(secret, path, id)` and
      `verifyPublishAttemptQuery(secret, path, query): string | undefined`.
- [x] Implement bounded canonical parsing and timingSafeEqual for fixed-length digest
      verification. Invalid signing inputs throw `invalid_ingest_identity`; verification
      returns undefined. HMAC uses the exact array above, keeping this domain separate
      from path/passphrase derivation.
- [x] Extend PublishRequest/PublishAssignment with optional `publishingAttemptId`.
      Validate/sign before relay I/O after existing capture/generation checks. Set the
      returned URL streamid to `publish:${path}:${query}`; do not mutate the base grant.
      Existing serialized generation checks, reconciliation and read URLs stay intact.
- [x] Route accepts only canonical optional UUID. Tests exercise authorized response,
      other capture/scorer denial, invalid fields, private-state exclusion, idempotent
      retry/API lifecycle reconstruction and stale-generation races. Run full API tests
      and typecheck; record actual red/green evidence.

## Task 2: Native request and lifecycle

Files: `ios/Packages/ScorebugCore/Sources/ScorebugCore/{MatchHTTPClient,MediaModels}.swift`,
`Tests/ScorebugCoreTests/PublishAccessTests.swift`,
`ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`,
`ios/FilmModelTests/CaptureStreamingModelTests.swift` and only directly affected fixtures.

- [x] Add fail-first request/response tests. New optional argument is
      `publishingAttemptId: UUID? = nil` before `credential`; wire string uses
      `uuidString.lowercased()`. Require exact echoed string for requested IDs. Require
      exactly one streamid `publish:scorebug-<16hex>-<32hex>:sbp1=<ID>.<64hex>`.
      Native checks identity/syntax, not the secret HMAC. Reject duplicate streamids,
      malformed proofs, missing/other echoes, and a URL for another attempt.
- [x] Add optional UUID to PublishAccess while preserving redacted descriptions.
      Legacy nil callers omit the request key and accept existing responses. Filming
      model passes the same UUID used in VideoFrameObservationScope. Tests prove two
      starts use distinct attempts and returned URL identity matches diagnostic scope;
      late responses/network errors leave local capture active and start no stale publisher.
- [x] Run focused/full Core tests and FilmModel tests. Preserve legacy and Watch callers.
      Return sole build/media execution ownership to parent.

## Task 3: Real connection evidence and review

Files: `scripts/native-streaming-fixture.mjs`, `scripts/test-native-app.mjs`,
new bounded evidence helper/test if needed, native publishing documentation.

- [x] During owned simulator streaming, inspect the private relay connection list;
      verify the signed query against the fixture installation secret and current
      generation-specific path, save only publication UUID/path/attempt ID. Require
      one observed publishing attempt and compare it to exported native diagnostic
      scope. Bound collection, discard private query/user/address, join on cleanup.
- [x] Run iPhone 14/iOS 17.5 native streaming with real API/relay/worker, score update,
      complete clean archive, >=24fps acquired live interval, A/V checks and cleanup.
      Keep the existing media gates unchanged. Build combined unsigned iPhone/Watch
      release and lower watchOS architecture where affected by public Core changes.
- [x] Obtain independent specification then quality review; resolve findings. Record
      source/evidence hashes, actual process exits, limitations and next actual-reader
      association task, then commit. Overall goal remains active.

## Verified outcome

Implemented and qualified 2026-09-15. API behavioral red: 14 failures; asynchronous
request-mutation regression separately failed before copying the request. Final API
tests: 292 passed; typecheck passed. Native Core red: 27 assertions across 10 tests;
Film red: 13 assertions across two tests. Core full: 244 passed; Film full: 97 passed.
Independent fixture oracle red: 11 failures, then 11 passed; full tools: 572 passed.

Real iPhone 14/iOS 17.5 workflow `native-app-PO8n7D` passed with a requested 30-second
hold and direct RTMP recorder. Relay observed a valid signed native attempt matching
exported diagnostics. Archive: 1,843 pictures, 30 fps, zero loss in its full interval.
Live: 1,431 pictures, 30 fps, zero loss in the acquired interval; 60 startup pictures
remain explicit and no encoded tail is missing. Scoring, A/V, archive continuation,
terminal exits and owned cleanup pass. Unsigned combined iPhone/Watch Release and
arm64_32 watchOS 10 Core builds pass. Both independent reviews approve.

No default relay-image or adaptive policy change. Next integration captures the
publisher UUID atomically when an actual relay reader attaches, then associates
that reader with a distinct worker pipeline read and the reporting workerEpoch.
Native attempt grants alone cannot establish that association or source receipt.
