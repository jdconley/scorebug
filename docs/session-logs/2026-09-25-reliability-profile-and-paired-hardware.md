# Reliability timing and paired hardware

## Scope and starting state

Continue the complete native recording/scoring/streaming vertical after the platform research. Start: `eff8465`, `codex/local-validation`, `/Users/jd/.codex/worktrees/scorebug-local-validation`. The previous research turn made progress: published evidence changed the next action from reducing buffers solely to meet 1.5 seconds to comparing deliberate broadcast timing profiles. The full goal remains active.

The physical smoke has priority. In parallel, implement coherent diagnostic timing profiles with separate media and report freshness. No production adaptation qualification or old-evidence relabeling is implied.

## Physical preparation

- Fresh device inventory: iPhone 16 Pro (`iPhone17,1`), iOS 26.7, connected; Ultra 2 (`Watch7,5`), watchOS 26.6, initially available/paired. LAN `192.168.1.130`.
- Announced the possible first-session phone passcode prompt; passcode stays on the device. Asked that the camera face a lit scene and Watch remain unlocked nearby.
- `physical-research-phone-build-20260925`: signed `build-for-testing`, exit 0. Fresh process inventory found no Scorebug process; explicit current app installation `physical-research-phone-install-20260925` exited 0.
- `physical-research-watch-build-20260925`: exit 70, destination preparation timed out while connecting. Retained this failure. A subsequent device-details query established a connected developer tunnel, enabled developer services, and a lock query reported no passcode required.
- `physical-research-watch-build-connected-20260925`: signed build-for-testing exited 0 after that connection-state change. No repeated launch of a still-running process.
- Builds use Xcode 26.2 and Conley Chaos LLC `B222J9J7B8`. Phone and Watch executable hashes, model/OS and source checkpoint are in `artifacts/qa/device-lab-IWDkV4/build-provenance.json`.
- Fresh lab `device-lab-IWDkV4`: VideoToolbox proxy, private-LAN scoring/SRT, loopback mock RTMP recorder, optional proxy final-overlay MP4, 1800-second upper duration. Credentials loaded from its private setup file into the phone test's environment; not placed in command arguments.
- The Watch runner starts first. Both tests use the already-built `eff8465` products; concurrent experimental timing edits do not qualify as hardware-tested code.

## Timing contract decision

The current delivery scheduler waits for capture-window end + decoder budget + 250 ms, while consumers separately expire capture windows at two seconds. Increasing only the decoder budget would make the evidence expire before it can be consumed.

Proposed experimental profiles retain a 500 ms consumption allowance: decoder budgets 1500/2000/3000 ms, maximum capture-window evaluation ages 2000/2500/3500 ms. Keep completed-window report age at 2000 ms, delivery/cadence samples at 250 ms, and observed decoder stalls at 1000 ms. These are explicit test policies, not industry standards. Candidate/probe/authority/lease deadlines remain independent.

New profiles must be accepted only on the complete owned diagnostic route and bound to trusted host selection in all relevant audit envelopes. Old runs keep their original strict settings. The unfinished whole-history recovery qualifier must continue refusing a full pass.

## Results and next work

- Watch runner `41571` joined exit 65: the runner failed to initialize UI testing because enabling automation mode timed out. Test case never began. The phone runner was deliberately not started. The user's earlier passcode-prompt explanation is relevant; a new async question requests approval directly on the phone and an unlocked nearby Watch. No retry until the device state changes or the user reports readiness.
- The unused lab was stopped by SIGTERM to its exact observed process. Root handle `33924` joined exit 0; its shutdown evidence is retained. This attempt produces no new physical media qualification.
- The preliminary export listing used the wrong `Documents/Recordings/Exports` path and failed; retained logs document it. The correct `Library/Application Support/Scorebug/Recordings/Exports` listing succeeded. Export verification must select the newly created export, never an old recording.
- A source inspection confirms real-camera adaptation remains unimplemented: `PublishingQualityDriver.fixture` returns nil outside debug simulators. Added an explicit real-camera integration/verification checkbox to the delivery plan so the fixed-profile physical smoke cannot close progressive streaming.

