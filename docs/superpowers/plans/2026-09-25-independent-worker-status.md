# Independent worker status polling implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development or
> superpowers:executing-plans. Preserve the original failed native evidence.

**Goal:** Keep worker health acquisition responsive while unrelated broadcast
control maintenance awaits, without changing delivery freshness or authority.

**Architecture:** Run foreground control maintenance and worker status polling on
separate schedules. One owned status request supplies the existing freshness,
source, delivery, probe and audit paths. Revocation is immediate; teardown joins
owned work before closing its evidence. Local capture remains independent.

**Tech stack:** Swift concurrency, SwiftUI, URLSession, XCTest, existing native
file-input/SRT/worker test harness.

## Evidence and design

The frozen `native-app-DhjMLB` run fails one delivery window at 290.084 ms sample
age. The next status request waits behind 300.843 ms of control maintenance;
its HTTP time is only 19.492 ms. The aggregate maintenance timing cannot attribute
the delay to a specific operation. The current order structurally allows restore,
persistence, capture report flushing and broadcast-command recovery to delay every
worker status request. An independent request lane removes this dependency; it
does not guarantee freshness when the host or network itself stalls.

Moving status to the beginning of the same serial loop still leaves the following
request blocked behind maintenance. Parallel acquisition followed by awaiting all
maintenance would retain an already-aging response. Use a separate single-flight
lane that consumes a response immediately, after validating its current owner.
Do not widen the 250 ms freshness or two-second live consumption limits. Do not
replace the unknown row from the saved run with a historical classification.

