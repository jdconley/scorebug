# Earlier congestion warning and worker crash verification

Starting checkout: `codex/local-validation`, `a506fb9`. Simulator-first; no hardware actions. Batches use focused tests and one actual workflow per changed failure mode.

## Saved evidence and policy candidate

Replayed original forward SRT payload and reverse cumulative ACKs from `ordinary-native-PvbKtK` and `ordinary-native-rVojgQ`. At250ms after the bandwidth collapse, the observed unacknowledged payload lower bounds are45,872 and38,916bytes; at500ms both exceed109KB. Replay inputs are closed, untruncated and have no observer errors. This is observed packet retention, not proof of receiver decoding/capacity; it excludes pre-fault packets. Script, input hashes and results: `artifacts/qa/ack-backlog-20260928/`.

Candidate adds a downward-only transport warning for growing native SRT retention. Over actual samples250–500ms apart, require at least100ms growth in buffer duration, increasing buffered bytes, the same known positive negotiated delay throughout, and current duration at least min(250ms,delay/4) with default limits. Existing generation, freshness and profile-acknowledgment bounds still apply. Stable/draining buffers and missing/changing delay do not activate this new warning. No receiver health or usable capacity is inferred. Existing half-delay/RTT/drop limits remain. Two-second GOP remains unchanged. This is a project policy candidate, not a published platform standard.

Added buffered-byte serialization to existing transport evidence and independent replay support. Focused telemetry regression fails before implementation;45native tests pass afterward. Replay19tests pass. Evidence under `ack-backlog-20260928/tests-*` and `replay-tests-*`.

## Hard worker crash coverage

`--lane server-crash` reuses the existing native server-recovery workflow, but explicitly SIGKILLs the owned worker before replacement. The existing guardian handles child encoder shutdown on parent disconnect; replacement waits for worker pipe closure. Restart evidence records the actual requested termination. API remains down15seconds, then worker remains down15seconds. Ordinary graceful restart behavior is unchanged.

Launcher tests first fail on missing lane and graceful-versus-forced result; all36pass after implementation, including a real child process termination. This alone does not qualify media recovery; actual workflow results follow.

## Plan reconciliation

Removed stale claims that native Watch/adaptation/recovery were merely planned. Main plan now credits existing full-app recording/relaunch/export coverage, backend readiness and deployment instructions. Low-space/queue pressure, source interruption, native lost-reply restoration and sustained/hardware acceptance remain open.

## Actual workflow results

### Growing-retention candidate

`ordinary-native-IZI72F`, lab `device-lab-JouIyE`: native workflow, independent native/transport/geometry replay, five actual profile transitions and cleanup all pass. The720→240 decision is376.8–408.2ms after the fault request; minimum profile acknowledgment855.5–886.9ms. Previously the decision was560.7–589.8ms and acknowledgment1017.7–1046.7ms. Actual encoder replacement still takes475ms.

The archive contains11,122consecutive30fps source frames with no video/audio timestamp errors. Both live outputs contain10,772frames,10,767unique source IDs:87missing IDs,5repeated/corrupted observations,16audio gaps,2.4seconds maximum video gap.98.833% of all complete five-second windows reach24freshfps; worst window12.6fps. Baseline was93missing/11repeated/26audio gaps/2.4seconds and98.796%. Overflow127packets versus133,60,260wire bytes versus65,996. Capture phases contain different source content, so these runs establish earlier reaction and the measured comparison, not isolated causal effect on every media metric.

Keep the conservative earlier warning as partial progress. **Strict live-media verification still fails.** Waveform/overlay checks were intentionally not repeated after decode/continuity failure; no blanket media pass. All run/analysis handles joined. Retain the immutable native-runtime patch and hashes in the run, the cumulative ACK replay, original failed outputs and checkpoint reports. Do not repeat the same congestion run unchanged.

### Hard worker crash

`ordinary-native-SvL3gk`, lab `device-lab-Y50Q72`: native workflow and cleanup pass. API and worker are actually SIGKILLed and remain unavailable15.204/15.215seconds. Recording and accepted publishing stay active; output recovers without another Start tap.

Reused the prior server-recovery media verifier unchanged.43archive segments pass identity/sequence/metadata/SHA256 checks; native export has2,510consecutive30fps source frames and no archive overlay in sampled frames. Both output destinations have three decodable H264/AAC sessions; final samples show HOME1–0AWAY. Final A/V end offsets: archive22.7ms, direct25.5ms, proxy24.9ms. Interrupted output tails retain508–548ms extra audio: this is automatic recovery, not seamless process-outage media. The production guardian terminates its encoder after worker IPC disconnect; killing the entire machine/process group was not simulated. All captures, verifiers and owned processes joined; no cleanup failures.

Commands: `DEVELOPER_DIR=/Applications/Xcode-26.2.0.app/Contents/Developer node scripts/test-ordinary-native-app.mjs --host 192.168.1.130 --source /Users/jd/.codex/worktrees/scorebug-local-validation/artifacts/qa/prepared-ordinary-recovery-dZeq4S/input.mov --lane server-crash`;720run uses `--lane recovery720 --publish-peer-latency-ms 700`. Media verifier scripts and reports are retained under each run. `git diff --check` passes. No broad suite, extra Watch workflow, physical build or hardware run was repeated.

## Next

Prioritize the missing native lost-reply/outbox, source-interruption and storage-pressure integration cases. Build a consolidated simulator acceptance result from existing valid evidence. Severe-collapse live media and sustained profiles remain open; avoid repeating unchanged congestion experiments.
