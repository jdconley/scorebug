# Relay origin metadata implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for the
> bounded upstream patch and independent specification/quality reviews. One owner
> executes Go, Swift, Docker builds or media fixtures at a time. Only use the
> validation worktree; the original checkout is off limits.

**Goal:** Expose the relay's actual MPEG-TS normalization origin on its private API
and qualify it against every acquired native picture without changing media timing.

**Architecture:** Maintain a small patch against MediaMTX 1.21.0 revision
`2c6727904fbf233615de74a6c54a9b94dbf6025d`. Observe the exact first supported callback
passed to the existing shared TimeDecoder. Bind the immutable scalar to the owning
SRT publisher connection, whose UUID already identifies that publication. A pinned
portable Docker build and the existing raw native boundary fixture establish this
primitive before any control-plane/native policy consumes it.

**Tech stack:** Go 1.26, existing MediaMTX/mediacommon decoder, private SRT API,
pinned source archive + patch, Docker, bounded Node raw-byte qualification.

## Design and exclusions

Changing the relay to preserve PTS would disturb qualified A/V behavior. Inferring
an origin from a late reader loses startup information. Capture the origin inside
the existing decoder path instead, with a once-only synchronous callback and no I/O
or per-frame allocations. Keep ToStream's current caller interface as a wrapper;
a new explicit ToStreamWithClockOrigin variant takes the optional callback.

Add optional `scorebugTransportClock` to the private SRT publisher API item:

```json
{ "convention": "mpegts-ingress-origin-90k-v1", "originPTS": "9000" }
```

The API item's existing `id`, `state` and `path` bind it to a specific SRT publisher.
`originPTS` is the actual 33-bit ingress callback PTS as a decimal string; convention
fixes 90 kHz and modulus 2^33. It is unavailable before first callback, on readers,
after publisher reader teardown, and for alwaysAvailable paths (which have a
separate PTS offset). This is a mapping primitive, not freshness or source receipt.
Do not expose passphrases, worker tokens or a guessed fixture constant.

No default relay deployment changes until the patched build is qualified. Preserve
the stock relay fixture mode as its established negative clock-preservation control.
The new mode must require actual metadata and fail when it is absent or mismatched.
The separate next integration must bind authorized native publishing attempts,
relay publication IDs and actual worker reads; path/generation alone is insufficient
across reconnects. Legacy deployment metadata is unknown, never guessed.

## Task 1: Pinned decoder/API patch

Edit only the isolated checkout
`artifacts/qa/mediamtx-clock-source/upstream` while developing. Maintained deliverable
is `vendor/MediaMTX/scorebug.patch`, upstream identity/hash manifest and MIT notice.

- [ ] Read pinned ToStream, TimeDecoder and SRT connection lifecycle. Add failing
      Go tests before implementation for first-zero/nonzero/near-wrap origins, mixed
      callback order, exactly-once notification and unchanged decoder outputs; use
      the real existing TimeDecoder as the output oracle. Add actual ToStream callback
      coverage so an unused wrapper cannot pass.
- [ ] Implement explicit optional observer in ToStreamWithClockOrigin while original
      ToStream delegates with nil. Every supported codec must use the same observed
      decoder; unsupported packets cannot choose the origin. For example:

```go
out := decoder.Decode(pts)
if !observed {
    observed = true
    if onOrigin != nil { onOrigin(pts) }
}
return out
```

- [ ] Add failing publisher API tests. Store a copy of the immutable scalar under
      the existing connection mutex, clear on publish-reader exit, suppress it for
      alwaysAvailable, idle and read connections. Include the JSON field only when
      qualified. Test snapshot isolation and concurrent access under the race detector.
- [ ] Run targeted Go tests with recorded red/green logs, then full MPEG-TS and SRT
      package tests and race checks. Preserve normal auth/timing/teardown behavior.
      Return sole execution ownership before parent Docker/media qualification.
- [ ] Produce an exact git diff against the pinned clean revision, including added
      tests; record SHA-256 for original touched files and round-trip patch application.

## Task 2: Reproducible portable build

Files: `vendor/MediaMTX/{README.md,LICENSE,upstream.json,scorebug.patch,Dockerfile}`
and `scripts/build-ingest-relay.mjs` only if a helper materially improves reproducibility.

- [ ] Pin the upstream archive URL by full revision and SHA-256, preserving go.mod
      and go.sum. Docker build verifies the archive hash before patching. Use a pinned
      Go toolchain builder and a minimal runtime with CA certificates. Build a static
      binary for the requested Linux target architecture. Do not add a cloud service.
- [ ] Build the local ARM64 image `scorebug/ingest:clock-v1`; record image/source
      hashes and build commands. Validate the Linux AMD64 compile target as feasible.
      Keep deployment examples on the stock image until metadata gates pass.

## Task 3: Require mapping in the raw native fixture

Files: `scripts/test-relay-clock.mjs`, `scripts/relay-clock-comparison.mjs`,
`scripts/test/relay-clock-comparison.test.mjs`, `package.json` if a named command helps.

- [ ] Add fail-first pure checks for the exact convention, canonical origin string
      in `[0, 2^33)`, publisher UUID/path/state identity and modulo consistency with the
      existing all-picture comparison. Reject missing/malformed/mismatched metadata;
      allow zero and wrap-region origins without truncation or hardcoded offsets.
- [ ] Implement a separate explicit mapped-relay mode. Read the private SRT item
      identified by the ready path's source UUID while native publishing is live; save
      only the bounded scalar metadata/identity needed for evidence. Compare the returned
      origin with all raw before/after picture offsets. Require same-publication early
      and late readers to agree. Keep full decode, VCL hashes, worker output identity,
      local recording and cleanup assertions unchanged.
- [ ] Run the stock image in mapped mode as a missing-metadata negative control,
      then the pinned patched image for zero/offset/late-reader cases. Run full tools
      tests. Verify absent metadata on a stopped connection; do not infer completion
      from a stale path snapshot. Save actual process exits and owned-container cleanup.
- [ ] Obtain independent specification then quality review, resolve findings, update
      `docs/relay-clock-correspondence.md` with actual evidence and remaining association
      work, and commit the verified primitive. Keep the full goal active.
