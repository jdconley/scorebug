# Watch scoring codec implementation contract

The codec boundary is implemented in ScorebugCore and independently reviewed.
It does not itself implement or qualify companion delivery. Focused TDD first
fails for the missing API, then passes 13 tests with terminal exit 0. The initial
green compilation's test-expression type-check timeout is retained separately;
splitting that expression resolves it without changing the acceptance case.

## Recommended wire shape

Use a dedicated version-1 JSON Data payload, separate from application-context
setup. Immediate scoring uses sendMessageData; application context remains reserved for
setup. The codec accepts Data, not arbitrary URLRequest or caller-selected HTTP paths.

Request has exactly `version`, `requestId`, `scope`, `credential`, `operation`.

- `requestId`: a new 36-byte UUID for this transport request. This is distinct from
  the durable scoring commandId, which must survive route changes and recovery.
- `scope`: exactly `{ endpoint, gameId, watchDeviceId, pairingId }`. Endpoint must
  equal `ScoringEndpoint(endpoint).canonicalAddress` byte-for-byte. Use the existing
  pairingId UUID as the pairing generation: every replacement pairing has a new
  issuance identity. Do not invent a numeric generation that the current setup
  exchange cannot corroborate. Any later peer/session generation is additional
  local ownership state, not a replacement for this persisted pairing identity.
- `credential`: existing MatchCredential, with matching gameId/deviceId, declared
  role `score`, and the Watch's token. Never substitute phone authority.
- `operation`: a closed union: `{type: snapshot}`, `{type: execute, command: ...}`,
  or `{type: receipt, commandId: ...}`. No extra keys or other operation names.

Phone dispatch must compare the whole scope to its durable authorized binding,
including pairingId, before constructing its own HTTP client from that binding.
Codec validity alone never authorizes a requested endpoint. The Watch's declared
role and identity do not authenticate its opaque token; each forwarded request
still requires server authentication. The phone stores neither credential token
nor request payload in its nonsecret pairing binding or logs.

Reply has exactly `version`, `requestId`, `scope`, `operation`, `result`. Echo the
request identity, complete scope, and operation tag. Decode against the expected
request, not merely as a standalone success object. For execute/receipt, also
match any returned commandId; all snapshots must match scope.gameId. Snapshot's
current scorer may legitimately be another device after takeover and must not be
forced to equal the requesting Watch.

Result is a closed union:

- snapshot operation: `{type: snapshot, value: MatchSnapshotResponse}`.
- execute operation: `{type: outcome, value: CommandOutcome}`.
- receipt operation: `{type: receipt_found, value: CommandOutcome}` or
  `{type: receipt_absent}`.
- any operation: `{type: failure, error: ...}` with a small typed error below.

No result can carry two branches, optional success fields, or a credential.

## Limits justified by current sources

Authoritative validation is in `apps/control-plane/src/routes/matches.ts`, not the
TypeScript-only aliases in `packages/protocol/src/matches.ts`. Current server
limits: identifiers 1–128 ASCII `[A-Za-z0-9_-]`; team names 80 UTF-16 code units,
short names 8; color seven ASCII characters; reasons 500 UTF-16 units after trim;
bestOf 3 or 5; targets 1–99; winBy 1–10; pointCap null or at least both targets and
at most 199. Expected revision is 0…MAX_SAFE_INTEGER, scorer epoch 1…MAX_SAFE_INTEGER.

`scoring.ts` prevents another completed set after a best-of win, so snapshots
produced by current scoring contain at most five completedSets. It does NOT cap
points at the target or pointCap: award_point can continue until explicit end_set.
Do not introduce a 99/199 score cap in this codec. Represent score/count/revision
integers exactly, rejecting unsafe numeric representations rather than rounding.

Conservative compact JSON sizing: five 500-unit override reasons plus one
500-unit end reason require at most 18,000 bytes even if every code unit requires
a six-byte JSON escape. The four team strings add at most 1,056 escaped bytes.
Identifiers, safe-integer scalars, enum strings, dates, and all fixed JSON keys
comfortably fit another 4 KiB. Thus a 32 KiB reply ceiling supports even this
conservative maximal current snapshot, including envelope scope. The real shared
`match-v1.json` snapshot has no completed sets and short team strings, far below
this bound; the acceptance fixture must also exercise five maximal reasons.

Recommend 16 KiB request and 32 KiB reply, checked before parsing and after
encoding; maximum JSON nesting depth 12; no arrays except completedSets, capped
at five; exact object key sets at every nested model. Cap canonical endpoint at
4,096 UTF-8 bytes and date strings at 128 bytes. The existing SHA-256 base64url
credential issuer produces exactly 43 ASCII base64url token bytes; accept that
version-1 token format without interpreting it as proof of authority. A maximum
500-unit normalized reason needs at most 3,000 escaped bytes, leaving generous
request space for an exact command, credential, and scope. Preserve command
strings unchanged; never trim/reformat the durable request during relay.

