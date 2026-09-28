# Fault coverage and native reconnect gap — September 28

Starting b7044b2, clean authoritative worktree. Previous goal turn made progress:
fixed delayed processing and UHD accounting, verified actual UHD admission, retained
truthful native media failure. No prior live jobs remained.

Inspected the saved 4K failure and current queue/codec paths.148capture versus146
encoded/received and actual receiver PTSgaps place the missing frames before remote
processing, but do not distinguish app ingress, SDK raw queue or native encoding.
The SDK raw input queue has two slots; do not enlarge it based on this inference.
Current probation/reset and recovery behavior follow the existing policy. No
threshold, encoder recipe or queue change is justified by these observations alone.

Audited existing fault evidence instead of rerunning it. collect.py under
artifacts/qa/fault-coverage-20260928 matches19passing test lines to present current
methods/assertions, records hashes and explicitly labels historical scope. The
[coverage matrix](../local-fault-coverage.md) separates those passes from real media
and hardware gaps. Runtime delivery control beyond finite audit caps is covered;
optional whole-run audit completeness remains separate.

## Actual missing behavior and next implementation

CaptureStreamingModel.pollLocalHealth currently treats native publisher failure as
terminal: detach, shouldStopOwnedBroadcast=true, failed state and manual retry.
By contrast, handlePollingFailure preserves publishing across recoverable HTTP
outages. Thus prior API/worker-crash tests do not cover native SRT reconnection.

Implement bounded automatic native reconnect for the same still-active recording
and still-authorized broadcast. Prefer reusing the running server generation after
joining the failed publisher over stopping/restarting the broadcast: stopping first
makes a remote user stop indistinguishable from the app's own stop. Fresh publish
access already binds a new publishingAttemptId; beginStreaming reuses the current
selection when it is still running.

Keep reconnect intent bound to capture object/tap, game, selection and generation.
Retry from minimum after a bounded backoff (reuse established delay values where
appropriate). The background control poll must successfully revalidate ownership
before retry; beginStreaming must recheck after every suspension and must not issue
a new .start when an automatic retry sees stopped/changed ownership. Explicit Stop,
capture replacement/end, match end, setup/auth failure or foreign/new generation
cancels intent. Recording never restarts. Join old publisher teardown before a new
publisher. Back off repeated startup failures; expose reconnecting state/message.
Do not let a stale HTTP snapshot or a late start resurrect an explicitly stopped
stream. Existing manual Start behavior remains supported.

Use the existing CaptureTestServer/publisher gates for focused tests: failed native
publisher→same authorized generation/new publisher, blocked teardown, offline
control, explicit Stop/capture replacement, remote stop/generation/selection change,
and failed reconnect followed by recovery. Then one bounded native total-outage
workflow; no repeated Watch/scoring/full suites. Preserve the 4K evidence and defer
its performance work until the missing recovery feature is implemented.

No new capture or test suite ran this session. No code was changed or failure
reclassified as a pass. Coverage verification changes the next action from generic
fault retesting to a specific missing native recovery feature. Goal remains active.
