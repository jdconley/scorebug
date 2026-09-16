# Native local-pressure fallback

Execute inline in the validation worktree with red/green tests and bounded
independent design/source reviews. Parent owns sequential Swift/build/media runs.

## Problem and scope

Checkpoint `1791c8c` proves native trial confirmation with clean local recording.
Inspection shows that `PublishingQualityDriver` evaluates only matched receiver
source intervals. Without one, it only checks an active trial's deadline. Known
local congestion cannot yet reduce bitrate outside a trial, and transition source
windows are skipped before their pressure can be evaluated. This is a code-level
gap; an actual impaired native run has not yet been qualified.

Add a separate, conservative path for known local pressure. Missing receiver
reports alone must never authorize growth or fabricate frame/loss observations.
Preserve receipt ownership, native write deadlines, archive isolation and existing
recovery/rollback rules. Keep production opt-in disabled.

## Stage 1: pure local evidence adapter

Add an app-layer adapter, independently testable and initially unused by the
runtime driver. Require current publishing state, the exact applied receipt,
a matching native publishing generation, and an open ingress scope belonging to
the applied attempt. Validate time, settings and acknowledgment. Use a complete
five-second interval that starts after both acknowledgment and any previously
evaluated window. Never reuse or overlap evidence and never shorten the interval
to chase a recent bitrate write.

Consider at most the latest endpoint of each independently covered, open, fresh,
non-quarantined thermal/transport/queue history. Deduplicate these candidates and
try newest first, returning the first with known unhealthy evidence. Classify all
metrics on that same five-second interval; never merge observations from unequal
intervals. Failed probes consume no policy window. A slightly older but still
fresh unhealthy interval may be selected despite newer nominal evidence: this
conservative downward-only choice preserves pressure that a lagging or unavailable
metric would otherwise suppress. Each metric needs full enclosing coverage. For sampled thermal and
transport evidence, require the enclosing sample bounds to lie after the native
acknowledgment. Queue occupancy is an exact integral of effective state, so its
state may have originated earlier while the measured interval remains post-ack.
Use the existing pressure thresholds and bounded histories; factor shared pressure
classification to avoid divergent source/local interpretations.

Return a window only when at least one known local metric is unhealthy: mean
queue occupancy >=0.75, serious/critical thermal samples, or transport pressure
above explicitly supplied limits. Missing/unqualified/closed/stale evidence stays
unknown. Capture/encode/receiver/loss/capacity/worker/connectivity stay unknown.
Core may recommend only a decrease or an active-trial rollback from this window.
A nominal local interval must return no window and cannot establish recovery.

Tests cover independent pressure causes, exact thresholds, time/ownership,
missing and stale evidence, sample gaps and quarantines, post-ack enclosing
samples, overlap, minimum five-second duration, and Core's downward-only behavior.
Run full FilmModel tests and the combined unsigned Apple Release build. Commit a
verified stage-1 checkpoint before connecting scheduling or changing trace format.

## Stage 2: owner, scheduling and independent trace qualification

- Add actor-owned local evaluation with one shared policy ordinal and native
  receipt/acknowledgment. Preserve existing admission, invalidation and write rules.
- Prefer eligible fresh matched source evidence. On absence, duplicate, mixed
  configuration, stale/rejected or incomplete evidence, consider known local
  pressure. A prior local evaluation must cause overlapping source windows to be
  skipped until a wholly newer window arrives; never splice a receiver window.
- Export an explicit local-pressure event with raw bounded diagnostic evidence.
  Extend the independent verifier to reconstruct pressure and prove no fabricated
  receiver/frame/capacity data or local-evidence growth. Keep source events strict.
- Test trial rollback, unavailable receiver, post-change timing, no double use,
  stale advice, stop/write races and resumed source recovery. Replay prior native
  confirmation artifacts to check the existing source path remains qualified.

## Stage 3: native impairment and recovery

Use the existing owned UDP impairment proxy with an explicit native fixture hook.
Validate options before resources; preserve direct A/V recording and original
source identities. Start with repeatable bandwidth pressure, then recovery. Freeze
acceptance criteria before running: local recording continuity, actual downward
native receipt, raw pressure evidence, no unsupported growth, bounded live loss
and recovery timing. Retain failed runs and avoid weakening gates to obtain a pass.

Longer adaptive soaks, resolution changes, physical iPhone/Watch networking and
remote CPU/GPU hosts remain later gates.

## Checklist

- [x] Independent stage-1 design review, including bounded endpoint refinement.
- [x] Stage-1 red/green tests, implementation, source review and verified commit.
- [ ] Stage-2 owner/driver/oracle integration with deterministic validation.
- [ ] Actual native impairment/recovery qualification with independent archive gate.

## Stage-1 validation record

The new local-adapter tests initially failed because the adapter did not exist.
The initial fixture incorrectly supplied nonzero item count with zero bytes;
correcting that invalid occupancy fixture exposed no source defect. A separate
shifted-history regression then demonstrated that choosing the minimum endpoint
suppressed independently valid transport pressure. The reviewed bounded newest-
first endpoint selection fixes that failure. A test still expecting the superseded
minimum-endpoint behavior was split into explicit pre-ack pressure exclusion and
newest unhealthy endpoint cases.

All 171 FilmModel tests now pass, including existing matched-source pressure tests
and nine new local tests. Core evaluation of these local windows produces a 20%
decrease outside a trial and baseline rollback during a trial, with frame delivery,
source loss, capacity, worker health and connectivity unknown. A nominal interval
returns no window. The runtime driver has no call to this new adapter yet.

Retained red/green logs use the `artifacts/qa/local-pressure-*` prefix. The final
verification manifest records staged source hashes, validation logs and review.
No additional native media run is claimed for this inactive adapter stage.

The combined unsigned iPhone/Watch Release build also passes.
Independent final source review approves the corrected endpoint regressions and
finds no remaining stage-1 blocker. Evidence hashes are retained in
`artifacts/qa/local-pressure-adapter-final-verification.json`.