## Timing implementation and verification

`aaa9afc` implements the complete diagnostic selector, native propagation, capture/report freshness separation, and trusted envelope checks. New profiles remain confined to the complete owned diagnostic route. Local-only pressure retains its two-second age limit; the new media budget does not extend it. The normal owned route still rejects pending its complete verifier, and diagnostics still exit 1.

- Full JS suite: 4,953 tests, zero failures. Full Core: 498 tests, zero failures. Exact commands, exits and retained red/green logs: `artifacts/qa/broadcast-timing-contracts-20260925/validation.json`.
- Root full FilmModel suite: 619 tests, zero failures, before the last added timing-focused assertions. Wrapper `broadcast-timing-film-models-20260925` joined exit 0.
- First focused run: 93 tests, one failure. The new three-second schedule test jumped from 10.1 to 15.249999 seconds without polling and correctly triggered the existing five-second suspension reset. The test now supplies an intermediate regular poll; runtime suspension behavior was preserved. Both failed and corrected logs remain.
- Corrected focused run: all 93 tests pass, wrapper `broadcast-timing-film-focused-fixed-20260925` joined exit 0.
- Final arm64 iOS simulator `build-for-testing` at `aaa9afc`: wrapper `broadcast-timing-ios-final-build-20260925` joined exit 0. This includes the final Core local-pressure refinement.
- Independent specification review passed, including 104 focused JS and six Core tests. Quality review found a source-advice expiry issue: the new capture allowance can outlive a completed report's independent two-second freshness. A `[0,4]` source window with receiver observation at 4.1 can recommend reset at 4.2 with expiry 7.5, permitting admission at 6.2 when that report is 2.1 seconds old. Session application does not independently recheck generic source advice. A scoped fix and delayed-admission regressions are in progress; review must pass before fresh two-/three-second comparisons run.

## Complete recovery verifier audit

No whole-history owned recovery qualifier exists yet. The read-only audit identifies a new orchestrator using existing raw media, owned probe/history, native transition, candidate, capacity clock and delivery leaves. Remaining work is complete native application/candidate joins, receiver conservation across all campaigns, witness replay and whole-policy retry/terminal-suffix replay.

The retained 514-event fixture has four `failed` events but only two `settledFailure` outcomes; the other two failures occur after successful `applicationTransferred` and settle as acknowledged. Root independently checked those event counts and order. Cleanup cancellation must not become another failed recovery episode. Actual downward applications also have no active candidate/probe binding, so legacy successful-candidate lifecycle assumptions cannot be applied unchanged.

Candidate encoder identity first appears in the joined result. Do not claim an independently observed native startup identity from it. Preserve all source/frame/receipt bindings and failed attempts; do not fabricate older-format summaries or discard unsuccessful history.

Next: finish both timing reviews, run fresh comparisons, and finish the complete owned recovery verifier before enabling the controller for real-camera capture. Physical retry needs a fresh lab and the pending automation prompt resolved. A successful UI workflow alone does not prove three-output media acceptance.

## Advice expiry review closed

- Quality review found that generic source reset/decrease advice could remain applicable after the original receiver report exceeded its independent two-second freshness limit. Corrected regression failed with 20 Session assertions and 24 Core assertions; the earlier invalid startup setup is retained separately.
- `c4c30cd` freezes advice validity at the earlier capture deadline or usable original report observation plus two seconds; missing/stale reports retain the historical source-end-plus-two bound. Strict, local-pressure and explicit candidate paths remain unchanged.
- Full Core 500/0, Session class 21/0 (root handle 59471 joined exit 0), focused JS 183/0. Exact commands/results: `artifacts/qa/broadcast-timing-contracts-20260925/advice-expiry-validation.json`.
- Spec rereview approved and independently passed eight Core profile tests; quality rereview approved, P2 resolved, no remaining actionable findings. Native envelope propagation and grace-boundary integration remain experimental checks.

