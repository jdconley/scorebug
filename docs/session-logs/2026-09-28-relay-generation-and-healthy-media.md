# September 28: relay generation and healthy media acceptance

Starting revision `fda6940`, authoritative local-validation worktree. Previous turn
made progress on bounded scheduling and stop; no live job remained. This batch
closes remaining local identity/late-reader coverage and analyzes saved media,
without native capture, hardware, agents, or a broad suite.

## Real relay integration

Extended `scripts/test-relay.mjs` inside its existing real API/SQLite/managed SRT
relay fixture. Stop/start advances broadcast1→2→3; prior worker status becomes
unknown; old generation reports and publish requests reject409`broadcast_changed`.
Old publisher and reader credentials reject, accepted old publishing drains to
termination, and generation3 gets distinct credentials. Replacing the worker session
changes its public epoch and permanently rejects prior reports; rejected reports
cannot restore stale status. A late reader attaches after source bytes advance and
actually decodes both A/V tracks. Match end revokes generation3 while preserving
independent recording metadata. These control reports are harness-authored, not
proof of an actual worker race; existing worker-client double-snapshot checks cover
that separate client boundary.

First attempt completed the new checks but used the old hardcoded scoring revision
when ending the match. Media generation changes had advanced it. End now reads the
current revision/epoch. Second attempt met transient503while polling after deliberate
relay restart. That bounded wait now retries only503; other errors still fail.
No application policy changed. Third attempt passes all integration and cleanup.
Logs:`artifacts/qa/relay-generation-{first,restart-503,green}-20260928.log`.
Process53612 joined0; first two processes42998/99635 joined1. No owned relay container
remains. Formatting and diff checks pass; no unrelated tests rerun.

## Retained media phase analysis

`artifacts/qa/analyze-retained-congestion-phases-20260928.py` produces the hash-bound
`retained-congestion-phase-analysis-20260928.json` from existing barcode arrays,
ffprobe frames, native source/capture anchors and controller request/response brackets.
No decoding or new capture is needed. It conservatively uses the full observed
capture-clock envelope(<2.3ms spread), excludes uncertain boundary frames, and
attributes source identities to before-constraint/constraint/after-restore periods.
This report does not replace any strict media, packet, waveform or overlay result.

Baseline`ordinary-native-IZI72F`: all87missing IDs are certainly inside the imposed
restriction. Before restriction:151.667seconds,4401complete rolling5second windows;
after restoration:190.767seconds,5574windows. Both healthy periods have30minimum
freshfps,100%windows≥24fps, zero missing/non-increasing IDs and zero audio timestamp
gaps. Direct and overlay agree; clean archive remains continuous.

Buffered candidate`ordinary-native-kStE7J`: all149missing IDs are also inside the
restriction. Healthy direct periods have4323/7198windows, both minimum30freshfps,
zero frame-identity errors and zero audio timestamp gaps. It still worsens the
whole-stream video gap(4.033s versus2.4s) and remains rejected for production.

Thus the documented healthy-period video criterion passes on these short runs;
strict whole-stream media still fails and outage loss remains an explicit issue.
Do not relabel those failures or claim sustained/hardware qualification.

## Next priority

The production ladder currently ends at720p. Deliver and qualify1080p upload with
one affected simulator workflow using the existing real-match source, then pursue
4K/device/backend limits. Do not start another parameter-only congestion capture.
Reuse current normal vertical, Watch, archive, recovery, relay and healthy-media
acceptance. Physical hardware stays deferred until simulator feature gates resolve.
