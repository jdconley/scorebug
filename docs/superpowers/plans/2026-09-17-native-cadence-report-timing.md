# Native decoder report timing implementation plan

Use the existing executing-plans and test-driven workflow inline in the local validation worktree.

Goal: measure the real worker/API/native-helper freshness path using the fixed minimum
simulator stream before enabling progressive quality changes. Preserve actual media
continuity and archive qualification in the existing native runner.

Add an explicit DEBUG simulator measurement flag, compatible only with the fixed
240p structured-motion/publication/processing/direct-recorder fixture and a 90–120
second hold. Run worker reports and native control polls at 100 ms. Do not instantiate
a quality controller in this measurement mode. Keep a closed, bounded 2048-row audit
of raw status responses, native request duration, residence duration, actual helper
result and expected publishing attempt. Export through the existing joined publisher
teardown. Missing helpers remain missing, and overflow invalidates qualification.

Independently reconcile native reported ages with server bounds plus request and
residence, verify publication/attempt identity, and report freshness distribution
and maximum gap between usable observations after five seconds of settling. Initial
local qualification targets: at least 30 seconds of observations, at least 95% within
250 ms, and no gap exceeding 500 ms between usable reports. These are test admission
criteria, not an industry standard or proof of remote-network latency. Preserve failed
runs. This step measures fresh reporting under normal media; controlled stalls and
actual native reset response timing remain the next required gate.

- [x] Add failing bounded audit/lifecycle and flag/verifier tests.
- [x] Implement native audit, explicit fixture plumbing and independent verifier.
- [x] Run Core/native/tool tests and simulator/device builds.
- [x] Run actual fixed240 native streaming with fast reports, inspect media and age results.
- [x] Update main plan, freeze source/evidence and commit verified results.

Files: new WorkerCadenceReportAudit.swift and native tests; CaptureStreamingModel.swift;
Project.yml and NativeStreamingTests.swift; native-streaming-options/fixture/test-native-app;
new native-cadence-reports verifier and tests. Production scheduling is unchanged.


## Verified result

Actual `native-app-ToYhHS` ran on the iPhone 14/iOS 17.5 simulator against the owned
local SRT relay, worker and direct RTMP recorder. Native helper execution exported
848 reports; 785 had an available helper. After the documented settling period,
all 747 observations across 98.481 seconds fit the 250 ms budget. Ages ranged from
118.583 to 247.844 ms, with a 219.069 ms 95th percentile. The longest gap between
usable observations was 164.092 ms. Every helper age reconciled independently with
the raw server bound, whole native request duration and native residence duration.

The first known helper arrived 7.403 seconds after the first audit row, while status
progressed through unknown/waiting_source/starting/producing_output. This is initial
telemetry availability, not user-to-viewer startup latency; it is excluded from the
settled freshness claim and must not be described as immediate delivery.

All 3,325 native compressed frames were consecutive (158...3482). Saved live media
contained 3,291 consecutive source frames (192...3482) following 34 acquisition
frames; the clean 1080p archive contained 3,667 consecutive frames (0...3666). Both
fully decoded. All 54 live and 61 archive audio markers matched, with maximum offset
65.250 ms live and 0.021 ms archive. Recorder, worker and worker encoder exited zero;
owned simulator and relay cleanup completed. An independent Python verifier checked
age arithmetic and raw frame barcodes, and rejected eleven damaged evidence variants.

Verification: 1,222 tooling, 348 Core and 248 native model tests pass, with ARM64
simulator and unsigned combined iPhone/Watch Release builds. Evidence is frozen in
`artifacts/qa/cadence-timing-final-verification.json`. The fixture uses fixed minimum
quality and does not start a quality controller. This run proves local reporting
freshness under normal media, not controlled-stall-to-reset latency, on-time source
frame delivery, automatic quality increases, physical phone/Watch performance or
remote-worker networking. Default production report scheduling remains unchanged.
Next introduce an owned, bounded live-path interruption while retaining archive
capture and qualify the native controller's actual stall/reset timing.
