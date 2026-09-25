# Direct evidence of an active upload rate limit

> Use `superpowers:executing-plans`. This is an explicitly selected laboratory
> route, not production authority or a replacement for historical acceptance criteria.

## Problem and intended result

The frozen `native-app-YAQo8F` experiment passed its causal clock exchange but
failed the historical congestion stimulus criterion:480.596ms maximum queue
residence, no overflow, versus the required500ms or overflow. A one-second input
peak above750kbps cannot independently prove sustained rate pressure because the
16KiB token burst may absorb it. Residence alone also cannot distinguish token
waiting from delayed scheduling. Preserve that run's failed result.

Record payload-free evidence at the actual queue branch that refuses a ready
packet because it lacks tokens. Reconstruct the complete limited-phase token
balance independently from actual forward times and wire-byte charges. A future
explicit `rate-ledger-v1` proof would establish that the rate limit actually bound
traffic, without claiming a particular queue-delay severity. The native policy
must still separately prove confirmation before the fault, owned transport
pressure after it, a decrease, complete media conservation and fresh recovery.

## Reviewed audit contract

Use a bounded phase operation log, not a forward-only witness. A forward-only
ledger cannot independently establish FIFO head identity or reproduce all
floating-point token updates.

- Opt in explicitly at queue construction. Default queue snapshots, historical
  fixtures and the current 500 ms/overflow qualification remain unchanged.
- Header: format version, exact queue configuration, actual limit timestamp and
  operation ordinal, received-packet counter, and complete bounded initial FIFO
  metadata (identity, wire bytes, enqueue/ready times; no payload). Require that
  the queue was constructed unlimited and had no previous finite-rate phase.
  Only then are initial tokens exactly the configured 16 KiB burst. Returning
  to unlimited does not replenish a previously depleted bucket.
- Records: every existing `#advance()` call in the finite phase, with its original
  timestamp; every receive and disposition with its monotonic received-packet
  identity and wire bytes; every forwarded charge; and the first actual ready-head
  token denial from `takeReady()`. Record empty/delay-only/`nextDelay()` advances
  too: omitting floating-point refills prevents bit-exact reconstruction.
- A denial is recorded only at the existing branch, with a nonempty FIFO and
  `now >= enqueuedAt + configured delay`, when
  `tokens + 1e-9 < head.wireBytes`. Predictions from `nextDelay()` are not denials.
  One witness is sufficient; repeated denials need not add witness rows, but their
  token advances still belong to the complete operation log.
- Footer: actual restoration timestamp/ordinal, final FIFO metadata and counters,
  record totals, and phase-closed/overflow/invalid flags. Close the audit at rate
  restoration before subsequent unlimited forwarding. Equal timestamps are valid;
  explicit operation ordinals and boundary markers establish order.
- Fix row and byte limits before implementation; reserve header/footer capacity.
  Exhaustion is sticky and disables only this proof. It must not affect forwarding
  or substitute aggregate counters for missing records. Use existing timestamps,
  avoid payload copying and per-event serialization, and deep-copy exported data.
- Keep the growing operation log out of ordinary `snapshot()` calls used by
  clock/status polling. Export it through an explicit final accessor and bounded
  separate artifact; match its boundaries to the existing immutable phase
  snapshots. Repeatedly cloning a large ledger during clock polling would itself
  create measurement load. A compact per-public-operation row may combine its
  one advance and outcome, provided replay still includes every original advance.
- When recording is explicitly enabled, ordinary snapshots include a compact
  `rateLedgerOperationOrdinal` alongside their existing fields. Match both phase
  snapshot ordinals to the ledger boundaries. Otherwise, deleting a no-op and
  renumbering the log could hide an omitted advance. Also include the small
  `rateLedgerFirstDenial` witness (null until an actual denial) and match it at
  restoration. This prevents a prediction-only row and forged witness from
  passing together against untouched snapshots. Default snapshots stay unchanged.
- The recorder cannot sleep, alter tokens/FIFO/rate timers, extend latency, or
  grant native quality authority. The final queue/socket shutdown remains joined
  separately after phase closure.

