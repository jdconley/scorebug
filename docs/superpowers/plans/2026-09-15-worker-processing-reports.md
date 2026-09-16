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

- [x] Add shared protocol types and positive pending/complete/unknown examples; build.
- [x] Add atomic pipeline evidence sampling and supervisor ownership filtering. Add
      reporter negotiation tests (legacy/mismatch/accepted/session renewal) before wiring.
- [x] Add strict API processing schema and stateful acceptance tests covering malformed
      bounds/counts/durations, attempt/scope reuse, pending progress, frozen contradictions,
      omission/reappearance and unchanged decoder age proofs; implement acceptance.
- [x] Add tolerant Swift wire decoding and validated processing evidence with shared
      fixture round trips and malformed/bounds/age/scope tests. Attach matched evidence
      to app source intervals, including repeated-window completion and omission tests.
- [x] Run worker/API/tool/typecheck suites, Core/FilmModel/Watch builds, combined unsigned
      iPhone/Watch Release and real local native reporting. Review, preserve evidence/hashes,
      update documentation and commit verified changes.

Follow-up: classify current-load evidence and wire automatic trial/rollback, separately
qualify startup probe ownership on abrupt parent death, then physical devices and other
worker hosts. Those requirements remain open rather than being implied by these reports.

## Implementation and regression evidence

The optional report now travels from an atomic pipeline sample through exact session
negotiation and API validation to matching native source intervals. Repeated windows
update processing completion while preserving the original source-age anchor. Current
omissions clear native/public evidence without erasing server progression guards.

Independent review found that assignment changes at the same attempt could erase the
processing high-water mark. Regression tests reproduced the gap. The API now retains
both processing scope and assignment across omissions; a new assignment requires a
new attempt, and rejected reports leave timing tokens/read IDs/scope sets untouched.

Enabling automatic optional timing also exposed oversized terminal log records: raw
bounded timing histories could exceed the native diagnostic reader's 4096-byte line
limit. A failing regression now passes after terminal logging explicitly selects only
the existing aggregate diagnostic fields. Direct pipeline callbacks retain raw timing
history; process diagnostics stay bounded.

Validation passes: 332 worker tests, 384 API tests, 793 tool tests, both TypeScript
checks, 279 Swift Core tests, 141 FilmModel tests, arm64_32 watchOS 10 Core compilation,
and combined unsigned iPhone/Watch Release using Xcode 26.2. Shared JSON includes
pending, complete, unknown-duration, backend and wide/signed timestamp examples.

The native qualifier independently collects allowlisted API reports and requires two
complete windows matching qualified native source intervals and saved frame identities.
Collector mutation tests reject malformed identity/count/timing data before retention;
the end-to-end oracle fixture passes and rejects ten identity/count/timing mismatches.
It does not re-derive raw processing durations; the existing paced pipeline harness
provides that separate proof. Source review approved the completed implementation.

## Native simulator checkpoint

`native-app-DAlh18` passes on iPhone 14/iOS 17.5 with Xcode 26.2 and:

```sh
SCOREBUG_TEST_RELAY_PUBLICATION=1 \
SCOREBUG_TEST_WORKER_PROCESSING=1 \
SCOREBUG_TEST_DIRECT_RTMP_RECORDER=1 \
SCOREBUG_TEST_STREAM_HOLD_SECONDS=30 pnpm test:native-streaming
```

The clean archive preserves all 1,929 consecutive frames (0–1928). The direct receiver
saves all 1,517 worker frames (source 227–1743) through the final native encoded frame,
at 30 fps with zero loss over the acquired range. The 60-frame decoder acquisition
interval and one initial capture frame before native encoder coverage remain explicit.
Both MP4s fully decode; A/V, native scoring, overlay changes, recording/export, source
identity, publication association and decoder-age qualification pass.

Eight complete 150-frame processing intervals (decoder sequences 2–9) match independent
API records, native source intervals and saved frame identities. VideoToolbox observed
completion means are about 401 ms, with maxima of 411–430 ms. These include scheduling
and pipe delivery, exclude decode execution, and are measurements for this fixture,
not universal backend thresholds. The barcode workload uses low actual payload bitrate.
This run does not qualify sports-motion load, automatic quality changes, physical
phone/Watch radios, remote GPUs or startup-probe cleanup after abrupt parent death.

`artifacts/qa/processing-reports-final-verification.json` retains hashes of the changed
source, red/green and full-suite logs, independent review and native evidence/media.
Next: classify aligned worker/transport/thermal evidence conservatively, map applied
configuration revisions, then qualify automatic bitrate trials and rollback with
actual native media before enabling runtime adaptation.
