# Relay reader source association implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the
> bounded Go patch and independent specification then quality reviews. Only use
> the validation worktree. One owner executes Go/Swift/media/Docker builds at a time;
> parent can run pure Node helper tests while the Go implementer owns execution.

**Goal:** Expose the publisher selected by an actual relay reader, preserving that
association across teardown/replacement rather than inferring it from a path lookup.

**Architecture:** Extend the pinned MediaMTX patch. In the path's serialized reader
registration, return a copied SRT source descriptor with the selected Stream.
The SRT reader stores a copy and exposes it on its private API item while attached.
Keep the existing publisher-origin metadata. The raw native fixture identifies each
reader using its own unique query marker and requires both reader and publisher
metadata to refer to the same publication.

**Tech stack:** Existing MediaMTX Go path actor and SRT connection mutex, pinned
archive/patch Docker build, raw native A/V qualification and Node bounded checks.

## Contract and design

Add optional `Source *APIPathSource` to the internal `PathAddReaderRes`. In
`path.addReaderPost`, construct the response from the Stream and source in the
same path goroutine. Return a fresh descriptor only for a non-alwaysAvailable
path whose source is SRT. Include both first registration and duplicate-reader
success paths; no source on failure, nil source or unsupported source types.

The SRT connection captures that descriptor from its actual AddReader result.
After stream-reader attachment, store it under the existing mutex. The private
SRT API item adds optional `scorebugReaderSource`:

```json
{ "type": "srtConn", "id": "<canonical publisher UUID>" }
```

The enclosing item identifies the reader UUID, path and `read` state. Validate
the descriptor before exposing it, copy on storage and API snapshot, and clear
on read exit. Do not put publisher-origin metadata on readers. Do not query the
current path or hold a pointer to mutable publisher state. Reader-source identity
is not readiness, frame receipt or freshness; the publisher may already be ending.
Normal non-alwaysAvailable stream replacement closes old readers rather than
retargeting them. AlwaysAvailable is deliberately excluded because its Stream can
span multiple sources. Unsupported deployments leave association unknown.

A read-query marker in the fixture identifies the connection that its launched
reader actually opened; it is a fixture nonce, not a new production capability.
The later worker integration will authenticate and bind a distinct pipeline read
to workerEpoch and attempt counters, and combine this field with the signed native
attempt and observed origin. None of this step enables adaptive quality.

## Task 1: Extend and test the pinned Go patch

Develop only in `artifacts/qa/mediamtx-clock-source/upstream`, currently containing
the verified clock-v1 patch against revision `2c6727904fbf233615de74a6c54a9b94dbf6025d`.
Maintained deliverable is the cumulative `vendor/MediaMTX/scorebug.patch`.

- [ ] Add fail-first Go tests for actual path registration returning a copied SRT
      source with the selected Stream, duplicate reader, nil/non-SRT/alwaysAvailable
      suppression, replacement and old snapshot isolation. Tests must call the
      real path registration code; fabricated API objects alone are insufficient.
- [ ] Add Source to PathAddReaderRes and construct success response in the path
      goroutine. Use a shallow copy of the immutable scalar APIPathSource fields.
      Do not change routing, stream teardown, auth or callback PTS handling.
- [ ] Add fail-first SRT tests exercising runRead attachment, pre-attachment absence,
      read-only exposure, snapshot isolation, malformed/nil descriptor suppression,
      cleanup on normal and failed startup and concurrent API access under race.
      Store only `type=srtConn` with canonical nonempty UUID from the AddReader result.
- [ ] Run targeted core path tests and full MPEG-TS/SRT package tests, plus race
      checks. Generate upstream's SHA-checked HLS/RPi assets if core compilation
      requires them; do not run unrelated whole-core integration tests on fixed ports.
      Record actual red/green exits. Produce cumulative exact patch including new
      tests, verify clean-archive apply/reverse/byte equivalence and return ownership.

## Task 2: Bounded qualification helper and actual readers

Files: `scripts/relay-clock-comparison.mjs`, its test,
`scripts/test-relay-clock.mjs`, `package.json`.

- [ ] Add fail-first `qualifyRelayReader({path, publisherId, readerQuery, connection})`:
      require canonical distinct reader/publisher UUIDs, exact path/read state,
      exact bounded expected query marker `sbr1=<UUID>`, and matching
      `scorebugReaderSource.type=srtConn/id=publisherId`. Return readerId,
      publisherId and path only; reject malformed, missing, mismatched or relabeled
      evidence. Origin qualification remains a separate all-picture requirement.
- [ ] In mapped mode, launch early/primary readers with different random query
      markers. Poll a complete private connection listing while publishing, identify
      each exact marker, require one matching read connection, and use the helper.
      Save only sanitized identity. Require distinct readers and identical source
      publication for early/late. Keep strict raw hashes, all-picture timestamps,
      archive completeness, worker identity, EOF and cleanup gates unchanged.
- [ ] Use `scorebug/ingest:clock-v2` for the upgraded mapped command. Requiring reader
      association from the clock-v1 image must fail after its valid origin check;
      stock mode remains available. Bound polling and retain terminal cleanup.

## Task 3: Portable build, media and reviews

Files: `vendor/MediaMTX/{scorebug.patch,upstream.json,Dockerfile,README.md}`,
`docs/relay-clock-correspondence.md` and this checklist.

- [ ] Update cumulative patch hash, original touched-file hashes and added-file list.
      Verify archive/license identity and exact patch round trip. Keep pinned upstream,
      toolchain/package/dependencies unchanged. Version the binary clock-v2, build
      ARM64 plus AMD64 and probe versions (AMD64 emulation is not hardware evidence).
- [ ] Run old-image negative and upgraded mapped zero/nonzero/late native cases;
      require real reader-source metadata and origin mapping for all acquired frames.
      Check exited processes, publisher removal and exact owned container absence.
      Run full tooling tests. No default relay deployment or adaptive policy change.
- [ ] Obtain specification then quality review, fix findings, update actual evidence
      and remaining worker-read integration, hash source/artifacts and commit the
      verified reader-source primitive. Keep the full goal active.
