# Worker capability reporting and native start preflight

Starting checkout: `codex/local-validation`, `a619d78`, clean. Previous turn was progress: native server recovery was fixed and verified. No hardware work or subagents.

## Implementation

Added versioned worker capabilities, bounded synthetic H264/AAC initialization with shared production encoder flags, authenticated registration/query, session-scoped monotonic heartbeat expiry, and native preflight before a new broadcast start. Failed/stale/unknown capabilities or a wrong output prevent the broadcast command while the archive continues. The current backend output configuration is reported separately from explicitly unqualified sustained performance. No input resolution ceiling is inferred from an output size or a short startup check.

See [behavior and upgrade order](../worker-capabilities.md). API first, worker second, app last; legacy workers remain accepted by the API but cannot satisfy the new phone preflight. Existing selected-stream recovery is preserved.

## Focused evidence

- Red API capability test failed before implementation (`worker-capabilities-red.log`).
- API tests:79 pass across capability, observation and status contracts (`backend-api-tests.log`).
- Worker tests:106 pass across capabilities, startup/shutdown, reporting and pipeline arguments (`backend-worker-tests-final.log`). Initial batch caught strict optional typing and an extracted encoder-return syntax error; both corrected before acceptance.
- Final malformed executable/cancellation/missing backend probe checks:3 pass (`backend-probe-final.log`). Both affected TypeScript projects typecheck (`backend-*-typecheck-final.log`); protocol builds.
- Native CaptureStreamingModelTests:119 pass (`backend-native-tests.log`). New cases cover stale, failed, unknown, wrong output and expired reports, no start command, intact recording and successful retry.
- Real check: `artifacts/qa/backend-capabilities-20260928/result.json`. Software and VideoToolbox H264/AAC initialization pass at1080p; NVENC fails as expected on this Mac. Actual worker process registers through real HTTP while idle; query returns fresh configured output, then stale/zero lease after graceful worker shutdown. API and worker handles joined.
- No full native media rerun: publishing/encoding data flow is unchanged; this slice changes startup metadata and command admission. Prior complete vertical and API/worker-restart media evidence remain scoped to their original commits.

## Next

Diagnose remaining720p collapse loss from saved `ordinary-native-PvbKtK` before another native run. Sustained backend throughput/profiles, hard worker crash/source interruption, full-match duration and hardware/radio-route acceptance remain open. No runtime benchmark is claimed by the startup probe.
