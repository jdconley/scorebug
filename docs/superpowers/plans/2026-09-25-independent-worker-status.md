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

## Task 1: Owned status lane and native regressions

Files:

- Modify `ios/Sources/Scorebug/Capture/CaptureStreamingModel.swift`.
- Modify `ios/Sources/Scorebug/UI/ContentView.swift`.
- Test `ios/FilmModelTests/CaptureStreamingModelTests.swift` (existing
  `CaptureTestServer` and `FilmTestGate` can hold individual requests).

- [ ] Write failing tests demonstrating that a held coordinator recovery does
      not prevent independent current worker status acquisition, and that a held
      status request does not prevent maintenance or immediate publisher detach.
- [ ] Extract the existing request-through-quality-tick body into
      `pollWorkerStatus()`. Preserve `pollControl()` as the compatibility entry
      point; a maintenance-only selection lets the foreground control schedule
      avoid double polling. Keep existing queued-start failure behavior.
- [ ] Capture request identity, worker epoch, endpoint/credential identity,
      broadcast selection and publishing owner. Validate them after every await
      before status mutation, quality work, or error handling. An obsolete result
      must not clear or stop a newer owner. Reuse existing scope checks.
- [ ] Keep a single-flight slot. Concurrent manual/foreground callers coalesce or
      skip, never issue overlapping delivery-cursor reads. Old completion can
      release only its own slot. Propagate cancellation explicitly for any stored
      unstructured task; cancellation is not a publisher network failure.
- [ ] Add a foreground worker-status schedule using the existing selected poll
      interval. It must neither check `controlBusy` nor await control maintenance.
      Preserve truthfully sampled request, receipt and native-probe timing.
- [ ] Revoke status authority and detach capture synchronously on stop. Join the
      captured request before closing/exporting its evidence. Avoid a cycle where
      status error waits for teardown which waits for the same status request.
- [ ] Test concurrent callers, old success/error after owner replacement,
      cancellation during a native probe read, no cursor duplication, and no
      post-close audit rows. Do not hide deadlocks by dropping joins or accepting
      stale ownership. Suspended mock requests must be explicitly released.
- [ ] Run the focused FilmModel target, then the complete existing native model
      target and tooling suite. Review ownership/cancellation independently.
      Commit only verified source and plan changes.

## Task 2: Fresh laboratory qualification

- [ ] Freeze the reviewed commit and all source/input hashes. Reuse installed
      iOS 26.2, the prepared representative match file and the explicit
      `token-budget-v1` route in
      `artifacts/qa/native-capacity750-token-budget-run.py`.
- [ ] Run the complete joined native workflow. Inspect full A/V decodes, archive
      and live frame IDs, score/audio checks, raw capacity policy and causal clock
      brackets. Preserve any failure and its original evidence.
- [ ] Verify unchanged frozen hashes and deletion of only the owned simulator.
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
