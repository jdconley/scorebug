# Owned measurements and automatic recovery retries

**Goal:** After upload capacity returns, retry failed measurements using actual
healthy media coverage and complete a fresh quality increase without a host cue.

**Starting checkpoint:** The three-phase native laboratory route passes at
`e0477be` (`native-app-uG39s5`): 240p → 360p → 240p, intact archive/live files,
and classified recovery after restoration. It does not perform a new increase.
The existing repeated fixture permits two campaigns and requires a new applied
revision between them. A failed probe can spend its final opportunity before the
network recovers. Raising a timeout cannot repair this ownership/policy gap.

**Architecture:** Core issues one opaque measurement attempt from current
readiness. Session pins its exact publisher, configuration and telemetry identity
and owns a native campaign lease. A scheduler may renew/advance that lease, admit
its final-stage candidate, or settle failure; it cannot assert that cleanup joined
or manufacture a successful measurement. Existing unregistered callers retain
their behavior. The new path remains explicit until its complete native route is
qualified.

## Required semantics

Readiness is advisory and remains queryable during measurement. Registration
rechecks actual current readiness and rejects duplicate allocation. Its freshness
expiry authorizes registration, not the whole campaign duration. Preserve the
native 60-second / 16 MiB campaign, 300 ms lease and separate seven-second
candidate-measurement bounds.

The stable lease identity contains the opaque Core and Session IDs, publication,
applied revision/receipt, baseline and exact target, native generation/policy,
campaign start and optional native campaign ordinal. A stage's UUID, start and
authority may change only through an awaited owned native allocation/replacement.
Stage replacement verifies a fresh UUID, next stage, unchanged campaign identity,
zero stage bytes and preserved cumulative accounting. A snapshot cannot adopt a
foreign allocation. A native restart begins a new Core token and Session lease.

Successful candidate admission must reference the actual final-stage UUID. Keep
the existing cost-binding and receiver-interval identity checks. Once a candidate
binds that stage, disallow another stage replacement; bounded renewal can continue
while awaiting current source coverage. Admission is not completion. Retain probe
ownership until `beginApplication` rechecks authority and transfers it to the
owned encoder application. The expected profile-write revocation is not an extra
measurement failure.

Same-owner failure or abandonment retires and joins actual work before settling
the attempt. Settlement consumes its token once, clears strong/source/shared
delivery recovery coverage, preserves source/delivery watermarks and advances the
earliest-health boundary monotonically. Factor failure-episode counting out of
the minimum-reset helper; do not fabricate an encoder application, profile write,
delivery failure or minimum reset to increment it. Retain pending downward advice.

Use the approved observed-health holds: 4 seconds initially, then 10/20/40/60
seconds following failures. Starting a new measurement opens an episode without
clearing the count. Delivery failure and measurement failure during one attempt
count once in either order. Only confirmed trial success clears the count.
Foreign, duplicate and obsolete completions must be rejected before clocks or
health mutate; they cannot cancel a newer encoder application.

Stop or configuration replacement revokes policy authority immediately. Cleanup
continues independently and joins before audit export or another allocation.
Never hold Session's global `busy` flag while waiting for measurement work:
source evaluation and downward action must remain responsive. Always retain a
returned allocation before rechecking ownership so even a canceled allocation
can be retired correctly. An old cleanup completion has no authority over a new
lease. Verified ownership retirement is non-counting; generic caller cancellation
cannot bypass backoff.

## Task 1: Exact native retirement and join

Files: vendored `SRTStream.swift` and probe tests, Streaming publisher adapters
and their probe tests, maintained SDK patch/provenance.

- [x] Add an explicit exact-owner retirement primitive that revokes probe sends
      and joins the captured wake task. Existing `cancelBandwidthProbe` cancels
      that task but does not await it. Native probe revocation already serializes
      with the nonblocking send under its lock; retain that behavior.
- [x] Keep the old cancellation API's behavior. Capture immutable old ownership
      before suspension. Duplicate joins should coalesce; cancellation of a
      waiter must not abandon cleanup. Completion must not clear a replacement
      probe or overwrite its state. Preserve restart from the terminal identity.
- [x] Propagate trusted retirement through adapters with exact identity checks
      and joined allocation/renewal/replacement work. Reject foreign owners
      without mutating current state. Avoid self-await in operation error cleanup.
- [x] Test a cancellation-ignoring held wake, concurrent waiters, a replacement
      crossing retirement completion, stop, canceled waiter, and no further sends
      after revocation. Run focused and full relevant SDK/Streaming suites;
      verify the maintained patch against all original hashes. This component
      alone does not enable retry scheduling or qualify recovery.

