# Reconnecting diagnostic recorder implementation plan

> Execute inline with `superpowers:executing-plans`; autonomous routine design and
> implementation are authorized. Review the completed bounded change.

**Goal:** Keep the local fault-test output endpoint available across worker
reconnections while preserving separate session recordings and failure evidence.

**Architecture:** A persistent Node TCP loopback listener accepts RTMP connections.
Each connection is paused until its own existing single-session FFmpeg recorder
is listening on an allocated private loopback port, then a backpressured duplex
TCP pipe connects them. Preserve every session; never concatenate media or infer
continuity. The existing strict single-session fixture stays unchanged.

**Tech stack:** Node `net`, existing direct RTMP recorder, FFmpeg, node:test.

## Contract and alternatives

Restarting the public FFmpeg listener after EOF leaves an avoidable connection-refused
window. Reusing the MediaMTX recording sink changes the timestamp/muxing path under
investigation. Instead keep a stable loopback front end, preserving RTMP bytes and
FFmpeg's existing stream-copy recorder per connection. This is diagnostic tooling,
not a production proxy or a media/recovery success verifier.

Bound at8 accepted sessions and2 concurrent sessions (a new connection can arrive
while the old recorder is finalizing). Reject and count excess connections. Never
log payloads, addresses or arbitrary child errors. Create an exclusive artifact
subdirectory; per-session directories hold the existing recorder and timestamp
manifests. The aggregate manifest contains ordered session numbers, relative paths,
monotonic acceptance/connect/close times, byte counts, fixed failure reasons and
joined terminal state. All outputs explicitly deny media/recovery qualification.

`finish()` closes the listener to new connections, allows5s for existing sessions
to close naturally, and then tears down unfinished sockets/children. Record timeout
and interruption; never call forced termination successful media. `stop()` cancels
immediately and joins all pending startup, sockets, recorder finish and persistence.
Calls are idempotent. A session accepted but disconnected during startup must never
leave a late recorder running. Existing recorder startup5s and TERM/KILL budgets
remain in force. No publisher means no FFmpeg process is started.

## Implementation and verification

- [x] Add `scripts/test/reconnecting-rtmp-recorder.test.mjs`: use real loopback TCP
      sockets and an injected owned recorder to prove byte-preserving two-session
      forwarding, paths/ordering, idle stop, concurrent/total admission bounds,
      rejected recorder startup, early disconnect and shutdown during startup.
      Run `node --test scripts/test/reconnecting-rtmp-recorder.test.mjs` red first.
- [x] Add `scripts/reconnecting-rtmp-recorder.mjs` exporting
      `startReconnectingRTMPRecorder({artifact, ffmpeg, port}, dependencies)` with
      `{url, finish, stop}`. Use `createServer({pauseOnConnect:true,allowHalfOpen:true})`,
      a per-session recorder, and `client.pipe(upstream); upstream.pipe(client)`.
      Record fixed failure categories, close the unused half on error/cancellation,
      and join all owned lifecycle/persistence promises before returning.
- [x] Run focused existing/new recorder tests; inspect cleanup and malformed-path
      behavior. Run the complete tooling suite after review repairs.
- [x] Add a reusable local integration runner that publishes two distinct short
      H.264/AAC FFmpeg sessions sequentially to the same URL. Join publishers/recorder,
      decode both outputs with `-xerror`, verify frame/audio counts and distinct content,
      and inspect per-session timing manifests. Save the actual exit statuses and
      source hashes. No simulator/runtime or external host is needed.
- [x] Select the new endpoint only for the explicitly diagnostic capacity route.
      Keep strict single-session delivery and the normal capacity qualification denial.
      Document the new evidence and remaining causal native recovery work.

## Verified checkpoint

`artifacts/qa/reconnecting-rtmp-uwjgbn` joined with exit0. Two real FFmpeg publishers
sent distinct3s excerpts (at10s and30s) from the prepared representative match file
to one loopback URL. Each separate output contains90 video frames and134,144 mono
44.1kHz audio samples; both fully decode with `-xerror`. Final publisher frame
counts equal decoded output frame counts. First-frame hashes differ. Both original
single-session recorder manifests report readiness, natural exit0, no signal and
no requested termination. The aggregate contains two ordered noninterrupted
sessions, no rejections or errors, and no finish timeout. Each session has its own
raw packet-timing audit. All6 saved source/input hashes stayed unchanged.

The prepared source checksum remains
`adb1f0f81552190786703cdd73ed9504d2021a9b1c366f820390c78482240c59`.
This experiment tests the recorder with real match excerpts; it does not exercise
the native app, a network outage or controller recovery. No simulator was needed.

The explicit `--capacity-diagnostics` native route now selects this recorder and
retains its bounded closed session manifest in `capacity-diagnostics.json` under
`recorderSessions`. Ordinary collection rejects the diagnostic mode; default and
strict single-session routes retain the old recorder and verification. Interrupted,
empty, failed or excess sessions are recorded, never converted into qualified
media. Native capacity recovery remains guarded and unqualified.

Focused recorder/diagnostic tests passed84. The first complete tooling run exposed
a race in the total-session unit test: it sent new synthetic connections before
older recorder file writes had joined, legitimately exercising the separate
concurrency cap. The test now joins those finalizations before testing total
admission. No runtime limit was relaxed. The final complete tooling suite passed
all4,251 tests (`repeated-live-checkpoint-reconnecting-recorder-reviewed-tools.log`).
Independent read-only code review found no actionable issues.

Next: measure the complete native240p/360p wire-rate distribution without probe
padding, select a recoverable capacity limit, and run the explicit native diagnostic
campaign with this endpoint. Retained sessions still need causal worker/attempt,
source-ID, media/audio and gap qualification before any recovery success claim.