## Independent replay

Reconstruct the FIFO and all token updates in recorded operation order. Start at
burst tokens under the exact initial-history precondition. At every advance use
the queue's actual expression:
`tokens = min(burst, tokens + (now - previousTime) * rate / 8000)`.
A forward requires the original tolerance predicate and performs
`tokens = max(0, tokens - wireBytes)`. Replay every receive/drop/forward against
its FIFO head, wire cost, readiness and queue capacity. Require that the recorded
first denial is a real ready-head deficit under the reconstructed token balance.

For every timeline bin, compare ledger dispositions with **restoration snapshot
counters minus limit snapshot counters**, treating absent bins as zero. This
includes partial first/last bins without mixing later unlimited traffic into the
phase. Reconcile header/footer FIFO occupancy and cumulative counters as well.
Reject omitted/extra/reversed operations, changed prefixes, foreign configuration,
wrong packet identity/size, impossible head order, premature readiness, token
arithmetic mismatch, and any missing phase closure or overflow/invalidity.

Retain existing conservation, configured loss, final queue/pending-send closure,
phase duration/rate ceilings, baseline/restored traffic and causal clocks. One
valid denial establishes active rate limiting, not deep congestion, receiver loss
or successful adaptation. Composed native acceptance retains its independent
transport-pressure, media and recovery gates. Old artifacts have no operation log
and cannot acquire this new qualification retroactively.

## Test-first implementation sequence

- [x] Review the proof shape and resolve initial history, FIFO ownership, complete
  floating-point advances, same-time boundaries, partial bins and phase closure.
- [x] Set fixed row/byte budgets and prove overflow cannot affect queue behavior
  before enabling the recorder.
- [x] Add queue observer tests: a finite cap with actual token denial; an underload
  with no denial; a delayed host timer whose replenished bucket can forward;
  delay-only waiting; packet drops; phase boundaries; immutable snapshots; caps;
  unchanged queue behavior with and without observation.
- [x] Implement the bounded audit without enabling it in any native run.
- [x] Add independent replay tests with missing/extra/reordered charges, forged
  denial, wrong ready time, incorrect wire accounting and incomplete terminal
  evidence. Keep the historical500ms gate tests unchanged.
- [x] Review and run focused/full tooling checks.
- [x] Implement only an explicit laboratory selector and bounded separate export.
- [ ] Retain raw input/source hashes and run the new native experiment.
- [ ] Compose actual token limiting with causal native pressure, bounded live-loss
  conservation, strict clean recording and fresh recovery. No evidence can be
  retroactively added to YAQo8F or substituted into its frozen failed result.

Review additionally requires tests for an initially finite or previously depleted
bucket, same-time boundary operations, denial followed immediately by restoration,
initial backlog, forged/dropped head identity, tolerance-edge arithmetic, omitted
empty or `nextDelay` advances, partial-bin mutation, and exhaustion just before
closure. The recorder and independent component now exist. The separately selected
native route is integrated below; its fresh end-to-end result remains unqualified.

## Implementation checkpoint

`DatagramImpairmentQueue` now accepts explicit `recordRateLedger: true` and exports
through `rateLedgerSnapshot()`. The recorder retains at most 131,072 operation rows
and 32 MiB of serialized evidence, reserving 2 MiB for bounded initial/final FIFO
metadata. JavaScript heap usage is separately bounded by those row/FIFO limits;
32 MiB is not a claim about the engine's object representation. Ordinary packet
operations perform no JSON serialization and retain no payloads. Exhaustion is
sticky, invalidates only the proof, and leaves queue forwarding unchanged.

`qualifyRateLedger({ ledger, limited, restored }, { configuration })` independently
reconstructs every token advance, receive/drop/forward decision, first actual
ready-head denial, and final FIFO. Its configuration is explicitly supplied by
the caller. It reconciles each disposition in every 100 ms bin against restoration
minus limit snapshots, including partial boundary bins. It reports rate binding
only; adaptation, recovery and production qualification remain false.