SDK checkpoint: the new exact-owner primitive passes **39 focused / 333 full
vendored tests** with Xcode 26.2. Regressions first reproduced early return from
legacy cancellation and premature rejection during close, finish and failure.
Final cases cover held wakes, duplicate and canceled waiters, replacement/restart,
new publication, preserved terminal reasons and rejected late native sends. All
test processes joined. The maintained patch verifies all **162 original hashes**
and an exact round trip. Logs are
`artifacts/qa/owned-probe-retirement-sdk-final-{focused,full}.log`; this is a
component checkpoint, not a new native media or automatic retry qualification.

Adapter checkpoint: **45 focused / 202 full Streaming tests pass**, including
13 new regressions. Both adapters retain raw returned allocations before
validation, route cancellation to the actual owned target, and join rejected
work before reporting its original failure. Public retirement coalesces cleanup;
foreign identities and old accepted predecessors cannot revoke a replacement.
Real cleanup failure blocks further probe admission. Downward encoder changes
remain available while cleanup waits, and shutdown joins its captured work.

Independent review found a late-allocation ordering gap: retirement could cancel
A while its replacement was still allocating, then returned B could suspend in a
health read before cleanup. The regression first failed both cleanup and ordering
assertions; both bridges now check revocation before that read. Final logs are
`artifacts/qa/probe-retirement-late-allocation-{red,focused-green,full-green}-20260925.log`.
All processes joined, specification and code-quality reviews approve the final
checkpoint, and `git diff --check` passes. Task 1 is complete; it enables joined
cleanup, not automatic retry scheduling or production quality increases.

### Adapter cleanup contract

Each adapter keeps accepted probe authority separate from an operation's raw
returned allocation. Capture the raw handle before validating its fields or
awaiting health: replacement can allocate B while the caller still owns A, then
lose admission to cancellation. That operation must retire and join B before
throwing. A public retirement of A joins the captured operation and its exact
cleanup obligation; it cannot query a global snapshot and adopt whichever probe
is current. Retain only bounded, operation-owned cleanup records.

Failure cleanup calls a leaf retirement operation in the lower layer, never its
own public retirement method. Public retirement may join that operation, so the
reverse dependency would deadlock. Coalesce duplicate joins and shield cleanup
from waiter cancellation. Conditional operation IDs protect slot cleanup and
revision changes from old completions. Keep downward encoder action available
while retirement waits, but admit no new probe operation through that barrier.

Close-first races also require evidence of completion: an exact retained SDK
probe can join the close task that captured its wake, or the already completed
close. It must preserve the original terminal reason and cannot mutate a newer
publication. An obsolete error alone is never proof of joined cleanup. An adapter
operation must not await its own shutdown, since shutdown already joins it.

The adapter retirement barrier is cleanup-only. A valid native replacement B
that loses admission after allocation is joined through its predecessor A, but B
does not become accepted scheduling authority. The existing restart API therefore
cannot recover that case merely by changing its argument from A to B. Task 2
needs a separate owned restart path: retain a validated allocation chain apart
from live-health admission, combine it with the SDK's exact joined terminal
snapshot, and issue an opaque retired-probe receipt only when both match. Session
rechecks its current configuration before using that receipt for a new attempt.
Malformed or unproven allocations require stop/recreation; a global snapshot
cannot supply the missing ownership proof.

## Task 2: Core token and Session campaign lease

- [ ] Add the owned terminal receipt/restart path described above, preserving
      legacy accepted-identity APIs. A canceled valid late allocation must be
      recoverable without a global snapshot; malformed, foreign and unjoined
      receipts cannot authorize another campaign. Test canceled initial and
      replacement allocations through both adapter layers.
- [ ] Implement the complete lifecycle: begin, bound candidate admission,
      unsuccessful settlement and verified ownership retirement. Token creation
      is private. Preserve ordinary admission when no owned attempt exists;
      reject competing unregistered admission while the owned route is active.
- [ ] Inject native begin/renew/replace/restart/snapshot/retire operations once
      into Session. Keep campaign start/cumulative counters internally because
      the current public observation omits them. Allocate and retain a task
      before suspending; store every returned handle before validation.
- [ ] Bind final measurement timestamps and candidate identity to the lease,
      exact configuration and final stage. Do not add a generic unbound
      `measuredSuccess` event or per-call `joined: true` assertion.
