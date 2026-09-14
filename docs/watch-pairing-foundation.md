# Native Watch pairing foundation

The API and shared Swift client now support giving each Watch its own match-scoped
scoring credential. Pairing does not select a camera, start a stream, change the
score, or take over scoring. Native phone setup screens, Keychain adapters,
WatchConnectivity setup exchange, and the Watch app target remain to be connected.

## Recovery contract

An installation-authorized phone issues a five-minute capability bound to a match,
pairing UUID, and Watch device UUID. Exact issuance retries return the same capability
and expiry. Only its digest is stored in SQLite. Each match retains at most 64
pairing records; uncertainty records are not silently evicted.

The Watch generates its own redemption UUID and 256-bit recovery secret. Before
sending anything, the shared setup coordinator atomically saves the exact endpoint,
capability, request, and recovery key. The server consumes the capability, creates
the scoring credential, and records the redemption in one SQLite transaction.

A lost response is uncertain, not a failed pairing. An exact retry with the same
recovery key recovers the same credential after expiry, process restart, or match
end. Another device/request/key cannot recover it. Credential-key changes fail
closed rather than silently issuing a different credential. Existing installation
join authorization and token generation remain unchanged.

An unused expired capability cannot create a credential. When the server observes
that definitive expiry, it commits a terminal marker before returning the error.
Later clock rollback cannot make the capability usable again. Database version 4
adds that marker without replacing existing version 3 pairing records.

## Shared Swift lifecycle

`WatchSetupCoordinator` uses injected atomic storage and HTTP transport. Its record
has no installation-token field. Native production storage must use device Keychain;
the local integration probe's private file store is only a test adapter.

The coordinator validates returned pairing/redemption IDs, Watch and match identity,
scoring role, snapshot identity, and server time before saving the credential. A
failed save after server success retains the pending attempt. Cancellation checks
reject late replies, and a busy guard prevents a concurrent setup operation from
replacing the current one. Recovery requests have stable JSON bytes and headers.

Malformed or unreadable saved setup is never silently replaced. Recovery keys must
be canonical base64url encodings of exactly 32 bytes, matching the server's rules.
The pending command store blocks a setup change while scoring is uncertain. The
native owner must quiesce its scoring coordinator before an explicit setup switch;
these stores have one active owner. Repeated setup messages cannot replace an
already committed credential without an explicit replacement action.

Explicit discard retries the original redemption first. A committed result is
recovered; only the definitive unused-expiry response permits clearing the attempt.
Scoring itself continues through the existing durable command coordinator, using
an endpoint and credential fingerprint as its nonsecret outbox scope. Takeover
remains an explicit scoring operation.

## Evidence

- 207 API tests pass, including 20 pairing tests, real competing Node processes,
  injected transaction failures, restart/retry, clock rollback, key rotation,
  strict authorization/schema checks, and scorer/capture/broadcast invariance.
- All 106 Swift Core tests pass, including shared wire fixtures, lost responses,
  pre-send and post-success storage failure, cancellation, stale setup messages,
  wrong identities/roles, malformed stored keys, and pending scoring protection.
- The complete TypeScript/tool regression suite and type checking pass. Core
  compiles for arm64_32 watchOS 10, and the Release iPhone app build passes.
- A real URLSession probe dropped an actually committed pairing reply, stopped and
  restarted the SQLite API, and launched a fresh Swift process. It recovered the
  original attempt, verified no implicit takeover, then explicitly took over,
  scored, undid the point, and ended the test match. No browser scorer was used.
- Independent specification and quality reviews approved both server and Swift
  implementations after the expiry-finality and canonical-key corrections.

Logs are under `artifacts/qa/watch-pairing-server/`,
`artifacts/qa/watch-pairing-core-final.log`, `watch-pairing-regressions.log`,
`watch-pairing-typecheck.log`, `watch-pairing-watchos10.log`, and
`watch-pairing-release-iphone.log`. The local probe's source, private fixture state,
and prepare/recover logs are in `artifacts/qa/watch-pairing-live/`.

This qualifies the shared pairing and native client/server path. It does not yet
qualify the Watch UI, companion transfer, radio handoffs, or wrist suspension. The
next integration step is the native Watch target and phone setup flow, followed by
paired simulator workflows and real Ultra 2/Series 7 testing.
