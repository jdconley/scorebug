# Evening physical-device resume — September 26

User explicitly requested continuing. Started from clean `095ed51`. This begins a fresh resumed blocker audit; do not reuse the prior blocked-turn count. Goal is still incomplete. The initial probe used unchanged application code; bridge implementation follows below.

The Mac's current en0 address is10.0.0.122. The previous192.168.1.130 bind is no longer assigned; the launcher's validation correctly refused it before allocating a lab. Current physical iPhone lockState succeeds and reports unlocked.

Ran `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane network-probe`.

- Signed phone build passes. Artifact `physical-recovery-AeMjLt`, lab `device-lab-3mCm0Y`, source095ed51.
- The exact physical network-probe XCTest actually executes (8.242s); UI automation is working on this phone. Both HTTP requests fail before an HTTP response with NSURLError-1009, CFStream domain1/code50. Bounded NWConnection explicitly reports `unsatisfiedReason:localNetworkDenied`, then cancellation joins.
- Attachment `5AC3308C-A54F-40B3-BCD9-6AAB194F8EC6.json` holds the diagnosis. No inference about the Settings switch itself is possible; user was asked whether it is now enabled, already enabled, or absent.
- Root process53615 joins exit1. No camera or fault phases ran. Lab shutdown reports worker exit0, receiver closed with zero sessions and no cleanup failures. All17 recorded execution inputs were independently rehashed unchanged after joining.
- Fresh Watch lockState query45300 joins exit1 with Network.NWError54, connection reset by peer. No lock-state result was obtained; do not call the Watch locked or restart the paired test on this evidence.

Next: after a reported permission change, rerun this short probe using the currently assigned LAN address. Only after both HTTP checks pass should the physical720 recovery lane start. A missing/already-enabled runner entry needs targeted diagnosis; do not repeat the failed Settings automation unchanged. Paired Watch acceptance still needs a stable developer connection and successful automation initialization. Existing artifact-only paired launchers hardcode the previous LAN address and need current configuration before reuse.

## Enabled switch and supported alternative

User confirms ScorebugAppUITests-Runner already has Local Network enabled. A fresh installed-app query matches `live.scorebug.app.uitests.xctrunner` exactly (`installed-runner.json` in the probe artifacts). Do not keep treating this as a missing user permission.

