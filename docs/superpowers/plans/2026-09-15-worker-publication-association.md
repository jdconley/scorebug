# Worker publication association implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the
> bounded worker change and independent specification then quality reviews.
> Only use the validation worktree. Parent owns protocol/API integration and all
> Swift/media/Docker execution; worker agent may run focused Node tests.

**Goal:** Connect a production worker pipeline and reporting epoch to its actual
relay reader, signed native publishing attempt and observed ingress clock origin.

**Architecture:** A random private pipeline read ID goes into the SRT read query
and authenticated worker reports. The API uses its bounded private relay inventory
to follow the actual reader's source descriptor, verifies that publisher's signed
native attempt, and emits sanitized publication metadata only while the reporting
scope stays current across I/O. Failure leaves association unknown and never gates
streaming or local recording.

**Tech stack:** Existing TypeScript worker/control plane, protocol types, private
MediaMTX clock-v2 API, native app simulator fixture and Swift status decoding.

## Design and trust boundary

Use the existing authenticated worker report plus the assignment's encrypted SRT
read capability. The worker is trusted to report its own pipeline honestly, as it
already is for decoder observations. A unique query `sbw1=<canonical UUID>` identifies
one pipeline read; it is private correlation data, not additional authorization.
The query is never returned to native status consumers or logged. Ambiguous matching
relay connections fail closed. A malicious holder of the worker token and read
capability is inside this trust boundary. Signing a query minted by that same worker
would not improve it. A new server grant per start would put diagnostic availability
on the media startup path, so is not used.

Generate a fresh ID for every actual synchronous pipeline start. Tag only the exact
production base stream ID `read:scorebug-<16 hex>-<32 hex>`, preserving other URL
parameters. Keep the untagged control input for assignment comparisons and score
updates, so a fresh nonce does not trigger unnecessary restarts. Expose the ID only
for an active non-stopping pipeline. Legacy/unrecognized read URLs remain usable
with no association. Reporter sends the ID at the top level of its private request,
only if the session advertises `pipelineReadIdentity: 'srt-read-query-v1'`.

Protocol additions:

```ts
export const WORKER_PIPELINE_READ_IDENTITY = 'srt-read-query-v1';
export type WorkerPipelineObservation = WorkerObservation & { pipelineReadId?: string };
// WorkerSessionResponse.pipelineReadIdentity?: string
// WorkerObservationRequest.pipelineReadId?: string
export type WorkerPublication = {
  readerId: string;
  publisherId: string;
  publishingAttemptId: string;
  clock: { convention: 'mpegts-ingress-origin-90k-v1'; originPTS: string };
};
// WorkerMediaStatus.publication?: WorkerPublication
```

Accept only a canonical lowercase 36-character pipeline UUID. For a given report
session and attempt, a known ID cannot change; omission makes the current report's
association unavailable without forgetting the high-water identity. Reuse of an old
ID by a later attempt in the same session is rejected. A fresh reporting session can
associate an already-running pipeline after API restart; its public workerEpoch
changes and the old epoch remains retired. Private IDs never enter public observation
objects. Only fresh starting/producing-output reports with an active read ID can
resolve an association.

The relay adapter fetches one complete connection page (max 100 items, max 256 KiB,
existing bounded timeout and no redirects). Unsupported/incomplete/malformed or
ambiguous inventory yields unknown through the status boundary. Match exactly one
reader by query and expected path/read state; require canonical distinct reader and
publisher UUIDs. Follow scorebugReaderSource, never the current path source. Require
one publisher with that UUID, publish state and same path, valid origin convention
and canonical decimal 33-bit PTS. The lifecycle verifies its sbp1 HMAC with the current
installation/path and returns only WorkerPublication fields. Check assignment before
and after I/O. Read-only association lookup must not provision/remove relay paths or
serialize behind control mutations. Older adapters may omit this capability.

Status takes an internal read scope containing game, generation, selected worker,
workerEpoch, attempt and private read ID. After the async lookup it obtains fresh
status and scope; only equal scopes receive publication metadata. Retry, shutdown,
TTL expiry, assignment changes, new attempts, session replacement and API restart
must not reuse an earlier result. Reporting may advance within the same pipeline;
that does not change its publication association. This field proves identity and
clock coordinates only, not current source delivery, loss rate or capacity.

## Task 1: Worker pipeline identity (delegated)

Files: `apps/home-daemon/src/{pipeline-read-identity,supervisor,worker-reporter}.ts`
and focused tests. Parent owns `packages/protocol/src/worker-status.ts`.

- [ ] Write behavioral failing tests for exact tagged URLs, unsupported URL fallback,
      one fresh ID per start/retry, unchanged control URLs/score updates, ID absence
      before start/after stop/failed start, and active scope copies.
- [ ] Implement `identifyPipelineRead(readUrl)` returning `{readUrl, pipelineReadId?}`.
      Generate UUID only for the exact base production stream ID and one streamid
      parameter. Keep `Running.input` untagged; store the ID separately. Pass tagged
      copy to start and return `WorkerPipelineObservation` from observation().
- [ ] Add reporter tests and capability negotiation. Destructure pipelineReadId from
      the supplied observation; include it at request top level only for the exact
      advertised convention. Neither public observation nor unrelated session token
      may stand in for it. Maintain supplier timing/clone/deadline behavior.
- [ ] Run focused/full worker tests and typecheck; provide actual red/green evidence.

## Task 2: API observation and relay association (parent)

Files: protocol worker-status, control-plane worker-observations, ingest,
relay-lifecycle, routes/media, app, new worker-publication helper and focused tests.

- [ ] Define additive optional protocol fields. Add fail-first report validation,
      same-attempt identity, omitted identity, new-attempt reuse and private/public
      separation tests; implement private report state and scope extraction.
- [ ] Add fail-first real HTTP adapter tests for exact reader/publisher linkage,
      missing/ambiguous/changed source, malformed UUID/origin, pagination and response
      byte bound, redirects/errors. Implement bounded read-only relay lookup.
- [ ] Add lifecycle tests for authentic native query, wrong path/secret, changed
      assignment during lookup, missing optional adapter and no provisioning writes.
      Implement sanitized lookup with before/after target checks.
- [ ] Add HTTP status tests with delayed lookup: new session/attempt/assignment,
      stopped pipeline and stale TTL lose mapping; same pipeline/new report may
      retain it. Ordinary status survives unavailable metadata. Worker routes reject
      client-supplied publication metadata. Assert private queries/tokens absent.
- [ ] Run complete API/worker tests and typechecks. Review specification, then quality.

## Task 3: Native and actual media qualification

Files: native WorkerStatus model/tests/fixture and existing native fixture scripts.

- [ ] Add optional native publication model and shared valid/malformed fixtures.
      Verify legacy status still decodes and no malformed mapping becomes qualified.
- [ ] Extend the owned native app fixture to select clock-v2 explicitly and require
      production status publication: native attempt matches the real publisher's
      valid sbp1 query, reader source matches that publisher and observed origin,
      workerEpoch and attempt stay scoped. No fixture-generated replacement mapping.
- [ ] Run the existing full iPhone14/iOS17.5 workflow with local clean archive,
      native scoring overlay, real production worker, exact frame/audio/cleanup gates.
      Record older relay unknown behavior in focused/API tests; retain existing
      worker/API restart and replacement identity regressions.
- [ ] Build/test native models, update qualification docs and evidence hashes, commit.
      Keep adaptive quality disabled pending matched intervals/capacity/impairments;
      physical phone/watch and home/cloud GPU qualification remain distinct work.
