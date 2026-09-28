# UHD application integration

Starting `e471277`, authoritative local-validation checkout. This batch carries the
UHD budget through immutable publisher configuration, owned requests/readbacks,
renewal/replacement/retirement, native observation and candidate planning. Budget
mismatch cannot grant authority even at a bitrate valid under both ceilings.

CurrentCapture now carries the selected archive/source profile.4K source + fresh
worker2160output selects the explicit UHD publisher and240→360→720→1080→2160 ladder;
other combinations use the existing ladder. Candidate planning uses the bounded
48Mbps probe/32Mbps measured-cost maximum. Admission requires matchingv4 receiver
evidence. Source-sized raw queue limits retain the same number of frames:4K scales
archive24→96MiB and live12→48MiB. Encoding/internal/in-flight allocations remain
separate from these queued-payload bounds.

## Focused checks completed

- Thirteen focused FilmModel/candidate-plan tests pass, including profile propagation,
  fresh output/source gate and bounded4K scheduling; existing1080 bound remains.
- Seven owned-probe operation tests pass, including UHD readback/renewal/retirement
  and substituted-budget rejection. Initial build missed an explicit `self` in an
  escaping closure; fixed before tests. No broad suite or hardware test.
- Thirty ordinary/device-lab runner checks pass. A separate quality2160 lane uses
  real4K source/output, no impairment controller, and the same ordinary app policy.
- A separately tagged `scorebug/ingest:uhd-probe-v4` image built successfully. Existing
  `drain-v1` image/default lane is preserved. Media template/geometry helpers now
  explicitly support2160p; old diagnostic fixture-selection restrictions remain.

## First native integration result

`artifacts/qa/ordinary-native-fo3p3M` from
`DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/uhd-app-20260928/input.mov --lane quality2160`.
Runner log: `artifacts/qa/uhd-app-20260928/native-run.log`. Exec61076 joined1;
cleanup failures are empty and the owned simulator was removed. App/UI build
passed, but the initial360 increase timed out with no measurements/transitions.
Saved diagnostics show healthy30fps baseline delivery and policy readiness.
The subsequent export gate expired after35s while the UI still displayed
“Preparing and checking video”; it did not display an export error. Segmented
recording is finalized and preserved. No native/media pass is claimed.

Follow-up `ordinary-native-LZBGYJ` (exec38751) adds scalar measurement-context
diagnostics and a180s bounded4K export wait. No hardware or broad suite.

Source is a600second stream-copy of the existing verified1800second4K SDR match
fixture `match-footage-n6n1f13m/endurance/4k-source.mov`:18000frames,48kHz monoPCM.
Original Downloads files untouched. Helpers prepared for the final artifacts:
`collect-ordinary-export-20260925.py`, `verify-2160-climb-20260928.py`, and
`verify-uhd-media-20260928.py` (dedicated2160 geometry/glyph checks). Use preserved
source/output hashes; no old evidence is rewritten.

## Integration diagnosis and fix

Live XCTest diagnostic output in LZBGYJ confirms the measurement context is ready
and the owned publisher is installed. Source review found `lowerRequest` in
PublishingBandwidthProbeOperation discarded the immutable budget when binding
the lower handle. The SDK correctly returned UHD, but the wrapper expected standard,
rejected binding, and retained the untrusted owner without granting another allocation.
Pass the request budget through this handoff. One two-layer regression exercises both
500kbps (valid under either cap) and36.192Mbps, renewal and exact joined retirement.
Eight focused owned-operation tests pass (exec87529 joined0,0.424s execution).
No broad regression or hardware run was repeated.

Plan reconciliation: production broadcast3000/default SRT is already selected and
has native1080 evidence. Marked that decision complete; severe-outage and sustained
qualification remain open. NEXT is trimmed to the active checkpoint, reusable
results, next actions and environment instead of carrying past session narratives.

Follow-up LZBGYJ joined1 with cleanup failures[]; the native MP4 export completed
at roughly65s (730MB) and the test failed only the already-known initial360gate.
The previous export failure was an undersized test timeout, not lost recording.
The fixed full lane now starts from the same600s input, with no hardware activity.

Fixed run GZQ9WQ (exec27502) joined1/cleanup[]. The original budget-binding bug
is resolved: measurements now allocate, renew, retire and retry. One source-wait
timeout was followed by repeatable candidate `inputRejected` failures; no increase
was qualified. Native export again passes. A focused actualVideoToolbox test with
3840×2160NV12 input measuring360p passes12paced frames in0.486s (exec34916 joined0),
so basic4K raw admission/downscaling is available. Added bounded encoder/transport
failure scalars and fail-fast input diagnosis to the4K UI lane; it no longer waits
out the entire180s increase gate after a known input rejection. Diagnostic run
exec22817 is active; join it before another capture. This remains unqualified.

Input diagnostic bJyE6m joined1/cleanup[] and identified `unresolvedRawByteLimit`
in the native candidate encoder (~0.24s after binding). The64MiB bound held only
fiveUHD NV12 frames during startup. Source buffers at least3840×2160 now receive
192MiB, while ordinary-source64MiB,16MiB/input,16unresolved frames,4queued frames
and all deadlines remain unchanged. Three focused SDK tests/six cases pass in0.203s,
covering UHD startup, the seventeenth-frame rejection and unchanged ordinary-source
byte accounting (exec99671 joined0). Maintained SDK patch updated. Diagnostic
exec22817 joined1; fixed bounded run exec7050 is active. No broad suite/hardware.

SDK round-trip verification passes all original upstream hashes and exact reapplication
(exec90645 joined0, sdk-patch.txt). The first check omitted upstream manifest-only
files and failed before validation; corrected the checker input set, not the patch.
Active bounded run: ordinary-native-P3jnRi / exec7050. Full simulator build passes.

P3jnRi joined1/cleanup[]. Raw candidate completes and reaches measured admission;
first measured360cost947144bps exceeds the nominal probe headroom. Subsequent
source-wait timeouts/backoff keep240p through the finite gate. Native export passes.
The lab had been defaulting to software2160encoding. GPU qualification now uses
explicit `--encoder videotoolbox` (exec92183); quality2160 defaults to this backend
while other lanes/explicit software selections are unchanged. No freshness, loss,
latency or admission thresholds were relaxed. CPU-only4K remains unqualified.

## Checkpoint and faster next iteration

GPU run `ordinary-native-Xg2t0t`, labBOKJBq, exec92183 joined1; cleanup failures[].
Real4K archive/export and240→360 measured increase/ten-second probation pass.
Initial720increase exceeds its finite gate. Measured720cost3718715bps is retained,
but source-wait/cancellation and40s recovery backoff prevent further progress.
Artifacts preserve every failure; no4K upload/media acceptance is claimed.
All owned jobs are joined; no active simulator/lab remains. User hardware untouched.

Next use focused scheduling/freshness model checks driven by these saved diagnostics,
not another full UI capture or broad suite. If more live diagnosis is necessary,
add an opt-in headless Mac harness around the existing FileFixtureCameraSource,
FilmModel/CaptureStreamingModel and real local lab; bypass UI setup and per-iteration
MP4 export while preserving archive/normal stop. It is a diagnostic harness, not UI
acceptance. Resume the full4K lane only after the gating cause is covered. Preserve
production timing until evidence supports a coherent replacement; no parameter-only
recaptures. Existing1080/nativeWatch/phone vertical evidence remains reusable.

Final runner options30checks pass (exec33671 joined0). Export metadata confirms3840×2160 H264 plus audio; no full-media integrity claim. `diagnosis-summary.json` retains phase/failure scalars. Format/syntax/diff checks pass. All jobs joined.
