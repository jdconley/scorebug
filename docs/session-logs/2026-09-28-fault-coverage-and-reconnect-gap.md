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

The initial coverage audit required no new capture or suite. It changed the next
action from generic fault retesting to the missing native recovery feature, which
was then implemented and verified below. Goal remains active.

## Reconnect implementation and verification

Native connection/append failure now retains an in-memory retry intent bound to
recording ID/tap, game and broadcast generation. It joins teardown, requires a
successful fresh control poll, and obtains new publishing access for the same
running selection without issuing another broadcast Start. Delays are2/4/8/16/30s;
30seconds of continuously publishing session health resets that failure count.
These are bounded project retry settings, not claims about platform standards.
Explicit Stop/capture replacement/end, authorization failure and changed/stopped
broadcast cancel intent. Automatic terminal failure never stops a new generation.
Manual Start still works. A reconnecting status preserves the Stop control.

Focused evidence under artifacts/qa/fault-coverage-20260928:

- reconnect-before.log: one baseline regression fails3assertions: no replacement,
  failed local state, and unwanted broadcast Stop.
- reconnect-after.log: first retry and joined-teardown tests pass.
- reconnect-guards.log:8tests pass in3.319s, covering same-generation retry, six
  cancellation cases, offline fresh-control requirement, startup backoff and existing
  control/stop guards. One extra selector named a nonexistent interruption test;
  it ran no test and is not counted.
- reconnect-stop-race.log: in-flight publish-access reply after explicit Stop cannot
  construct a publisher (0.124s).
- reconnect-controls.log: six cancellation variants also check reconnecting/Stop
  availability (0.742s).
- reconnect-simulator-build.log: incremental arm64 iOS Simulator app build succeeds.
  No physical signing, simulator boot or unrelated suite was repeated.

One actual native70-second run, headless-native-omoEsi / device-lab-Q0T9a3,
terminates its sole SRT publisher via the lab-owned relay API. The documented
[MediaMTX1.21 API](https://raw.githubusercontent.com/bluenviron/mediamtx/v1.21.0/api/openapi.yaml)
uses /v3/srt/conns/kick/{id}; no connection query credentials are retained in the
fault record. Lifecycle: publishing0s, failed15s, publishing17s with a new attempt,
same recording and generation1. Recorded/publishing at end, elapsed71s, cleanup[].
This is real connection termination, not a sustained packet blackhole/radio loss.

Existing RecordingLibrary export reused that capture. Offline4-thread decode of
archive and four output files verifies2137consecutive archive frames0–2136, zero
archive audio gaps, and uninterrupted within-session live video/audio. Both output
destinations have identical source IDs:62–444 before failure and582–2116 afterward.
The137missing live frames represent4.567seconds of actual outage; they are reported,
not hidden. All five A/V end offsets are within31ms. SQLite has exactly one Start
and one final explicit Stop, with no broadcast restart on reconnect. Static score
was unchanged; changing-score/Watch workflows reuse their retained qualification.

Reports/hashes: omoEsi/reconnect-media/result.json, input-output-hashes.json,
implementation.patch/json and diagnostic.json. Full workflow/media handles3259,
89195,7251joined0. Focused handles62190joined65(expected baseline),36182/18314/
76448/47882joined0; simulator build13326joined0. All jobs terminal.

The headless runner now supports --disconnect-after15 with bounded/abortable
injection and lifecycle evidence; normal runs still stop on unexpected publishing
failure. UI-only changes followed the captured native implementation and received
focused control assertions plus the simulator build. Formatter and diff checks pass.
