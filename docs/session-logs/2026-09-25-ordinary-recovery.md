# Ordinary production recovery implementation

Starting checkpoint: `8317f33`, authoritative worktree
`/Users/jd/.codex/worktrees/scorebug-local-validation`, branch`codex/local-validation`.

## Scope and decisions

The prior goal turn produced new Watch destination-preparation evidence and a
read-only recovery proposal. Physical paired acceptance remains open, awaiting
Mac unlock for Xcode inspection. No unchanged hardware or simulator retry is
started. The active goal remains the complete native vertical with progressive
streaming; independent recovery implementation continues.

Design/first component plan commit`79f324f` specifies normal publisher-only ingest
configuration before event-driven upload impairment. A fixed-time impairment
would not establish whether the production trial had confirmed; the old fixture
URL selector would change the app route under test. Normal deployment addresses
and actual confirmed quality transitions are therefore used. The sole source
implementer handles the paired configuration path and its native API tests.
Root handles design/session docs and independent finite source preparation.

## Ten-minute finite source

Artifact-only helper`artifacts/qa/prepare-ordinary-recovery-source-20260925.mjs`
creates a new derivative from the already validated30minute1080p match fixture.
Its retained provenance traces that source to the user's original Downloads
match at1200seconds, with no looping. The new clip is stream-copied for600seconds
with123.25second PTS origin, preserving H.2641080p30 and48k mono PCM. Originals and
all old artifacts remain untouched.

Preparation process11068 joins0. Four commands (copy, complete A/V decode with
`-xerror`, all-frame probe, complete barcode decode) join0 with empty error logs.
`artifacts/qa/prepared-ordinary-recovery-dZeq4S/qualification.json` verifies:

- 18,000consecutive source identities0–17999 over600seconds.
- 48k audio28800602samples; maximum discontinuity~1microsecond and cumulative
 timeline error~0.5microseconds.
- A/V start aligned, tail difference~12.542milliseconds.
- SHA256`6c4d0f5f6d08948cba78f6ff6342a8e1feb729e7831352e373260781919cb2a6`.

Input/checker hashes are frozen before and verified after processing. This is
source qualification only, not a congestion/recovery or physical camera pass.

## Publisher-only endpoint component

Commit `488c50b` adds the optional validated native publisher endpoint while
preserving worker read grants, credential/path derivation and attempt attestation.
The native API integration regression exercises normal configuration and app
wiring. Initial behavioral red: 62 failed/64 passed; scoped IPv6 red: two failed.
Final 128 focused tests and all 599 control-plane tests pass, plus typecheck and
format checks. Independent specification and quality reviews approve all 11
changed files. Root verifies every source blob/SHA256 and all 17 retained artifact
hashes in `publisher-ingest-address-validation/manifest.json`; root verification
is retained alongside it. No native congestion pass is claimed by this component.

The next proxy component preserves full bounded boundary timelines because the
existing rate-ledger qualifier checks their exact bins. It will snapshot only at
baseline/constraint/restoration, retaining the current queue/accounting limits;
it will not substitute scalar totals for complete required evidence.
