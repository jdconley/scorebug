# UHD probe/backend isolation — September 28

Startingfe332cb, clean `codex/local-validation`. Previous turn narrowed the fault
to pre-upgrade work. No production streaming policy/queue/encoder changes here.
Added opt-in finite warmups to the existing fixed owned-publisher diagnostic and
software/VideoToolbox worker selection to the headless runner.

## Implemented and checked

`--warm-uhd-candidate on` requires owned/fixed transition mode. Routes actual
capture and AAC through PublishingCandidateCampaignOwner, waits for its real
completed result, clears routing and joins retirement before changing profile.
Native test requires at least97admitted frames. No synthetic candidate evidence.

`--warm-uhd-probe on` uses the actual owned probe API, current verified encoder
receipt,36.192Mbps and recovery-budget policy. Renews for40×100ms, then joins
retirement before the profile change; native test/runner require accepted bytes.
The warmup measures sender acceptance only, not receiver admission. Flags may be
combined concurrently, but that combination has not been run. Existing stop also
joins the campaign. Diagnostic errors still end through the headless cleanup path.

`--worker-encoder software|videotoolbox` selects the existing portable worker
backend; default remains VideoToolbox. No release-app behavior changes.
Incremental FilmModel builds/targeted native lifecycle tests and JS syntax/diff
checks pass. No broad suite, hardware, agents, push or full-media decode.

## Results

All use the same private250–300s content remux,35s capture and real archive/SRT/
proxy/both outputs. All preserve recording/publishing and select native hardware.
Each artifact includes source HEAD/patch plus hashed `isolation-analysis.json`.

| Artifact               | Warmup / proxy                       | SDK / app drops | UHD receiver frames | Max PTS delta |
| ---------------------- | ------------------------------------ | --------------- | ------------------- | ------------- |
| headless-native-fw3Zum | 121candidate frames / VideoToolbox   | 0 /0            | 786                 | 3000/90000    |
| headless-native-LC8Cpq | 17,534,384probe bytes / VideoToolbox | 17 /0           | 772                 | 6000/90000    |
| headless-native-zDpc9c | 17,460,688probe bytes / software     | 0 /0            | 790                 | 3000/90000    |

Candidate-only exec69955, probe/VT exec28797, probe/software exec60166 all joined0;
cleanup arrays empty. Candidate-only producing patch predates moving baseline
verification before warmup and adding concurrent probe support; provenance preserves
this difference. No combined candidate+probe comparison is claimed.

Probe/VT native final submission32.77ms and maximum56.05ms; probe/software final
0.255ms and maximum29.63ms. Software worker geometry confirms actual3840×2160
input. Receiver cadence and native boundaries are scoped evidence; neither decoded
archive/audio/overlay media nor normal adaptive success is yet established.

These comparisons locate an interaction between bandwidth probing and the local
VideoToolbox proxy workload. Candidate encoding alone does not reproduce it.
The internal shared-resource cause remains unproven; no speculative native codec
or transport change is justified yet. CPU proxy offers a plausible working local
UHD path while the separate hardware/backend limit stays explicit.

## Active verification

Normal production ladder, software proxy, source600sUHD fixture, duration330,
timing audit off; no fixed/direct/freeze/warm flags. Artifact
`headless-native-nZ4tzv`, exec **80423**. Log
`artifacts/qa/uhd-readiness-20260928/adaptive-software.log`.
Producing HEAD/patch recorded before capture. Join this exact handle; never restart
on an observation timeout. If UHD cadence passes, verify retained archive and both
actual output files. If it fails, inspect the new reason rather than repeating.
No other active jobs. Do not count this in-progress run as a pass.
