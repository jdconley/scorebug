# Staged Probe Qualification Plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the independent sender-proof verifier, then spec and quality reviews. Parent owns authenticated receiver/interval validation, integration, image build and media runs.

**Goal:** Independently reconcile all three DEBUG probe stages over a real local SRT/relay/worker path while preserving decoded live A/V and the clean archive.

**Architecture:** Explicit version-2 sender proof is checked separately from authenticated relay polling and app-generated intervals. Stage identities isolate local windows; publication identity, receiver clock intersection and cumulative accounting persist across stages. CLI staged mode selects a separately built staged relay image. Legacy v1 fixtures remain supported.

**Tech Stack:** Node assert/test, authenticated relay JSON, Swift simulator fixture, patched MediaMTX/Go in Docker, FFmpeg and existing media verifiers.

## Independent sender proof

Files: `scripts/native-bandwidth-probe.mjs`, new staged sender tests (optionally a focused sibling module).

- [x] Admit explicit mode `staged` under the existing exclusive fixed-540p full-pipeline requirements. Preserve default/legacy behavior. Dispatch version-2 proof to staged validation; reject stage/campaign/cumulative fields in v1 proof instead of silently erasing them.
- [x] Require closed, non-invalid, completed proof with matching scope/generation and at most 607 events. Exactly three stages in order at 500 kbps, 1 Mbps and 2 Mbps; begin/renew/retire/replace/final phases must follow the scheduler. Require at least one renewal and positive accepted bytes per stage. Each stage starts at zero local bytes with a 300-ms lease. Campaign origin is fixed, first-stage origin equals its start, each next stage follows the prior retirement observation, and every stage begins before the 60-second campaign deadline.
- [x] Validate finite monotonic observations, exact UUID/generation/stage identity, current-stage bytes and cumulative bytes aligned to 1316 and bounded by 16 MiB. Within-stage cumulative delta equals local delta; next-stage cumulative start equals exact retired prior total. Enforce paced 1360-byte accounted messages at the offered rate, accepted timestamps within lease/campaign, valid renewal instants before old expiry, no terminal revival and unchanged final counters.
- [x] Require each retirement's pre-cancel `retirementRequestedAt` between the prior observation and retired observation; reason cancelled. Final snapshot must exactly match the last retirement. Return `{mode,publishingGeneration,acceptedPayloadBytes,totalAcceptedPayloadBytes,stages,eventCount,receiverCapacityQualified:false}`. Each stage contains numeric `stage`, canonical lowercase `id`, `publishingGeneration`, `bitRate`, `startedAt`, `campaignStartedAt`, local/cumulative accepted byte counts as safe numbers, `lastAcceptedAt`, `retirementRequestedAt`, `retiredObservedAt`, `reason`.
- [x] Red/green and mutation tests for identity/version confusion, missing/extra stages, budget reset/overflow, lease revival, late acceptance, unbounded proof and fabricated retirement/final evidence.

## Authenticated receiver evidence

Files: `scripts/receiver-probe-evidence.mjs`, receiver tests.

- [x] Collector validates explicit v1/v2 snapshots and retains v2 stage/total fields. V1 cannot contain v2 metadata. Preserve authenticated publication binding and secret redaction. V2 total is canonical decimal, aligned, between local bytes and 16 MiB; pending packets reserve one full message against the cumulative cap.
- [x] Staged qualification requires the same publication and native generation, exact known stage/UUID/rate, monotonically increasing stages, serial request bounds and one receiver clock intersection across the whole campaign. Within a stage retain first delivery, monotonic counters/pending progress, immutable equal-count last delivery and exact cumulative/local delta. New stage begins after previous observed receiver time; its prior-delivered total must equal the prior stages' exact retired native totals, even if a terminal old-stage poll was missed. Reject skipped/missing stages for this three-stage exercise and any regression or contradiction.
- [x] Every observed current-stage delivery plus reserved pending bytes is bounded by that stage's native accepted bytes, and cumulative evidence by native cumulative acceptance. Final stage must finish with zero pending packets and all accepted bytes delivered. Summaries remain explicitly delivered load, not spare capacity.

## Native interval reconciliation

Files: `scripts/native-receiver-intervals.mjs`, staged interval tests.

