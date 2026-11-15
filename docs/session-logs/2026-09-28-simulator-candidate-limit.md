# Simulator candidate limit — September 28

Previous goal turn made progress: bounded UHD sender pacing committed as4c43b7a.
This session isolates the remaining4K candidate failure rather than rerunning the
full UI/export workflow. Production encoder settings and queue caps are unchanged.

## Direct SDK simulator diagnosis

Evidence: `artifacts/qa/uhd-candidate-simulator-20260928/`.
SDK schemeHaishinKit-Package builds for iOS26.2 arm64 simulator. The selected test
is `HaishinKitPatchTests/VideoCandidateEncoderTests/uhdNativeLatencyDiagnostic(lowLatency:)`.
The initial selector without `(lowLatency:)` ran zero tests and is not evidence.
Each owned simulator is shut down/deleted; retained result files have cleanup[0,0].

`selected/test.log`: normal4K24Mbps initially hits rawQueueFailure; low-latency
mode cannot create the native session (-12908). The fixture began pacing before
first-frame decode, which could introduce an artificial catch-up burst.

`properties/test.log`: corrected fixture decodes the first frame before starting
30fps pacing. Normal encoding accepts27 inputs/outputs26 after joining, then fails
`unresolvedInputLimit`, matching the full simulator. First completion delay473ms,
maximum919ms. EncoderID reads `anon-1`, RealTime=true; MaxFrameDelayCount and
UsingHardwareAcceleratedVideoEncoder return -12900/absent. Unsupported readback
is not evidence of software selection. Low-latency native creation still fails.
Diagnostic execution takes2.697seconds. A green diagnostic means the observations
were collected, not that either4K recipe was qualified.

The previous macOS normal-mode diagnostic completed90/90frames at83ms maximum
completion delay. Its low-latency comparison still included the pre-decode pacing
issue, so that earlier queue failure alone cannot establish a mode performance limit. The iOS simulator result alone cannot establish phone capability.
Do not enlarge admission queues or change production recipes to hide this failure.

## Follow-up

`headless-native-ZiHDud` runs the real macOS FilmModel archive, production publisher
and adaptive policy with the local SRT/proxy/mock outputs for180seconds. It finishes
with recording/publishing true,357 quality samples, and a closed non-overflowing
valid cadence audit. Cleanup[].360/720 confirm; no encoder-input failures, but4K
is not attempted in this time. Initial measured candidate costs exceed planned
padding headroom (e.g.931kbps cost/1.052Mbps padding); a later attempt uses the
measured cost and succeeds. This is a capacity rejection, not a cadence failure.
The existing2048row audit bound is preserved. This is diagnostic evidence, not UI
or full saved-media acceptance.4K remains an open requirement.

## Longer diagnostic support

The headless runner now accepts `--timing-audit off` (default on). Only the optional
closed timing audit is omitted; production polling, report validation, admission,
archive, source and receiver rules remain. Result explicitly records this choice.
This avoids pretending a truncated2048-row audit qualifies a longer run. Quality
state changes also print during the run. Node syntax check passes; native execution
is being verified by the360second diagnostic. No broad suites or hardware tests.

## Completed360second native run

`headless-native-3aD0U5`, lab `device-lab-UV6LXk`, exec76004 joined0/cleanup[].
Recording and publishing remain true at362seconds; timingAuditEnabled=false.
This verifies the new opt-out executes, not full media qualification.
A saved implementation patch/hash binds the producing source state.

Approximate sample times:360p trial71s,720p trial150.5s,1080p trial225s, minimum
reset239s,360p retry339s.360/720 confirm.4K is never attempted. The reset witness
says `input=sourceScopeChanged`, `reasons=telemetryInvalidated`, revision3→4.
At reset the delivery window has30on-time frames, zero late/missing/uncertain;
report age134ms. Actual receiver geometry runs240/360/720/1080/240/360 have
2085/2400/2250/438/3009/573frames, all maximumPTSDelta3000 and no invalid reason.
This does not establish an encoder throughput failure or excuse skipping scope
validation. It identifies a distinct telemetry-identity transition to investigate.

The preceding accepted source sequence46/scope digest is in diagnostic samples469–477;
reset is sample478. Applied transition uptime2225263.9235, sequence47, interval
2225257.9368…2225262.9386. `PublishingQualitySession.SourceScope` compares capture
scope, native clock, worker identity/epoch/attempt, publication, and optional
processing scope. The exact differing field was not retained by the compact
witness; do not guess or weaken identity checks. The optional processing scope
can be absent, but its involvement in this reset is currently unproven.

Next: inspect scope construction and add a compact changed-field witness if needed;
use targeted model tests/replay before another long media run. The simulator encoder
limit and this native telemetry reset are separate. All jobs are joined; no labs
or owned simulators remain live. No full saved-media verdict is claimed.