Apple DTS [thread817792](https://developer.apple.com/forums/thread/817792) describes similar failures beginning with iOS26.3 and recommends a loopback listener in the app under test, using the app's granted network access. This is a supported architecture to test, not proof of an identical OS cause. Research and bounded DEBUG-only implementation plan were committed as82482fd. Implementation is in progress with focused tests and independent review before any hardware attempt. The original recovery mutation clocks, receipts and acceptance gates remain authoritative.

## Bridge implementation and local verification

Implemented fixed-route Debug-only app loopback control with strict canonical configuration/authenticated bounded HTTP, finite upstream requests, joined stop receipt and listener-refusal verification. Launcher opts in with `--runner-transport app-loopback --bridge-port 49173`; direct mode remains the default. The phone test proves no existing recording/publication before relaunching with bridge-only environment. Generated bridge errors are distinguished from actual upstream responses. Existing mutation timing/freshness/sequence checks remain unchanged.

Focused run passes51 Node tests, including the Swift harness's14 XCTest cases. Tests cover malformed configuration/framing/auth/routes, body/response limits, actual forwarding, timeout, expiry, port collision and active-request cancellation. Logs and joined process records are under `artifacts/qa/physical-loopback-validation-20260926/`. Syntax and whitespace checks pass.

Initial signed Debug build41113 and actual arm64 iPhone Release build89190 both joined0. `release-exclusion.json` records matching positive Debug / negative Release checks for bridge symbols, activation key and fixed route, plus actual binary hashes. The existing UI network diagnostic has an exhaustive-switch warning for the SDK's newer vpnInactive case; app-intents metadata warnings also remain. No bridge compile error occurred.

Independent specification review found one missing post-relaunch idle condition; corrected by repeating enabled start and both absent stop buttons. Final UI blobd09d84f098f5a712959f6c9f7a72414f4ebbbc4f is spec-approved. Final signed Debug rebuild and independent quality review follow before hardware.

Final signed Debug rebuild26131 joined0. Independent quality review approves all11 implementation/test/project blobs with no actionable blocker. Root verifies success markers and stores final source hashes plus log/binary checks in `root-verification.json` and `final-review-inputs.json`. Hardware probe is next; no capture acceptance is implied by these checks.

## Physical loopback probe passes

Sourceb639c81; command `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-physical-recovery.mjs --device 00008140-001474110C13001C --host 10.0.0.122 --lane network-probe --runner-transport app-loopback --bridge-port 49173`. Root87776 joined0. Artifact `physical-recovery-ymge6q`, lab `device-lab-urQgMy`. Exact probe leaf passes13.428s, zero skips.

Both APIroot and controllerroot return actual forwarded404 responses; the controller matches its expected unknown-operation body. Bridge shutdown is acknowledged and subsequent connection refusal verifies the listener closed. AttachmentB1D1DC36-6BC2-4EFF-9DDA-0B4E9536EFC3.json and separate shutdown attachment preserve the evidence. Root independently rehashes all25 listed runtime/config/source inputs unchanged. Controller audit is closed with zero records; receiver has zero sessions; worker exits0 and shutdown has no failures. This establishes app-mediated test connectivity, not restored direct runner privilege or media qualification.

Next is the physical720 ramp/collapse/recovery comparison. The user has been asked to provide a lit moving scene; no response yet. A new controlled hardware timing run can still diagnose application/transport behavior, but cannot establish fresh-motion or perceptual sync if the scene remains dark/static. No media gate will be relaxed.

## First app-loopback physical recovery attempt

Sourceb08f2fa, physical-recovery-MJj7dD / device-lab-CsDYIz, command3525 joined1. Full native test records/streams, acknowledges HOME1, stops publishing, continues the archive, stops recording and exports actual recording1B76FACB-D93E-4A07-89C7-13E54D924037. Recovery fails at the unchanged10s initial-minimum gate, before any constraint/restoration. Controller audit has zero mutations. Bridge shutdown is acknowledged with listener refusal; lab worker/receiver close cleanly and all25 execution inputs rehash unchanged.

Read-only causal review finds an observation-order race: initial240p ACK at recording+4.312s, initial hardware-publishing evidence around+12.3s, but gated reads start only+28.919s after scoring/navigation. The first sample has accepted-source age5.166s and correctly fails the5s bound; native360p applies at+30.655s. This is not a failed bandwidth-collapse comparison. Native360 trial application is51.274ms in this run, not a measurement of720 collapse.

Hypothesis/fix to verify: for physicalRecovery only, start the existing contiguous adaptiveGate immediately after worker producing_output, before screenshots/scoring; suppress the later duplicate call. Preserve every predicate/deadline/receipt and normal/simulator lane order. The earlier qualified source window was not sampled, so physical re-execution is required; do not declare the hypothesis proven by code inspection.

Collected only the actual new export UUID using devicectl. Allthree outputs pass precise full audio/video decode with no stderr. Clean archive1876frames/62.50s lastPTS, proxy/sink1588frames each; all have increasing video timestamps, no gaps over50ms, and no audio packet gaps over5ms. Preview confirms clean archive and HOME1–0 overlay in the live sample. Scene is dark: no fresh-motion/perceptual-sync or recovery qualification. `media-validation.json` and hashed outputs retain that distinction; media verification9827 joined0.

Observation-order correction changes only two test callsites plus a comment. Final UI blobdece429dfcde36839ce8e6fc1f7c232e0b1ac0ee passes independent spec and quality review,70 focused evidence/control regressions, syntax, and signed Debug build25993 joined0. Existing failed hardware run is the regression; only the next physical run can verify the new observation timing. Evidence hashes: `order-fix-validation/root-verification.json`.

## Early-observation retry and explicit startup acquisition

Source8696389; physical-recovery-bUx6EQ / device-lab-WXSbzs; root52566 joined1. The order fix does observe startup at+11.786s. Five samples through+19.949s are240p/revision0 with no owned source interval; last is rejected for cadence-freshness. The initial10second gate ends+21.786s. Subsequent evidence has an acquired source, but is already stale and cannot retroactively pass the gate. Source tracking requires two consecutive completed5second decoder windows; producing_output does not promise this acquisition. The ten-second cold-start acquisition assumption lacks a derived budget.

No impairment commands ran. Archive recording4A58B227-F36A-4763-BFAF-1E436479DFE6 exports; all25 inputs unchanged, bridge stop/refusal passes, lab/receiver join cleanly. Collected only that UUID and actual per-attempt QA audits for both phone runs. Allthree new outputs decode with no errors; archive2016frames/67.168s lastPTS and live1713frames each, no video gaps over50ms or audio packet gaps over5ms. Media analysis47155 joined0. Dark/static content still prevents fresh-motion/perceptual-sync qualification.

User now confirms the phone is pointed at a lit scene with movement. The next run can use that improved scene.

A separate later event is retained: bUx6EQ's360trial ACK around+30.985s resets to240/revision2 at+42.454s for cadenceRejected/freshness. This disproves a claim that it merely stayed at startup or could not measure a candidate. Production thresholds remain unchanged pending exact admission-timing diagnosis.

[Explicit physical startup acquisition plan](../superpowers/plans/2026-09-26-physical-startup-acquisition.md): version physical evidence separately, prove initial encoder ACK within10s of local publishing, then permit bounded30s source acquisition after worker output using identical freshness/owner requirements and exact initial revision/ACK. All later recovery gates and540s recording budget remain unchanged. Implementation/tests are in progress; no further hardware job is active.

Fresh Watch read-only readiness query71548 joins0: passcodeRequired:false and unlockedSinceBoot:true. Evidence `artifacts/qa/watch-after-phone-loopback-20260926.json`. This supports a new bounded paired attempt after the phone work/builds join; it is not UI automation or paired scoring acceptance. Artifact-only paired wrappers still need the current10.0.0.122 host and fresh build provenance before reuse.

## Startup contract reviewed; precise rejection witness next

The six-file physical startup slice is frozen and approved by independent specification and quality reviewers. Root repeated the focused suite: process53629 joined0, 182/182 tests, zero skipped; `artifacts/qa/physical-startup-acquisition-validation-20260926/root-focused-tests.log`. Physical evidence is format3/physical-recovery720-v1 with separate anchored10s encoder ACK and30s owned-source acquisition; ordinary evidence remains unchanged. No physical pass is implied.

The exact cadence-rejection witness is now being implemented from the [diagnostic plan](../superpowers/plans/2026-09-26-cadence-rejection-witness.md). It preserves the original receipt and evaluation-time age components in the existing successful-ACK transition audit, without changing production freshness thresholds. Root has prepared separate v3 replay and current-host paired wrappers under artifacts; the previous wrappers/evidence remain intact. Signed builds and physical capture will follow reviewed frozen source.

Read-only review also confirms startup ownership can be observed during ordinary candidate measurement: bUx6EQ recorded source-owned revision0 at855986.437 and360ACK at855993.066, about6.63s later. Measurement does not itself mark the session/application busy. This is evidence of an observable window, not a guarantee that2s accessibility polling always catches it. The physical qualifier continues rejecting skipped initial ownership and later reset substitution. The new physical transition-audit verifier will retain complete-collapse requirements; partial failed runs remain diagnostic-only.

## Cadence witness reviewed

Implemented DEBUG-only immutable rejection-age decomposition and first-cause audit fields, captured at the original evaluation, snapshotted before native suspension and exported only after successful Core ACK. UI payload and production policy remain unchanged. Added strict explicit-field validation and a separate physical-v3 transition verifier retaining complete-collapse/sampled-ACK requirements. Root review caught evaluation-state sampling and context-error validation issues; the independent quality reviewer caught impossible-overflow acceptance. All were fixed with focused regressions before builds.

Final independent specification and quality reviews approve the six-file scope. Verified tests:78 distinct app tests,7 Core cadence tests,210 affected Node tests, zero failures/skips. Quality reviewer independently repeats63/63 verifier tests. Original red and compilation-failure attempts remain in `artifacts/qa/cadence-rejection-witness-validation-20260926/`; root checks final blobs/logs in root-verification.json. Fresh phone and Watch lockState queries both report passcodeRequired:false; Watch session31735 joined0. Signed phone/Watch and Release builds now run sequentially under root56610 before any capture.

Sequential build wrapper56610 joins0: signed Debug iPhone, Release arm64 iPhone, signed Debug Watch all pass. `artifacts/qa/physical-startup-witness-builds-20260926/` contains commands/logs/source and binary hashes. Root verifies positive Debug/negative Release symbols and strings for bridge and cadence diagnostic in release-exclusion.json. All review/test/build jobs are joined before the new lit-scene physical run.

## Lit-scene run blocked before test body

Committed reviewed startup/witness source asfe35041. Ran the physical recovery launcher with --host10.0.0.122 --lane recovery720 --runner-transport app-loopback --bridge-port49173. Artifactphysical-recovery-EUdSsp / labdevice-lab-oqKUm2; root56518 joined1. Signed build passed, but the actual phone runner timed out enabling UI automation before entering the test body. No capture or bridge/control mutations started. This matches the user-described first-session passcode prompt; user was asked to approve it if shown or report that no prompt is visible. Do not retry until new readiness evidence arrives.

Root rehashes all25 listed execution inputs unchanged. Controller audit closed with zero mutations; receiver closed with zero sessions; worker exited0; cleanupFailures is empty. root-assessment.json preserves these results. The latest readiness checks before the run had both devices unlocked, which does not prove automation initialization. No media was produced or collected.

## Approved phone retry: startup works, quality stays at minimum

User approved the new phone automation prompt. Retried unchanged reviewed code: physical-recovery-ydaKA3 / device-lab-C5lQku, source836926b, root33285 joined1. The test body now executes. Initial encoder ACK is observed at recording+5.883s and initial owned source at+22.351s, establishing the new startup observation path. The150s initial-360-increase gate fails; no impairment ran. All78 sampled revisions remain0/240p, and the exact closed/non-overflow transition audit has zero records. Worker geometry is one continuous426×240 run. Bridge shutdown ACK/refusal passes, all25 inputs remain unchanged, and lab cleanup is empty.

Read-only diagnosis: first measured candidate cost913143bps versus delivered padding1040292bps, below the unchanged1.25 headroom requirement1141429bps. It settles costReadyWithoutApplication. Existing retry sizing retains cost and can request at least1.5×cost (~1369715bps); this is not proof of a hard padding ceiling. A retry reaches cost-ready but its last admission rejection is receiver-time-bounds, which combines six comparisons; the recorded fields cannot identify the failed inequality or establish why cancellation followed. Do not attribute the first evaluation's older cost/padding values to that retry. Readiness requirements increase4→10→20s; later cadence/delivery rejections may interrupt readiness, but exact rejected ages are unavailable. No threshold relaxation is justified. Next adaptation diagnostic should retain the actual receiver bounds and accumulated readiness blocker/coverage.

Native recording/scoring/stop/export still completes. Collected only recording1B4B78DC-3620-41BC-99B7-142ACB1BF3B6 and QA attemptd3ac8934-625e-4f81-af1e-cb03dbe500a1. Full media verification78312 joins0: clean1080p30 archive6649frames/221.638s; proxy and mock sink6322frames each. Allthree precise full A/V decodes pass with no errors, no video gaps>50ms, no nonincreasing video timestamps and no audio gaps>5ms. Viewed samples show a lit changing scene, clean archive and live overlay0–0→1–0. These samples and encoded continuity do not certify the full fresh24fps or perceptual-sync contract. Full recovery replay correctly fails incomplete native/transport/geometry contracts. assessment.json preserves these limits.

## Paired Watch attempt after phone collection

The physical launcher rebuilt/signed phone products, so the earlier generic phone-binary hash no longer matched. Root bound the paired run to the newer phone capture inputs (all still matching), verified unchanged Watch/source/Release hashes from the generic build, and saved combined provenance at artifacts/qa/paired-lit-provenance-20260926/result.json. The original manifests remain intact. Current-host paired wrapper uses that new manifest. Fresh Watch lockState27931 joins0, unlocked.

Paired run physical-paired-live-qBRzUf / device-lab-qkOT5A, root1127 joined1: Watch runner times out enabling UI automation before its test body. The orchestration barrier prevents phone capture from starting. All14 execution inputs remain unchanged; worker exits0, receiver closes with zero sessions, cleanup empty. User was asked whether a new phone/Watch prompt is visible and to approve it if shown. No retry before that new readiness evidence. All jobs are joined.

Read-only next-diagnostic design: use the synchronous observer in PublishingCandidateAdmission to retain exact receiver-time comparison operands/failure enum, then forward after CaptureStreamingModel's final await under existing attempt/session/tap guards. Core readiness already exposes recoveryStart and last strong-window end; accumulated coverage is their difference, not the latest window duration. Capture the actual first guard/blocker at the scheduling read, including session-level ownership/active-measurement checks. Prefer a separate bounded per-attempt DEBUG candidate summary (first/latest admission rejection, count, registered identity, settlement and current readiness), not the4096-event laboratory audit or successful-ACK records. Preserve16measurement/8192byte bounds, flag overflow, freeze before shutdown suspension and export after joins; keep UI and Release policy unchanged. No implementation started. Focused tests must cover each predicate/boundary, immutable operands, stale identities, never-applied settlement, accumulated20s versus latest5s window, bounds and closure. This is queued work while the paired Watch prompt answer is pending.

Additional audio-packet order checks pass for allthree lit-run files: strictly increasing audio PTS and no overlaps>5ms, retained in audio-packet-order.json. No active capture/build/media/test jobs remain. The latest user question concerns a new Watch automation prompt; no new reply has arrived yet.