Independent timing review also finds a coincident proxy dispatch gap: host bins
260000–260199 ms contain no forward/reverse events, followed by roughly
299/290 ms maximum queue residence. The harness/proxy and control-plane API run
in separate Node processes. Restoration and its clock response precede this gap;
no existing observation identifies GC or a particular maintenance operation as
its cause. Native delivery evaluation occurs during the maintenance interval, so
the native actor is not continuously blocked for all 301 ms. Preserve this
uncertainty: the split removes a proven sequencing dependency, not every possible
host scheduling interruption. If it recurs, separately sample bounded event-loop
and GC timing in the harness/API and record maintenance substage durations;
[Node performance hooks](https://nodejs.org/api/perf_hooks.html) provide those
measurements. Such diagnostics must not supply qualification or healthy credit.

## Task 1: Owned status lane and native regressions

Files:

- Modify `ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`.
- Modify `ios/Sources/Scorebug/UI/ContentView.swift`.
- Test `ios/FilmModelTests/CaptureStreamingModelTests.swift` (existing
  `CaptureTestServer` and `FilmTestGate` can hold individual requests).

- [x] Write failing tests demonstrating that a held coordinator recovery does
      not prevent independent current worker status acquisition, and that a held
      status request does not prevent maintenance or immediate publisher detach.
- [x] Extract the existing request-through-quality-tick body into
      `pollWorkerStatus()`. Preserve `pollControl()` as the compatibility entry
      point; a maintenance-only selection lets the foreground control schedule
      avoid double polling. Keep existing queued-start failure behavior.
- [x] Capture request identity, worker epoch, endpoint/credential identity,
      broadcast selection and publishing owner. Validate them after every await
      before status mutation, quality work, or error handling. An obsolete result
      must not clear or stop a newer owner. Reuse existing scope checks.
- [x] Keep a single-flight slot. Concurrent manual/foreground callers coalesce or
      skip, never issue overlapping delivery-cursor reads. Old completion can
      release only its own slot. Propagate cancellation explicitly for any stored
      unstructured task; cancellation is not a publisher network failure.
- [x] Add a foreground worker-status schedule using the existing selected poll
      interval. It must neither check `controlBusy` nor await control maintenance.
      Preserve truthfully sampled request, receipt and native-probe timing.
- [x] Revoke status authority and detach capture synchronously on stop. Join the
      captured request before closing/exporting its evidence. Avoid a cycle where
      status error waits for teardown which waits for the same status request.
- [x] Test concurrent callers, old success/error after owner replacement,
      cancellation during a native probe read, no cursor duplication, and no
      post-close audit rows. Do not hide deadlocks by dropping joins or accepting
      stale ownership. Suspended mock requests must be explicitly released.
- [x] Run the focused FilmModel target, then the complete existing native model
      target and tooling suite. Review ownership/cancellation independently.
      Commit only verified source and plan changes.

## Task 2: Fresh laboratory qualification

- [x] Freeze the reviewed commit and all source/input hashes. Reuse installed
      iOS 26.2, the prepared representative match file and the explicit
      `token-budget-v1` route in
      `artifacts/qa/native-capacity750-token-budget-run.py`.
- [x] Run the complete joined native workflow. Inspect full A/V decodes, archive
      and live frame IDs, score/audio checks, raw capacity policy and causal clock
      brackets. Preserve any failure and its original evidence.
- [x] Verify unchanged frozen hashes and deletion of only the owned simulator.
      Update the main plan with the actual result. Fresh post-restoration ramp,
      physical phone/Watch and remote host qualification remain separate gates.

## Review constraints

Keep source classification and recovery requirements unchanged. Control responses
continue to own setup/start/stop decisions; worker responses supply scoped media
health. A pending control request may block replacement startup as before, but
must not block health acquisition for the existing publisher. An epoch change
revokes old results immediately, even when its network cleanup still awaits.
No status request may outlive its audit owner and later append evidence to it.

The following next feature is deliberately separate: autonomous repeated probes
need one owned measurement lifecycle spanning registration, native allocation,
joined failure, successful admission and revocation. Reuse the approved
10/20/40/60-second observed-health backoff; do not use a host restoration signal
or probe/candidate ordinal equality to authorize a new attempt.

## Preserved follow-on design: measured attempt ownership

Read-only review found no existing Core API for failed probes before admission.
`QualityController.evaluateCandidate` receives only completed admission evidence;
`invalidateTelemetry` clears health without advancing backoff. Reusing
`acknowledge(nil)` or synthesizing delivery failure would invent events. Native
SRT start/restart already supports `recovery-budget-v1` with fresh UUID, authority,
stage-one allocation and zeroed per-campaign counters; retain its 60-second,
16 MiB and 300 ms lease bounds.

The follow-on lifecycle must cover registration, successful admission, failure and
revocation together. Session first validates actual current readiness and pins
publication/clock/encoder ownership; Core mints one opaque measurement token.
Only the owning scheduler may register native allocation and join it. Keep advisory
readiness readable during an active probe because stage-three refresh needs it;
reject duplicate allocation at registration instead.

A joined failure consumes its token once, clears source and shared delivery health,
and advances the monotonic earliest-health boundary. Factor failure-episode counting
out of `latchMinimumReset` rather than invoking its encoder-reset and application
revocation side effects. Registration begins the new episode without clearing the
failure count; a delivery failure during the same episode must not count twice.
Only confirmed trial success clears consecutive failures. Reject duplicate, foreign
and obsolete completions before clock/health mutation; they must not revoke newer
applications. Revocation prevents policy work immediately while cleanup still joins.

Successful admission must identify the same measurement token and actual probe
handle, with measurement timestamps inside that attempt. A separate generic
`measured` success callback would leave admission unbound. Remove candidate/probe
ordinal equality: failed probes before candidate allocation consume no candidate
ordinal. Every allocation still needs a distinct bounded audit and total attempt
ceiling, with failed attempts retained. The four-phase capacity experiment needs
its own export/qualification route; existing three-phase capacity and five-phase
repeated-decoder-fault routes keep their contracts.

A probe can fail while the lowest profile remains healthy before restoration. It
must retire, wait for the approved observed-health hold, and retry on the same
applied revision with new ownership. Neither the host restoration clock nor an
elapsed timer may authorize it. Offline clock brackets subsequently prove that a
successful fresh measurement and trial followed actual restoration. This design
is not implemented or qualified by the independent polling work.

## Implementation checkpoint

The independent foreground lane and compatibility polling are implemented.
Seven new model tests cover the held coordinator, shared single-flight status,
held request with immediate detach/joined export, cancellation during native
probe read, obsolete success/error, current failure without self-deadlock, and
queued-start failure during maintenance. Both the original blocking regression
and the queued-start race were reproduced before their fixes. The latter now
ends only the currently queued start after a current owned status failure;
obsolete or canceled failures cannot poison a later intent.

All 99 capture-model tests and all 583 FilmModel tests pass. The complete model
run is joined in `artifacts/qa/independent-worker-status-models-full.log`.
Independent specification and concurrency reviews found no actionable issues.
The full native app build is still required to compile the SwiftUI schedule and
qualify the real workflow. No simulator was created or runtime installed for
these model tests. The saved DhjMLB failure remains unchanged.

The full tooling suite also passes all 4,702 tests, joined exit 0 in
`repeated-live-checkpoint-independent-worker-status-tools-20260925-exit.json`.
The next native execution freezes this reviewed source before compiling the full
app and collecting new evidence; source/docs must not change during that run.

## Fresh native result

The full app compiles and runs at frozen `1c311f0`. Run `native-app-kEQWC0`
joins with exit 1 after its UI workflow and both complete A/V decodes. All 1,264
frozen hashes are unchanged, and simulator `1C60DC48-D69F-41FB-8666-4D98F9829AFF`
is absent from the post-cleanup inventory. No runtime was installed.

All 331 delivery windows have a result, with maximum sample age 155.987 ms.
Thus this run does not reproduce the prior freshness failure. The full native
qualification nevertheless fails: 60 locally compressed frames disappear at the
first downshift GOP, while the clean archive remains consecutive (7,518 frames).
See the [next investigation](2026-09-25-transition-gop-loss.md). Passing this
polling-specific observation does not qualify media recovery or the next ramp.

A subsequent complete native run at `e0477be`, `native-app-uG39s5`, also has no
unknown delivery rows and passes the full laboratory workflow after the separate
mux continuity repair. All 325 windows classify with maximum sample age214.162 ms.
See the [fresh native checkpoint](2026-09-25-transition-gop-loss.md#fresh-native-laboratory-pass)
for full media, source-freeze and cleanup evidence.