## User-ready paired retry

- User explicitly confirmed the automation prompt was approved and both devices ready. Announced the new session and lit-camera requirement.
- Fresh `device-lab-3RCYtU` started with VideoToolbox proxy and both recording destinations. Watch runner starts first; phone waits for the actual Watch test case. Same installed `eff8465` products are retained and provenance copied with an explicit statement that they are not the experimental `c4c30cd` binary.

### User-ready retry result

- Watch runner 57085 joined exit 65: the same 61-second automation-enablement timeout occurred before any test case. Phone was not started. Lab 33719 joined exit 0 after SIGTERM to its recorded PID92372; worker exited0 without force, recorder had no sessions, cleanup failures empty.
- Fresh read-only Watch details showed connected tunnel and Developer Mode enabled. Subsequent lock-state query timed out establishing the network tunnel; a later details query reconnected. This does not establish the automation failure's root cause.
- Exported runner diagnostics retained under `device-lab-3RCYtU/watch-diagnostics`; they add no more specific explanation. Asked whether another prompt appeared on either device; answer pending.
- Comparison with successful `paired-resume` logs shows the phone's automation test started10:56:49 and Watch test started10:57:12. The recent Watch-first guard may matter: simultaneous/phone-active automation is a testable coordination hypothesis, not a confirmed fix. Avoid attributing this pre-test failure to Scorebug behavior.

### First 2-second native experiment

- Launched the reviewed source checkpoint `086ff94` using the prepared2000 launcher; root handle51098 joined intentional diagnostic exit1. Artifact `native-app-LvDNAy`.
- UI workflow passed1test/0failures in356seconds. Collection errors empty; one uninterrupted mock recorder session. All six timing envelopes agree on `broadcast-reliability2000-v1`; this metadata check explicitly grants no media or recovery qualification.
- Native audit shows240p→360p→240p→360p, three applications, two acknowledged measurements, and two settled failed measurements. Full decoded-media and leaf checks are still running; do not label this complete recovery yet.

- Full A/V decode/frame-ID analysis7728 joinedexit0: clean archive9313frames0–9312; both live outputs8860frames227–9086, with no identity reversal or missing frame in each span. Archive tail226frames. Diagnostic results preserve hashes and per-file timing.
- Trusted2000 leaf replay passes timing envelopes, all540 owned-native events, compressed frames, four-phase profile transitions, accounted media, and capacity clocks. Whole-history policy/witness/receiver qualification remains separate and does not gain authority from these leaf passes. Natural audio/overlay verification is in progress.

- Natural A/V and overlay helper62889 joinedexit0:64archive and61per-live waveform probes,30freshfps,score0–0→1–0 in both outputs,226archive-tailframes. Additional phase-audio helper87689 passed11probes per live output including eight anchors bracketing all four phases, using the reviewed phase-anchor validator and retained PCM.
- Diagnostic timing summary:410/410 delivery windows on time;0late/missing/uncertain and0unmatched arrivals. These overlapping windows contain16,380 frame observations, not16,380unique frames. Median arrival lower/upper bounds1440.6/1514.0ms; maximum upper1603.8ms. Encoder median435.7ms; source-evaluation age median2013.7ms.
- Native applications after bootstrap:360p at27.82s,240p at90.89s,360p at182.99s. Two failed measurement attempts under restriction remain in original history. All four phases retain30freshfps and zero source loss in their acquired spans.
- Sampled all four phases visually in `owned-recording-diagnostic/four-phase-preview.png`: representative volleyball imagery and score overlay visible. This is sampled visual inspection, not a full perceptual-quality metric.
- Native runner completed owned simulator shutdown/deletion (empty successful logs), and all root analysis handles joined. The2000 experiment provides clean media and four-phase evidence; complete receiver/witness/policy replay remains unfinished. The3000 comparison has not run. No real-camera progressive streaming claim follows from this simulator result.
