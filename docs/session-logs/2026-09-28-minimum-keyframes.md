# Minimum-profile recovery keyframe experiment

Starting checkout: `codex/local-validation`, `271e390`, clean. Previous turn was progress: actual backend initialization/reporting and native preflight were implemented and verified. No hardware work.

## Evidence and decision

Reused `ordinary-native-PvbKtK` rather than rerunning the old settings. Its packet analysis shows a700ms publishing-hop budget, maximum constrained-queue residence2686.7ms, firstNAK3711.6ms after constraint, and90dropped original data sequences with no later retransmission/forward. The native downward cause occurs560–590ms after constraint, replacement/ACK at1018–1047ms; native replacement takes454ms. Old unsupported low-latency/MaxFrameDelayCount and failed immediate pre-rate/pacing experiments remain rejected.

The old minimum profile starts at sourcePTS107820800/384000. Relative to the fixture's123.25second nonempty start, this is sourceframe4726. The long damaged interval ends at4846, exactly120frames later, consistent with the expected two-second keyframe cadence. This is a hypothesis from configuration and source identities, **not a captured input-IDR proof**: the uplink packet capture is encrypted.

Candidate: use one-second keyframes at the minimum240p upload profile. Other upload profiles and the proxy's two-second output GOP stay unchanged. This limits the reference dependency interval after packet loss; it cannot prevent congestion, restore lost audio or create retransmission time. Existing bitrate/capacity admission remains active and must include the changed encoder output.

Primary references: [YouTube encoder settings](https://support.google.com/youtube/answer/2853702) recommend two seconds for destination ingest; that output setting is unchanged. [Haivision SRT latency](https://doc.haivision.com/SRT/1.5.4/Haivision/latency) and [RTT multiplier](https://doc.haivision.com/SRT/1.5.4/Haivision/rtt-multiplier) require enough recovery time and bandwidth for burst loss. None of these establishes the candidate's performance; the native run must measure it.

## Verification and rejected result

- Existing profile contract:5tests,1expected red before change;5pass after (`minimum-gop-red.log`, `minimum-gop-green.log`).
- One actual iPhone14 simulator workflow: `ordinary-native-rVojgQ`, log `minimum-gop-native.log`, using the same600second prepared volleyball fixture and explicit700ms publishing budget.
- Command: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane recovery720 --publish-peer-latency-ms 700`.
- Native workflow, cleanup, independent native/transport/geometry replay and transition audit pass. All handles joined, app data preserved and owned simulator/lab removed.
- Strict media fails. Archive:9307consecutive30fps frames, no audio timestamp gaps. Each live output:8973unique frames,96missing IDs, no repeats/corrupted IDs,26audio timestamp gaps, maximum video gap3.233seconds. Only98.651% of all complete five-second windows meet24freshfps; minimum10.8fps. Baseline was93missing/11repeated-or-corrupt,26audio gaps,2.4smaximum gap,98.796%/11.4fps. The candidate removes corrupt/repeated observations in this run but does not improve the primary continuity metrics.
- Transport:196overflow packets (157original data/39control),149220wirebytes; firstoverflow735.6ms, last3534.4ms; maximum queue residence2790.9ms, firstNAK3527.2ms. Native downshift timing/content phase differs from the saved baseline; these two runs alone cannot isolate keyframe cadence as the cause of increased backlog.
- Decision: reject and restore both profile source and its test exactly to271e390. No production keyframe change retained. Original failed result and full-media verdict remain false; no acceptance thresholds changed. A/V waveform/overlay phases are not promoted after the strict decode/continuity failure.
- Evidence: run `checkpoint-steps.json`, `independent-recovery-evidence.json`, `applied-transition-analysis.json`, `collapse-packet-analysis.json`, `media-production-manifest.json`, `fresh-frame-summary.json` and `recovery-comparison.json`. The candidate patch/hash is preserved in the run's `implementation.json`; restore evidence is `candidate-restoration.json`.

## Next action

Do not repeat the one-second minimum GOP as a fix. Return to transport backlog and encoder-drain bursts. Native statistics already expose `senderBufferedBytes`, `senderBufferMilliseconds`, RTT and actual sender delay; the ordinary saved UI snapshots omit those samples at the downward boundary. The packet evidence has cumulative ACK sequence numbers, so an offline replay can estimate newly observed outstanding bytes without another simulator capture. Use that evidence to evaluate an earlier pressure response before choosing another production change. Hard worker crash/source interruption and native uncertain-scoring restoration remain independent unfinished acceptance items.
