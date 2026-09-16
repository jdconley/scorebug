# Worker processing reports implementation plan

> **For agentic workers:** Use superpowers:executing-plans inline, red/green behavioral
> tests and bounded independent review. Parent runs builds and native media sequentially.

**Goal:** Carry source-correlated processing measurements from the live worker through
negotiated API reports into the native app's matched source intervals.

**Architecture:** Add an optional version-negotiated processing report beside decoder
telemetry. Sample decoder and processing evidence synchronously from one pipeline
read. API validation checks exact window/count correspondence and monotonic completion
within one immutable pipeline scope; absent evidence stays absent publicly. Swift
accepts additive metadata tolerantly and validates it before matching native source
history. Existing decoder age proofs remain the timing provenance for the same window.

**Tech stack:** shared TypeScript protocol, worker/Vitest, Hono/Zod API, Swift Core and
FilmModel tests, existing native media fixtures. No pressure threshold or automatic
bitrate policy activation in this slice.

## Wire contract

`WORKER_PROCESSING_PROTOCOL = 'source-processing-v1'` is advertised by worker session
registration. New reporters omit processing metadata unless that exact protocol,
transport clock and private pipeline-read identity are negotiated. Legacy payloads
and observations without processing remain valid. Reports contain a pipeline UUID,
encoder backend, previous/current decoder sequence, first PTS and the existing interval
of decoded/submitted/completed/pending/omitted counts and optional duration aggregates.

Only producing-output observations with valid, non-ended transport-clock decoder
windows can contain processing. Sequence, first/end PTS and decoded count must match
the current decoder window. The exclusive source anchor is before its first PTS;
previous sequence is exactly current minus one. Counts are safe nonnegative integers:
submitted <= decoded, completed <= submitted, pending = submitted-completed and
omitted = decoded-submitted. Durations are finite nonnegative mean/max with mean <= max;
no submissions means unknown durations, and pending output means unknown completion
duration. Zero/pending counts never imply healthy completion.

Per worker session and publishing attempt, pipeline UUID and encoder cannot change.
A pipeline UUID cannot be reused in another attempt. For the same decoder window,
source identity, counts before completion and filter duration are immutable. Completed
count may only rise; completion duration remains unknown until all selected output
completes. After complete, the whole report is immutable. Adjacent processing intervals
share exactly one exclusive endpoint; skipped windows must advance past the prior end.
Omissions do not erase server high-water evidence but never restore old public data.
Invalid reports are rejected before receipt/age state or identity sets mutate.

Swift uses Int64 for source coordinates and counts, including watchOS arm64_32. Bad
optional processing metadata cannot invalidate otherwise usable score/worker status.
Native evidence requires existing server-derived age proof and validated publication,
then matches the processing exclusive endpoint, first/end PTS, sequence and decoded
count to the app's independently reconstructed source interval. Repeated decoder
reports can update pending-to-complete metadata; omission clears it. No new UI health
claim, utilization estimate, network-capacity estimate or viewer-delivery claim.

## Tasks

- [ ] Add shared protocol types and positive pending/complete/unknown examples; build.
- [ ] Add atomic pipeline evidence sampling and supervisor ownership filtering. Add
  reporter negotiation tests (legacy/mismatch/accepted/session renewal) before wiring.
- [ ] Add strict API processing schema and stateful acceptance tests covering malformed
  bounds/counts/durations, attempt/scope reuse, pending progress, frozen contradictions,
  omission/reappearance and unchanged decoder age proofs; implement acceptance.
- [ ] Add tolerant Swift wire decoding and validated processing evidence with shared
  fixture round trips and malformed/bounds/age/scope tests. Attach matched evidence
  to app source intervals, including repeated-window completion and omission tests.
- [ ] Run worker/API/tool/typecheck suites, Core/FilmModel/Watch builds, combined unsigned
  iPhone/Watch Release and real local native reporting. Review, preserve evidence/hashes,
  update documentation and commit verified changes.

Follow-up: classify current-load evidence and wire automatic trial/rollback, separately
qualify startup probe ownership on abrupt parent death, then physical devices and other
worker hosts. Those requirements remain open rather than being implied by these reports.
