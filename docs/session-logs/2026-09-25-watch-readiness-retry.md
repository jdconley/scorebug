# Watch readiness retry and ordinary recovery investigation

Starting checkpoint: `08bbfef`, `codex/local-validation`, authoritative worktree
`/Users/jd/.codex/worktrees/scorebug-local-validation`.

## Physical device retry

The user confirmed that the automation prompt was approved and both devices
were ready. A fresh `devicectl list devices --timeout 20` listed the iPhone 16 Pro
and Ultra 2 as available/paired. This justified one new bounded Watch preparation
attempt; no repeat approval was requested.

The existing bounded wrapper ran the signed Watch `build-for-testing` with the
same destination, Xcode26.2, Conley Chaos team and180second destination deadline.
It joined with exit70 after181.326seconds, before compilation or test execution.
Xcode reports destination preparation failure and suggests unlocking/proximity.
This does not establish that the user failed to unlock the Watch, or that the
approved automation prompt was rejected.

Artifacts under `artifacts/qa/physical-paired-current-mtc1mc54/`:

- `watch-ready-retry-build.log` and `watch-ready-retry-build-result.json` retain
  the exact command, elapsed time and joined result.
- `watch-ready-retry-build-error.xcresult` preserves Xcode's temporary error bundle.
- `watch-after-approval-readiness.{json,log}` and its result record preserve the
  bounded follow-up read: booted, Developer Mode enabled and paired, but developer
  tunnel disconnected and DDI services unavailable. No app/process capability.

Trying to inspect Xcode through the supported computer-use tool found the Mac
locked; no Xcode UI state could be read. Asked the user to unlock the Mac for
that diagnostic step, with an option to continue independent work. This is
separate from the already approved phone/Watch automation prompt. No app was
installed, test launched, recording started, device unpaired or existing data
removed in this retry. Both command processes have joined.

## Independent recovery investigation

Read-only investigation identified prerequisites for testing real congestion
through the ordinary production app. The complete proposal is retained at
`artifacts/qa/ordinary-congestion-design-proposal-20260925.md`.

The current single-peer UDP impairment proxy can be reused, but the ordinary
lab needs separate publisher and worker-reader addresses. Its current shared
ingest address cannot safely route both through that proxy. The existing
laboratory environment selector is not an ordinary production route.

The queue already supports rate changes, but the proxy exposes fixed scheduled
phases only. An explicit bounded event-driven test mode should apply a finite
forward cap after an actual confirmed increase and restore capacity after an
actual minimum acknowledgment. Preserve the old scheduled qualifiers. Do not
silently inherit their bidirectional delay/packet loss into a bandwidth-only test.

The current quality acknowledgment applies a trial; it does not prove confirmation.
A confirmed-profile congestion test needs bounded current trial-state evidence.
A750kbps cap is a plausible initial stimulus against recent measured360p costs
of~0.91–0.92Mbps, but the run must prove actual demand and token/queue pressure.
The390second finite source is too short for worst-case two150second increase
waits plus confirmation, fallback, holds and archive continuation. Prepare a
separate longer finite source; never loop or relax the increase deadlines.

No runtime changes or new passing tests result from this investigation. Existing
21ms live-audio-gap and incomplete historical audit evidence remain unresolved.
Next: inspect Xcode after Mac unlock; otherwise specify and implement the
ordinary publisher-only impairment route and event-bound qualification.
