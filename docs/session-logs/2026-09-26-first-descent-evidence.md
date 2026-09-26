# First-descent diagnostic session — September26

Started on62f08ea in the clean authoritative local-validation worktree. Previous goal turn made concrete progress: reviewed host/simulator phase comparisons, guarded pre-rate implementation/tests, full media failure, preserved59files, and exact restoration with17passing tests. No active build/capture/analysis jobs remain. Goal active; Watch/phone passcode state has not changed, so no unchanged physical retry.

Current inspection confirms ordinary factory disables full Driver diagnostic history and no quality audit exists in EZqNUN app QA data. The only successful-transition witness is the latest sampled UI field; revision3 is overwritten by revision4 before UI sampling. Existing full history has a512-event cap, unsuitable for100ms capture without filtering. Selected bounded successful-application audit, maximum16records/8192bytes each, post-shutdown export, UI and policy unchanged. Design/requirements are in the first-descent plan. User's standing autonomous implementation authorization applies; no new approval gate.

## Implementation and readiness

The user reports the automation prompt approved and devices ready. Fresh read-only checks nevertheless find the phone passcode required; the first Watch query fails to allocate its remote device, then a bounded retry succeeds and also reports passcode required. Requested a fresh unlock, kept the paired capture pending, and continued independent work. No app/device settings changed.

Swift implementation retains successful ACKs only, closes before suspension, joins native cleanup before one shielded export, preserves the UI payload and uses no capture file writes. Agent behavioral red logs retained (initial missing-import compile error separately retained), then82host tests pass:5audit,24session,17profile,36driver. Independent Swift review approved exact blobs in agent report. Signed phone/watch build-for-testing and Release build all passed and joined.

Root offline checker initially37tests pass after behavioral red. Review caught an audit-only admission/deadline inconsistency: the verifier must enforce Core's exact two-second deadline, not just ordered timestamps. Two mutation regressions fail before correction; all39pass afterward. This fixes diagnostic acceptance only, without changing streaming policy. Post-fix review pending. Red/green/build logs are under `artifacts/qa/first-descent-evidence-validation/`.

Post-fix verifier review approves52be61ebe5f76a43e4af31714f656400b73282e1/tests7ab755fdbd57f05bf31366c87803ac851a52dbc6. Capture wrapper9a161312528ec3e9e8cd9d334fbf8874a65babd7 binds the exact phase/control inputs to independent transport replay, server receipt scalars and attempt filename, preserves hashes and remains diagnostic-only. All build/test handles joined.

## Fresh ordinary recovery and first-descent evidence

Source376f761 run `ordinary-native-Kfk8rj` / lab `device-lab-w1Lwsr`, root15741, joined0. Workflow true, cleanup failures empty. Actual archive export uses181segments. Phase attachment `17AD1803-CE29-4EEE-B9C5-1F6757FDE31B.json`. Independent native/transport/geometry replay passes. New closed, nonoverflowed audit has6consecutive successful applications, agrees with all5sampled UI applications, and captures previously missed revision3. Reviewed wrapper binds exact phase/control hashes to independent transport replay; no media claim.

First descent720→360 cause evaluation is541.910–570.187ms after constraint; admission544.293–572.570ms; native completion1000.622–1028.898ms; ACK1000.742–1029.019ms. These are native-clock request/response bounds, not packet arrival or exact server clock synchronization. Application456.449ms; profile replacement456.058ms; admission follows evaluation2.383ms. Trigger localPressure, buffer367ms against350ms delay-relative threshold, RTT146.27ms against175ms threshold, SDKdrops0.

Complete packet capture records309overflows/282984wirebytes:267original-data plus42control, zero retransmitted-data copies. Firstoverflow516.349ms, last3917.458ms, peak100ms172804bytes at200–300ms, maxqueue2796.939ms, firstNAK3320.057ms. Independent read-only diagnosis confirms cause evaluation already25.6–53.8ms after first proxy overflow. The early burst precedes replacement; encrypted packet headers cannot assign later bursts to source frames/encoder generations. Zero SDKdrops does not contradict external proxy loss. The456ms profile span does not distinguish oldencoder drain from newoutput latency.

Media36036 joins1. Archive10779consecutive IDs0–10778,30freshfps,no audio timestamp gaps. Both live outputs10359identical observed frame IDs145–10663,162missing IDs4652–4813 plus two duplicate4651frames; minimum1freshfps/maxgap~4.567s;30audio timestamp errors each. Archive continues115frames after live. Producing media manifest remains false, no accepted-window mapping.

IndependentAV31004 joins1: archive74waveform probes/clean glyphs pass. Live summed-audio coverage differs~-1205ms/direct and~-1204ms/overlay; this is not proof of permanent presentation offset. Immutable failed-media manifest preserves 57 files covering inputs, reports, code snapshots and output hashes; every hash rechecked before writing. No policy change is qualified by this diagnostic.

Next decision: prioritize the same collapse on the physical phone when unlocked. Add a bounded diagnostic around old-session drain completion and first new-frame submission/completion only if needed to separate the456ms span; keep policy, thresholds and transport unchanged for that comparison. Paired Watch/camera acceptance remains independently pending on fresh actual device unlock. Avoid another unchanged full simulator run or repeated unsupported low-latency properties.

Final independent evidence review approves the timing/media scope,57-file manifest and joined statuses; checks the four small analysis report hashes. Corrected the handoff's stale “latest” description of the older xjv6RI run. No active root build/capture/analysis jobs remain. Overall goal remains active.
