# Faster native media iteration

Starting point: `a27d2f7`, `codex/local-validation` in the local-validation worktree.

The user requested faster iteration with fewer repeated checks and hardware deferred
until the simulator feature set is green. Retain existing acceptance evidence and
run one focused check for a changed boundary; reserve full simulator/media runs for
integration checkpoints. No agents or hardware were used.

## Diagnostic path

Added `scripts/test-headless-streaming.mjs` and the opt-in
`FilmModelTests.testHeadlessLocalStreamingDiagnostic`. The runner incrementally
builds the existing Mac model target, creates the existing isolated local lab, and
runs the real FilmModel archive, CaptureStreamingModel, SRT publisher, adaptation,
GPU proxy and mock RTMP recorder. It uses the same independent control, worker and
health schedules as ContentView. Original media is read directly without copying.

It skips simulator boot/install, UI navigation and archive export. Native archive
segments, quality samples, cadence timing audit, proxy/mock recordings and xcresult
are retained. Stop joins the native work and lab cleanup is recorded. Configuration
and credentials stay in a private artifact directory. Without explicit configuration
the test skips, so ordinary unit tests do not start a media lab.

This is a diagnostic harness, not phone/Watch UI or independent media acceptance.
It does not qualify frame continuity, A/V sync, overlay correctness or 4K upload.

```sh
DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer \
node scripts/test-headless-streaming.mjs --host 192.168.1.130 \
  --source /absolute/prepared/input.mov --duration 120 --quality 2160
```

Duration is bounded to 10–600 seconds. `--quality 1080` diagnoses the existing HD
pipeline. The default is 2160 with VideoToolbox. Run no full UI/export workflow
until the focused diagnosis justifies one.

## Evidence

First diagnostic run `artifacts/qa/headless-native-hmNggn`, lab `device-lab-7QsmNu`:
120-second observation, 121-second native test including joined stop; exit 0 and
cleanup failures `[]`. Archive and publisher remain active at the end. It reaches
360p with a completed 720p candidate but not a 720p application within this duration.
The cadence audit has 1,203 rows, closed, no overflow/invalidity; maximum report age
at acquisition is 114.73ms. This does not reproduce the simulator freshness failure.
No independently decoded-media pass is claimed.

The existing `strongHealthDurationSeconds` scalar measures only the latest source
window. Added `recoveryCoverageSeconds` to expose cumulative recovery separately.
Also retain one compact, timestamped cadence rejection timing breakdown outside
trials; later fresh samples must not be used to infer the rejected sample's age.
These are DEBUG diagnostics only; adaptation thresholds and ownership are unchanged.

Extended run `headless-native-qfiBCM` observes 180 seconds (181-second native test),
exit 0, cleanup `[]`; both native paths remain active. It reaches 720p, then resets
240p during probation. The applied transition identifies `cadenceRejected/freshness`.
The matching audit row at uptime2221405.251 has289.66ms total age:119ms server age,
168.02ms HTTP request,2.63ms local residence; the native probe read is0.034ms.
A second row reaches457.64ms because HTTP takes381.94ms. Of1,798 closed, valid audit
rows, two exceed250ms. Cumulative recovery reaches34.999seconds, so the earlier
five-second scalar was not evidence of a coverage bug. This reproduces the actual
reset without simulator UI and rules out a native probe stall for this occurrence.

Final incremental build and the existing cadence-rejection ownership/audit test
pass (two fixture cases,0.017seconds). The new opt-in test correctly skips without
configuration. Script syntax, formatting and `git diff --check` pass. All jobs
joined; no hardware/simulator lifecycle changes in this session.

Next: address the production report-timing policy using this exact HTTP-delay
regression. Do not simply discard delayed reports as fresh, weaken ownership, or
relabel historical profile contracts. Keep the250ms strict benchmark unchanged;
if production report-age budgets change, version them coherently across Core,
telemetry, delivery and exported diagnostics. Verify the focused regression before
one integration checkpoint. The raw video/decoded delivery budgets and media
acceptance thresholds remain separate.

The previous saved GPU simulator run `ordinary-native-Xg2t0t` shows repeated cadence
freshness rejection cancelling upward measurements. Its compact diagnostics do not
retain enough timing decomposition to identify the delayed stage. Keep current
freshness/admission limits unchanged until the new audit identifies that stage.