- [x] Requalify native sender proof and compare staged accepted summary exactly. Requalify independent authenticated receiver history. Keep version-1 interval export format; stage is an optional per-row field already exported by the app. Each staged row must match one exact native stage and current-stage receiver endpoints.
- [x] Match endpoint brackets only against independent polls for that stage. Staged boundary rows without two-sided independent coverage remain schema/clock/native/history-validated, but are explicitly excluded from qualified counts, load and duration; report both observed and unbracketed counts. Require covered intervals in every stage. Retain publication/worker identity, serial request/evaluation ordering, nonoverlap and receiver/phone clock intersection across every stage. Cross-check per-stage accepted counts with sender observations; require row evaluation before that stage's retirement request. Reject interval windows spanning stages, receiver byte/cumulative fabrication, native stage substitution and post-retirement evidence. Require at least one independently covered healthy receiver interval per stage. Never relabel delivery rate as spare capacity.
- [x] Preserve all prior freshness, clock, byte, pending-packet and worker-publication checks. Red/green tests include valid three-stage and coordinated mutation cases, not just schema rejection.

## Integration and real-media qualification

- [x] Add explicit `stagedReceiverProbe` boolean to the owned streaming fixture, valid only with authenticated probe/publication requirements; CLI derives it solely from validated mode. Select `scorebug/ingest:staged-probe-v2` by immutable image ID; preserve legacy image defaults. Test selection/invalid combinations.
- [x] Run relevant Node suites and full tooling; spec then quality review. Build the pinned staged relay with `docker build -f vendor/MediaMTX/Dockerfile -t scorebug/ingest:staged-probe-v2 vendor/MediaMTX`, record image/source/patch provenance without changing prior qualified image tags.
- [x] Run the exclusive fixed-540p 90-second simulator fixture with mode staged, blocks16 motion, direct RTMP recorder, full processing/publication requirements and independent 1080p local archive. Use Xcode 26.2 and full FFmpeg. Join all processes, retain failed artifacts, and correct causes before any rerun with a fresh artifact directory.
- [x] Independently inspect stage totals/intervals plus live/archive decode, source frame coverage and audio markers. Preserve all earlier frozen artifacts. Update plans with the exact qualified boundary and commit after source/evidence hashing.

## Remaining scope

This measurement qualification does not authorize automatic quality increases by itself. Fresh candidate encoding cost, conservative capacity admission, upward trials/recovery, long-session campaign policy, physical phone/Watch routes and remote CPU/GPU workers remain open in the main plan.

## Real-run correction

The first run (`native-app-ll3wa3`) completed all three stages and reconciled
3,416,336 payload bytes at the authenticated relay, but correctly failed because
the app exported zero receiver intervals. The DEBUG probe fixture still used the
normal two-second control cadence. With a 300-ms observed native lease, local
health correctly expired every baseline before a one-second interval could form.
The explicit probe fixture now requests the existing 100-ms control cadence;
observed-lease expiry, native authority checks, freshness bounds and normal
production cadence remain intact. A model regression failed before the correction.
A fresh full-media run is required; the first run remains failed evidence.

The second run (`native-app-lYliiG`) produced 21 native intervals. Two initial
intervals began before the independent poller's first observation of their stage.
The qualifier now reports these as unbracketed and excludes them from qualified
counts, bytes and duration. Every row still undergoes native ownership, lease,
freshness, clock and coherent combined-history validation. At least one fully
corroborated interval remains mandatory in each stage. This is an explicit
coverage boundary, not inferred evidence for the omitted windows.

## Qualified result

Fresh run `native-app-PnVEYX` passed the complete simulator pipeline with the
reviewed verifier and DEBUG cadence correction. All 3,411,072 native accepted
payload bytes arrived at the authenticated relay. Of 21 app intervals, 18 were
independently bracketed (six per stage); three boundary intervals were explicitly
excluded from qualified totals. All rows passed ownership, lease, freshness,
clock and combined-history checks.

The independent 1080p archive contains 3,639 consecutive source frames and all
60 expected audio markers. The 540p live output contains 3,264 consecutive source
frames after bounded startup acquisition and all 54 expected audio markers. Both
outputs decoded without errors or source-frame loss; minimum reported receiver
cadence was 29.8 fps. Recorder, worker encoder and worker all exited successfully.

Verification: 1,609 tooling tests, 299 native model tests, spec and quality reviews,
and the pinned staged relay build. Both failed runs remain preserved. Evidence:
`artifacts/qa/staged-probe-qualification-final-verification.json`.

This qualifies finite staged delivered-load measurement during fixed-profile
simulator media and independent recording. It does not establish spare capacity,
automatic upward adaptation, long-session probe policy, physical phone/Watch
behavior or remote deployment.