- [ ] Share existing failure-episode counting without profile side effects.
      Preserve downward advice and consumed evidence watermarks. Reject crossing
      source/shared-delivery windows as new recovery credit.
- [ ] Test same-revision retry holds through 10/20/40/60 seconds, both failure
      orderings, obsolete/foreign tokens with invalid clocks, three changing stage
      UUIDs, foreign snapshot rejection, cancellation during allocation and
      replacement, pending-candidate renewal, expected profile-write revocation,
      held cleanup with immediate downward action, and unchanged default callers.

### Core lifecycle implementation notes

Use a public opaque token with private construction, controller identity and
nonce, held privately by Session. Registration recomputes readiness. Bound
admission and application transfer require that exact token and its expected
phase; application transfer consumes measurement authority. SPI visibility and a
caller-provided cleanup flag would not prove retirement and are unnecessary.

Put token/scope/duplicate checks before the existing candidate validation's
`do/catch`: that path advances time and invalidates telemetry on rejection, so an
obsolete owned callback must never enter it. Preserve ordinary callers' existing
validation behavior when no owned attempt exists. Factor episode counting out of
`latchMinimumReset`; failure settlement must not fabricate an application/reset or
clear unrelated downward advice. Keep one episode through measurement, admission,
application and probation. Only confirmed trial success clears the counter.

Non-counting Core retirement requires an exact retained token whose applied
revision has already changed, with no time argument or other state mutation.
Same-revision cancellation must use unsuccessful settlement after actual joined
cleanup. Terminal Session stop can revoke access and discard its controller.
Receiver/configuration changes that do not advance Core's revision need an
explicit verifiable owner-scope identity before qualifying for non-counting
retirement; a caller-selected reason is insufficient.

Session settlement clears source/shared-delivery recovery credit but retains
all consumed-evidence watermarks. Exclude complete windows crossing the settlement
boundary. `PublishingCandidateRecoveryCoverage.clear()` alone is insufficient
because it also clears `resumedAt`; apply the monotonic boundary on future input.

## Task 3: Bounded scheduler and fresh native four-phase experiment

- [ ] Replace the two-campaign/revision-only fixture assumption on a distinct
      route. Use current readiness and newly accumulated healthy coverage; neither
      the host restoration clock nor an elapsed wait authorizes another attempt.
      Retain failed attempts, independent probe/candidate/trial ordinals, a finite
      overall attempt/event/byte budget and joined retirement for every allocation.
- [ ] Define a separate 240p → 360p → 240p → 360p export and qualifier. Replay the
      complete global source/delivery history, including failures and terminal
      suffix. Do not slice raw evidence into synthetic sessions or alter existing
      three-phase capacity/five-phase decoder-fault contracts.
- [ ] Choose an experiment duration only after checking native source length,
      UI timeouts and audit bounds. A 270-second hold would roughly add 600
      cadence rows and 90 delivery rows to current runs, nearing the unchanged
      3,072/512 limits. The prepared input is 330 seconds. These are feasibility
      estimates, not permission to widen limits or skip tail coverage.
- [ ] Require a fresh successful measurement and trial after independently
      bracketed restoration, complete full-file archive/live/score/audio checks,
      and at least 24 fps under the existing delivery/loss gates. Preserve any
      failure, all frozen hashes and only-owned-simulator cleanup.

Resource preflight against the passing `native-app-uG39s5` artifacts: the
210-second hold retained 2,356 cadence rows (9,089,096 file bytes) and 325 delivery
rows (21,732,386 file bytes). A prospective 270-second hold, assuming unchanged
polling and delivery cadence, adds about 600 and 90 rows: 2,956/3,072 cadence rows
and 415/512 delivery rows. Scaling by current mean row size estimates 11.4 MB and
27.8 MB, below the unchanged 16 MiB/32 MiB bounds; these averages are not worst-case
guarantees, especially with more campaign fields and failure events. The passing
archive lasted 248.9 seconds, so adding 60 seconds would consume about 308.9 of the
prepared input's 330 seconds, leaving only 21.1 seconds of source margin. Existing
generic test budgets permit a 270-second hold (450-second XCTest allowance and
690-second workflow timeout). No duration is selected or route qualified by these
estimates. Recheck complete event/byte bounds and source margin after the scheduler
and four-phase export exist; fail explicitly on exhaustion, never truncate history.

Physical iPhone/Watch camera, cellular and thermal tests and remote proxy/GPU
qualification remain later gates. No production upgrade flag changes merely
because these components pass unit tests or because the three-phase run passed.
