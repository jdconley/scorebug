# Owned admission and probe pressure — September 25

## Starting point

Authoritative checkout `/Users/jd/.codex/worktrees/scorebug-local-validation`, branch `codex/local-validation`, starting `e8e5ece`. The previous goal turn made progress: candidate/recorder reviews closed, and a fresh native replay reproduced media loss with clean recorder shutdown. No live root process or open review carried into this continuation.

## Admission/application implementation

`4a86392` adds whole-original-history owned admission/application correspondence and narrowly extracts shared witness arithmetic. Failed owners remain represented; no legacy envelope, final snapshot or rebased campaign is fabricated. Implementer48new tests pass;414affected tests passed before the final isolated failed-owner guard,48after. Independent specification review passes293tests(48new+245affected) and verifies byte-exact lifecycle provenance; quality review passes407tests(48new+359related). Both approve without findings. Root replays complete original LvDNAy,uE9hUY,iUAsQ6 evidence: each retains4owners/2admissions and explicitly denies media/full recovery authority. Results saved separately as owned-admission-application-replay.json. This closes this slice, not the full recovery or production-enable goal.

## Queue pressure comparison

Read-only comparison of all five retained experiments saved `artifacts/qa/owned-probe-queue-comparison-20260925.json`, with original input hashes. No queue overflow drops occur. During the restricted750kbps phase, maximum forwarded-packet residence is832.60ms(LvDNAy),914.80ms(pzZozK),1412.54ms(D4EhKU),1513.95ms(uE9hUY),1670.71ms(iUAsQ6). The corresponding SRT peer buffers are700/700/1000/1000/1000ms. Residence exceeds those buffers in5/9/19/27/36sparse100msbins respectively. These bins are event observations, not continuous coverage.

The clean LvDNAy case shows that exceeding the buffer in a queue statistic does not by itself prove damaged media. Both clocks remain separate; the diagnostic does not invent an offset or identify specific encrypted packets. Missing decoded IDs in pzZozK include damaged identities, not three proved missing compressed frames.

In iUAsQ6, the third owner's500kbps probe runs142.144–142.963s after native bootstrap, then2Mbps until renewal rejection143.574s. The missing sourceframe4575 was encoded at146.828s, within the independently bracketed restricted period. Proxy peak residence occurs145.865s after its own start. Last successful native recovery observations show RTT rising63.7→234.6ms while reported sender-buffer duration remains61→168ms. This motivates checking the meaning of that buffer measurement before raising timing limits.

## Confirmed statistics semantic mismatch

Both `SRTSocket` production reader defaults call `srt_bstats`. Haivision documents that `msSndBuf` from that API is a moving average; `srt_bistats(..., instantaneous=true)` returns current state. Our native probe guard applies an immediate queue ceiling to that smoothed value. The bundled iOS/macOS headers expose `srt_bistats`; no new dependency is needed. [Official statistics documentation](https://github.com/Haivision/srt/blob/master/docs/API/statistics.md#mssndbuf).

A separate real-SRT loopback experiment demonstrates the difference without changing app code: `artifacts/qa/srt-instantaneous-statistics-20260925/probe.cpp`, compiled10241exit0, run80852exit0. It limits sending to10000bytes/s, queues85packets1316bytes at10ms intervals, and reads both APIs with clear=0. At packet43,current buffer511ms versus average123ms. Maximum current1013ms versus maximum average399ms. All sockets/thread/processes joined; result,stderr,source/binary/library hashes and linked-library provenance retained. This used installed HomebrewSRT1.5.6 on the Mac, not the phone or bundled iOS library. It proves a sampling mismatch, not that this is the sole cause of prior media loss.

Next runtime fix: use instantaneous native queue statistics for pressure checks while preserving clear-counter behavior, sample timestamps, failed-read invalidation and closed/cancelled ownership checks. Add regression coverage at the native API selection boundary, build the bundled target, then repeat the native scenario under unchanged policy thresholds. Do not simply increase the receiver buffer or relabel old evidence.

## Additional primary-source context

Current WebRTC source uses bounded probe clusters and waits for feedback; the inspected configuration has15ms minimum probe duration and100ms initial duration, rather than our staged0.8-second holds. This is evidence to review probe-induced congestion, not a drop-in SRT tuning value or claim about Facebook/YouTube mobile apps. [Probe controller](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/congestion_controller/goog_cc/probe_controller.cc) (blob4589173f128721571eb8cc5acd6cb76d43ca63cd), [bitrate prober](https://webrtc.googlesource.com/src/+/refs/heads/main/modules/pacing/bitrate_prober.cc). The direct statistics mismatch is the smaller, evidenced change to test first.


The controlled statistics experiment also passes against the bundled macOS SRT1.5.4 static archive (same dependency version as the app), with source and binary retained separately: compileexit0,run9506exit0. At packet44,current512ms versus average127ms; maxima985ms/current and380ms/average. `bundled-provenance.json` records the library hash and result. This strengthens the API diagnosis; no phone or media-loss fix is claimed.

Runtime implementation is now assigned to switch the native call boundary to instantaneous sampling, preserve clear flags0(demand)/1(periodic), add selection/failure/cancellation regression tests, and compile/test the bundled target. No buffer/rate thresholds are being changed. Reviews and a fresh native replay must follow.