Review reproduced an omitted same-time empty advance hidden by renumbering the
ledger. The phase snapshot ordinal anchors and a regression test close that gap.
Code review also reproduced a predicted wait rewritten as a denying operation,
with a matching forged ledger witness. A separately copied first-denial witness
in the phase snapshot now binds that branch; a coherent row-and-witness mutation
must fail even though all tokens, FIFO counters and ordinals still match.
No old artifact can acquire this evidence retrospectively. The historical 500 ms
congestion gate, default lossless media gate, proxy export and native runner remain
unchanged. The next integration must export the separate bounded artifact, select
this proof explicitly, retain all other transport checks, and compose it with
causal native pressure, bounded live-loss conservation and fresh recovery.

Verification: 18 observer tests and 47 independent replay tests pass. The complete
tooling suite passes 4,556 tests, with a joined exit 0 in
`artifacts/qa/repeated-live-checkpoint-rate-ledger-tools-20260925-c-exit.json`.
Initial missing-feature and later omitted-no-op failures are retained alongside
the green logs under `artifacts/qa/repeated-live-checkpoint-rate-ledger-*`.
Formatting and `git diff --check` pass. No simulator was created or installed for
this component checkpoint. Final specification and code-quality reviews found no
remaining actionable findings after independently repeating both corruption
regressions.

## Explicit native integration

Use a separate host-only environment selection,
`SCOREBUG_TEST_CAPACITY_EVIDENCE=rate-ledger-v1`, valid only with the complete
existing native capacity-recovery route. An absent selection retains
`congestion-v1` and the historical lossless contract. Unknown values and selection
outside that route fail before resource creation. This changes laboratory
qualification only and grants no production authority.

The native fixture receives `capacityEvidencePolicy`. Only `rate-ledger-v1`
enables the forward queue observer. The proxy exposes a separate final
`rateLedgerSnapshot()` accessor for its forward queue; its normal snapshot never
contains the growing ledger. After joined proxy closure, export compact JSON to
`uplink-rate-ledger.json`, with an enforced 32 MiB bound and idempotent cleanup.
Null/incomplete/overflowed evidence may be preserved for diagnosis, but must fail
qualification. Export errors must not skip resource cleanup or be treated as a
passing result.

Transport qualification accepts explicitly trusted `stimulusPolicy` and separate
raw `rateLedger` options. The default `congestion-v1` keeps the 500 ms/overflow
criterion exactly. The new `rate-ledger-v1` replaces only that stimulus criterion
with `qualifyRateLedger`, deriving queue configuration from the selected profile
and binding to the original limited/restored snapshots. Keep configured loss,
socket closure, pending sends, foreign-peer checks, phase timing, offered load,
rate ceilings and baseline/restored traffic unchanged. Merely attaching a ledger
to historical input cannot select this policy.

The complete capacity policy receives the trusted `capacityEvidencePolicy` and
raw `rateLedger` separately. Only the explicit ledger route selects the existing
`accounted-bounded-v1` live-media contract in both the preliminary native harness
check and shared raw native evidence. The archive stays lossless. Other measured
routes reject this bounded media option. Keep admission/probation, causal clocks,
native pressure/decrease, delivery ownership and all recovery gates intact.

Implement with red/green tests for route validation, bounded/idempotent export,
transport false positives and retained gates, default compatibility and explicit
media-option propagation. Review and run the full tooling suite before freezing
source/input hashes and starting one fresh native 750 kbps experiment. Use the
installed runtime and remove only the experiment-owned temporary simulator.

The integration is implemented. Host selection is validated before resource
creation, and `capacityEvidencePolicy` is recorded in requested options and final
results. Explicit transport results retain `stimulusPolicy` and the independent
`rateLedgerProof`; the complete policy also reports bounded `mediaConservation`
with zero health credit. Historical outputs remain unchanged by default.

Focused red/green tests and the real loopback export/replay pass. The full tooling
suite passes 4,642 tests, joined exit 0 in
`artifacts/qa/repeated-live-checkpoint-rate-native-integration-tools-20260925-exit.json`.
Specification and code-quality reviews found no actionable issues. Fresh native execution is still
pending and must use new frozen evidence; no previous result is relabeled.