Important qualification: there is no finite maximum for every theoretically
server-accepted wire request today. URL length is not bounded by ScoringEndpoint,
ISO date fractional precision has no explicit route length cap, and the server
trims reason input before its 500-unit check (arbitrary surrounding whitespace).
The proposed wire/date/endpoint limits are therefore explicit transport limits,
not a claim that the current server already enforces them. Oversized requests
fail before sending and preserve pending commands. Likewise score/revision
overflow is not comprehensively guarded in server increment logic; safe-integer
checks should fail conservatively, not silently coerce it. Do not describe a
representative fixture measurement as a proof of every possible legal payload.

## Strictness and semantics

Validate JSON structure before typed Codable decoding: required/unknown nested
keys, union-specific keys, booleans versus integers, finite exact integers,
non-null required values, nullability, string bounds, and array bounds. Synthesized
Codable alone ignores unknown keys. Explicitly reject duplicate JSON member names
using a bounded preflight parser/scanner; JSONSerialization's resulting dictionary
alone cannot prove duplicates were absent. Bound depth before recursive model
validation. Avoid canonical-byte equality as a substitute: valid field ordering
and escaping can differ without changing the exact command values.

Use the existing TS operation shapes: end_set winner/reason remain independently
optional at the syntax layer. Incomplete override combinations reach the server
and produce an authoritative domain rejection. Do not locally change the domain
rules or manufacture CommandOutcome. Use UTF-16 length where mirroring JS string
limits; Swift String.count counts grapheme clusters and is not equivalent.

CommandOutcome requires accepted true with null error, or accepted false with a
nonempty bounded ASCII error code. Preserve recognized or future bounded domain
codes rather than treating a rejection as transport failure. Normalized snapshot
reasons fit 500 UTF-16 units. Snapshot dates and server time must decode as actual
ISO dates, while original strings remain unchanged. Reuse the current models as
the typed return values after validation.

Failure payload is a typed enum: unauthorized, forbidden, http(status, code?),
invalidResponse, invalidRequest, scopeMismatch, unavailable, cancelled, busy.
HTTP status must be an integer in 100…599; code is null or 1–128 ASCII code bytes.
No raw response body, exception text, token, endpoint credentials, or stack trace.
Map HTTP client errors faithfully where safe; unknown exceptions become
unavailable. Codec/transport errors must throw at MatchScoringClient, never return
nil receipt or a fabricated rejected outcome.

Only an actual successful receipt lookup with exact server command_not_found
semantics can emit receipt_absent. Timeout/cancellation/unreachable/malformed/
oversized reply cannot establish whether execute committed. The Watch keeps its
outbox, and only coordinator receipt-first recovery decides whether a mutation
may be retried. A failure result must not act as automatic fallback permission.
Even a claimed local pre-dispatch failure does not prove a previous attempt never
committed. Successful replies still require the coordinator's durable clear
before user acknowledgment.

## Acceptance evidence for implementation

Round-trip all three operations and all valid result branches using shared fixture
models; exact durable execute values must survive the codec. Add maximal name/
reason UTF-16 cases with escaping and five sets; include scores above 199. Verify
the actual encoded size stays under the chosen ceiling. Test just-at/one-over
byte bounds, depth/count limits, unknown/duplicate nested keys, wrong JSON scalar
types, unsafe numbers, malformed dates, wrong union branches, contradictory
outcomes, snapshot game mismatch, commandId mismatch, and every scope/request
correlation mismatch. Verify a different current scorer remains valid. Capture
role, installation/setup/media operations, arbitrary URL/path/header fields, and
credential mismatches fail before dispatch. Unauthorized bearer verification
requires server-backed tests later; an opaque token-format check cannot prove it.

Transport/lifecycle work later must independently test duplicate delivery,
superseded pairing and local session generations, bounded in-flight ownership,
late callbacks, lost execute replies, and receipt absence versus lookup failure.

## Platform validation findings

Integer JSON values require exact integer spelling: decimal/exponent numeric
lexemes are rejected before Foundation decoding can round them. Native `Int`
representation is an additional ceiling. The initial Watch Release build caught
the JavaScript safe-integer constant overflowing on arm64_32. The implementation
now declares the constant as Int64 and clamps the accepted bound to native Int,
so large values are rejected before typed decoding rather than truncated. The
subsequent Release iPhone build succeeded, including both arm64 and arm64_32
Watch architectures (`watch-relay-phone-release.log`, terminal exit 0).

The maximal escaped snapshot fixture has five alternating winners and 3–2 set
totals. It verifies payload size and codec round trips; it is not a scoring-engine
progression test. Exact tests/logs are `WatchRelayCodecTests.swift` and
`artifacts/qa/watch-relay-codec-{red,green}.log`; the failed Watch build is retained
as `watch-relay-watch-release-initial.log`.
